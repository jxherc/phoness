// c api the app uses to start the ui test runner on this same phone.
// we talk to the phone's own lockdownd through the loopback vpn (10.7.0.1),
// same trick stikdebug uses for jit. idevice does the heavy lifting.

use std::ffi::{CStr, CString, c_char};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use idevice::{
    IdeviceError, IdeviceService,
    heartbeat::HeartbeatClient,
    lockdown::LockdownClient,
    mobile_image_mounter::ImageMounter,
    pairing_file::PairingFile,
    provider::{IdeviceProvider, TcpProvider},
    services::dvt::xctest::{TestConfig, XCUITestService, listener::XCUITestListener},
    services::installation_proxy::InstallationProxyClient,
};
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

// the vpn swaps src/dst, so this address is "the phone, seen from outside"
const PHONE: Ipv4Addr = Ipv4Addr::new(10, 7, 0, 1);

const OFF: i32 = 0;
const STARTING: i32 = 1;
const RUNNING: i32 = 2;
const FAILED: i32 = 3;

// gen goes up on every start and stop. a run only writes state while its gen is current,
// so an old run finishing late can't clobber a newer one.
struct State {
    generation: u64,
    phase: i32,
    message: String,
    tasks: Vec<JoinHandle<()>>,
}

fn lock() -> MutexGuard<'static, State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(|| {
        Mutex::new(State {
            generation: 0,
            phase: OFF,
            message: String::new(),
            tasks: vec![],
        })
    })
    .lock()
    // a panic elsewhere shouldn't brick every later call
    .unwrap_or_else(|e| e.into_inner())
}

fn rt() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

fn set(generation: u64, phase: i32, msg: impl Into<String>) {
    let mut s = lock();
    if s.generation == generation {
        s.phase = phase;
        s.message = msg.into();
    }
}

fn note(generation: u64, msg: impl Into<String>) {
    let mut s = lock();
    if s.generation == generation {
        s.message = msg.into();
    }
}

// keeps the task so stop can abort it. a stale run's task gets aborted right away
fn track(generation: u64, task: JoinHandle<()>) -> bool {
    let mut s = lock();
    if s.generation == generation {
        s.tasks.push(task);
        true
    } else {
        task.abort();
        false
    }
}

// the vpn being off means 10.7.0.1 goes out the normal route, maybe to some other host.
// fail fast instead of hanging on a connect that never answers
async fn within<T, E: std::fmt::Display>(
    secs: u64,
    what: &str,
    fut: impl std::future::Future<Output = Result<T, E>>,
) -> Result<T, String> {
    match tokio::time::timeout(Duration::from_secs(secs), fut).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(format!("{what}: {e}")),
        Err(_) => Err(format!("{what}: timed out, is the vpn on?")),
    }
}

fn provider(pairing: &str) -> Result<Arc<dyn IdeviceProvider>, String> {
    let pairing_file = PairingFile::read_from_file(pairing)
        .map_err(|e| format!("pairing file unreadable, run scripts/setup.sh again ({e})"))?;
    Ok(Arc::new(TcpProvider {
        addr: IpAddr::V4(PHONE),
        scope_id: None,
        pairing_file,
        label: "agent".into(),
    }))
}

struct Listener {
    generation: u64,
}

impl XCUITestListener for Listener {
    async fn test_runner_ready_with_capabilities(&mut self) -> Result<(), IdeviceError> {
        set(self.generation, RUNNING, "runner is up");
        Ok(())
    }

    async fn did_begin_executing_test_plan(&mut self) -> Result<(), IdeviceError> {
        set(self.generation, RUNNING, "runner is up");
        Ok(())
    }

    async fn did_finish_executing_test_plan(&mut self) -> Result<(), IdeviceError> {
        set(self.generation, OFF, "runner stopped");
        Ok(())
    }

    async fn initialization_for_ui_testing_did_fail(
        &mut self,
        description: &str,
    ) -> Result<(), IdeviceError> {
        set(self.generation, FAILED, format!("ui testing failed to start: {description}"));
        Ok(())
    }

    async fn did_fail_to_bootstrap(&mut self, description: &str) -> Result<(), IdeviceError> {
        set(self.generation, FAILED, format!("runner failed to start: {description}"));
        Ok(())
    }
}

async fn heartbeat(provider: Arc<dyn IdeviceProvider>) {
    // lockdownd drops "network" clients that stop answering marco/polo
    loop {
        if let Ok(Ok(mut hb)) =
            tokio::time::timeout(Duration::from_secs(10), HeartbeatClient::connect(&*provider)).await
        {
            let mut interval = 15;
            loop {
                match hb.get_marco(interval).await {
                    Ok(i) => interval = i + 5,
                    Err(_) => break,
                }
                if hb.send_polo().await.is_err() {
                    break;
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

async fn mount_ddi(generation: u64, provider: &dyn IdeviceProvider, ddi: &str) -> Result<(), String> {
    let mut mounter = within(10, "image mounter", ImageMounter::connect(provider)).await?;
    let mounted = within(10, "image list", mounter.copy_devices()).await?;
    if !mounted.is_empty() {
        return Ok(());
    }

    note(generation, "mounting developer disk image");
    let read = |name: &str| {
        std::fs::read(format!("{ddi}/{name}"))
            .map_err(|e| format!("developer disk image {name} missing, run scripts/setup.sh again ({e})"))
    };
    let image = read("Image.dmg")?;
    let trust = read("Image.dmg.trustcache")?;
    let manifest = read("BuildManifest.plist")?;

    let pairing = provider.get_pairing_file().await.map_err(|e| e.to_string())?;
    let mut lockdown = within(10, "lockdown", LockdownClient::connect(provider)).await?;
    within(10, "lockdown session", lockdown.start_session(&pairing)).await?;
    let chip = within(10, "chip id", lockdown.get_value(Some("UniqueChipID"), None))
        .await?
        .as_unsigned_integer()
        .ok_or("chip id: not a number")?;

    // the mount may close the socket on failure, so use a fresh client.
    // the image is 16 MB plus a request to apple's signing server, so this one gets longer
    let mut mounter = within(10, "image mounter", ImageMounter::connect(provider)).await?;
    within(120, "mount", mounter.mount_personalized(provider, image, trust, &manifest, None, chip)).await
}

async fn run(
    generation: u64,
    pairing: String,
    ddi: String,
    runner: String,
    port: u16,
    token: String,
) -> Result<(), String> {
    let provider = provider(&pairing)?;

    note(generation, "connecting to the phone");
    let pairing_file = provider.get_pairing_file().await.map_err(|e| e.to_string())?;
    let mut lockdown = within(8, "can't reach lockdownd", LockdownClient::connect(&*provider)).await?;
    within(8, "pairing rejected, run scripts/setup.sh again", lockdown.start_session(&pairing_file))
        .await?;
    drop(lockdown);

    if !track(generation, rt().spawn(heartbeat(provider.clone()))) {
        return Err("stopped".into());
    }

    note(generation, "checking developer disk image");
    mount_ddi(generation, &*provider, &ddi).await?;

    note(generation, "finding the runner app");
    let mut ip = within(10, "installation proxy", InstallationProxyClient::connect(&*provider)).await?;
    let mut cfg = within(
        15,
        "runner app not found, run scripts/setup.sh again",
        TestConfig::from_installation_proxy(&mut ip, &runner, None),
    )
    .await?;
    let mut env = plist::Dictionary::new();
    env.insert("RUNNER_PORT".into(), plist::Value::String(port.to_string()));
    // any app on the phone can reach loopback, so the runner wants this on every request
    env.insert("RUNNER_TOKEN".into(), plist::Value::String(token));
    cfg.runner_env = Some(env);

    note(generation, "launching runner, enter your passcode if asked");
    XCUITestService::new(provider)
        .run(cfg, &mut Listener { generation }, None)
        .await
        .map_err(|e| format!("runner: {e}"))
}

/// # Safety
/// `p` is null or a valid nul-terminated string.
unsafe fn arg(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn out(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap_or_default().into_raw()
}

/// starts the runner in the background. returns right away.
/// poll launcher_phase / launcher_message for progress.
///
/// # Safety
/// every pointer is null or a valid nul-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn launcher_start(
    pairing_path: *const c_char,
    ddi_dir: *const c_char,
    runner_bundle: *const c_char,
    port: u16,
    token: *const c_char,
) {
    let (pairing, ddi, runner, token) =
        unsafe { (arg(pairing_path), arg(ddi_dir), arg(runner_bundle), arg(token)) };

    let generation = {
        let mut s = lock();
        s.generation += 1;
        for t in s.tasks.drain(..) {
            t.abort();
        }
        s.phase = STARTING;
        s.message = "starting".into();
        s.generation
    };
    if token.is_empty() {
        return set(generation, FAILED, "no runner token given");
    }

    // a panic must not unwind into swift
    let started = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        rt().spawn(async move {
            let res = run(generation, pairing, ddi, runner, port, token).await;
            let mut s = lock();
            // a newer start or a stop owns the state now
            if s.generation != generation {
                return;
            }
            match res {
                Ok(()) => (s.phase, s.message) = (OFF, "runner stopped".into()),
                Err(e) => (s.phase, s.message) = (FAILED, e),
            }
            // run is done, the heartbeat can go too
            for t in s.tasks.drain(..) {
                t.abort();
            }
        })
    }));
    match started {
        Ok(task) => {
            track(generation, task);
        }
        Err(_) => set(generation, FAILED, "launcher crashed while starting"),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn launcher_stop() {
    let mut s = lock();
    s.generation += 1;
    for t in s.tasks.drain(..) {
        t.abort();
    }
    s.phase = OFF;
    s.message = String::new();
}

/// 0 off, 1 starting, 2 running, 3 failed
#[unsafe(no_mangle)]
pub extern "C" fn launcher_phase() -> i32 {
    lock().phase
}

#[unsafe(no_mangle)]
pub extern "C" fn launcher_message() -> *mut c_char {
    out(lock().message.clone())
}

/// blocking, up to about 15s. json array of {"id","name","type"} or {"error"}.
/// only call it with the vpn up.
///
/// # Safety
/// `pairing_path` is null or a valid nul-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn launcher_apps(pairing_path: *const c_char) -> *mut c_char {
    let pairing = unsafe { arg(pairing_path) };
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        rt().block_on(async move {
            let provider = provider(&pairing)?;
            let mut ip =
                within(8, "installation proxy", InstallationProxyClient::connect(&*provider)).await?;
            let apps = within(15, "app list", ip.get_apps(Some("Any"), None)).await?;
            let mut list = vec![];
            for (id, info) in apps {
                let Some(d) = info.as_dictionary() else { continue };
                let s = |k: &str| d.get(k).and_then(|v| v.as_string()).unwrap_or("").to_string();
                let name = [s("CFBundleDisplayName"), s("CFBundleName")]
                    .into_iter()
                    .find(|n| !n.is_empty())
                    .unwrap_or_default();
                // skip hidden stuff with no name (plugins, services)
                if name.is_empty() {
                    continue;
                }
                list.push(serde_json::json!({ "id": id, "name": name, "type": s("ApplicationType") }));
            }
            Ok::<_, String>(serde_json::Value::Array(list))
        })
    }))
    .unwrap_or_else(|_| Err("launcher crashed while listing apps".into()));
    out(match res {
        Ok(v) => v.to_string(),
        Err(e) => serde_json::json!({ "error": e }).to_string(),
    })
}

/// # Safety
/// `s` is null or a pointer this library returned and hasn't freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn launcher_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}
