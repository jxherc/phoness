// c api the app uses to start the ui test runner on this same phone.
// we talk to the phone's own lockdownd through the loopback vpn (10.7.0.1),
// same trick stikdebug uses for jit. idevice does the heavy lifting.

use std::ffi::{CStr, CString, c_char};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::{Arc, Mutex, OnceLock};
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

struct State {
    phase: i32,
    message: String,
    tasks: Vec<JoinHandle<()>>,
}

fn state() -> &'static Mutex<State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(|| {
        Mutex::new(State {
            phase: OFF,
            message: String::new(),
            tasks: vec![],
        })
    })
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

fn set(phase: i32, msg: impl Into<String>) {
    let mut s = state().lock().unwrap();
    s.phase = phase;
    s.message = msg.into();
}

fn note(msg: impl Into<String>) {
    state().lock().unwrap().message = msg.into();
}

fn provider(pairing: &str) -> Result<Arc<dyn IdeviceProvider>, String> {
    let pairing_file =
        PairingFile::read_from_file(pairing).map_err(|e| format!("pairing file: {e}"))?;
    Ok(Arc::new(TcpProvider {
        addr: IpAddr::V4(PHONE),
        scope_id: None,
        pairing_file,
        label: "agent".into(),
    }))
}

struct Listener;

impl XCUITestListener for Listener {
    async fn test_runner_ready_with_capabilities(&mut self) -> Result<(), IdeviceError> {
        set(RUNNING, "runner is up");
        Ok(())
    }

    async fn did_begin_executing_test_plan(&mut self) -> Result<(), IdeviceError> {
        set(RUNNING, "runner is up");
        Ok(())
    }

    async fn did_finish_executing_test_plan(&mut self) -> Result<(), IdeviceError> {
        set(OFF, "runner stopped");
        Ok(())
    }

    async fn initialization_for_ui_testing_did_fail(
        &mut self,
        description: &str,
    ) -> Result<(), IdeviceError> {
        set(FAILED, format!("ui testing failed to start: {description}"));
        Ok(())
    }

    async fn did_fail_to_bootstrap(&mut self, description: &str) -> Result<(), IdeviceError> {
        set(FAILED, format!("runner failed to start: {description}"));
        Ok(())
    }
}

async fn heartbeat(provider: Arc<dyn IdeviceProvider>) {
    // lockdownd drops "network" clients that stop answering marco/polo
    loop {
        if let Ok(mut hb) = HeartbeatClient::connect(&*provider).await {
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

async fn mount_ddi(provider: &dyn IdeviceProvider, ddi: &str) -> Result<(), String> {
    let mut mounter = ImageMounter::connect(provider)
        .await
        .map_err(|e| format!("image mounter: {e}"))?;
    let mounted = mounter
        .copy_devices()
        .await
        .map_err(|e| format!("image list: {e}"))?;
    if !mounted.is_empty() {
        return Ok(());
    }

    note("mounting developer disk image");
    let read = |name: &str| {
        std::fs::read(format!("{ddi}/{name}")).map_err(|e| format!("ddi {name}: {e}"))
    };
    let image = read("Image.dmg")?;
    let trust = read("Image.dmg.trustcache")?;
    let manifest = read("BuildManifest.plist")?;

    let mut lockdown = LockdownClient::connect(provider)
        .await
        .map_err(|e| format!("lockdown: {e}"))?;
    lockdown
        .start_session(&provider.get_pairing_file().await.map_err(|e| e.to_string())?)
        .await
        .map_err(|e| format!("lockdown session: {e}"))?;
    let chip = lockdown
        .get_value(Some("UniqueChipID"), None)
        .await
        .map_err(|e| format!("chip id: {e}"))?
        .as_unsigned_integer()
        .ok_or("chip id: not a number")?;

    // the mount may close the socket on failure, so use a fresh client
    let mut mounter = ImageMounter::connect(provider)
        .await
        .map_err(|e| format!("image mounter: {e}"))?;
    mounter
        .mount_personalized(provider, image, trust, &manifest, None, chip)
        .await
        .map_err(|e| format!("mount: {e}"))
}

async fn run(pairing: String, ddi: String, runner: String, port: u16, token: String) -> Result<(), String> {
    let provider = provider(&pairing)?;

    note("connecting to the phone");
    let mut lockdown = LockdownClient::connect(&*provider)
        .await
        .map_err(|e| format!("can't reach lockdownd, is the vpn on? ({e})"))?;
    lockdown
        .start_session(&provider.get_pairing_file().await.map_err(|e| e.to_string())?)
        .await
        .map_err(|e| format!("pairing rejected: {e}"))?;
    drop(lockdown);

    let hb = rt().spawn(heartbeat(provider.clone()));
    state().lock().unwrap().tasks.push(hb);

    note("checking developer disk image");
    mount_ddi(&*provider, &ddi).await?;

    note("finding the runner app");
    let mut ip = InstallationProxyClient::connect(&*provider)
        .await
        .map_err(|e| format!("installation proxy: {e}"))?;
    let mut cfg = TestConfig::from_installation_proxy(&mut ip, &runner, None)
        .await
        .map_err(|e| format!("runner app not found ({runner}): {e}"))?;
    let mut env = plist::Dictionary::new();
    env.insert("RUNNER_PORT".into(), plist::Value::String(port.to_string()));
    // any app on the phone can reach loopback, so the runner wants this on every request
    env.insert("RUNNER_TOKEN".into(), plist::Value::String(token));
    cfg.runner_env = Some(env);

    note("launching runner, enter your passcode if asked");
    XCUITestService::new(provider)
        .run(cfg, &mut Listener, None)
        .await
        .map_err(|e| format!("runner: {e}"))
}

fn arg(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn out(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).unwrap().into_raw()
}

/// starts the runner in the background. returns right away.
/// poll launcher_phase / launcher_message for progress.
#[unsafe(no_mangle)]
pub extern "C" fn launcher_start(
    pairing_path: *const c_char,
    ddi_dir: *const c_char,
    runner_bundle: *const c_char,
    port: u16,
    token: *const c_char,
) {
    launcher_stop();
    let (pairing, ddi, runner, token) = (arg(pairing_path), arg(ddi_dir), arg(runner_bundle), arg(token));
    set(STARTING, "starting");
    let task = rt().spawn(async move {
        match run(pairing, ddi, runner, port, token).await {
            Ok(()) => set(OFF, "runner stopped"),
            Err(e) => set(FAILED, e),
        }
        // run is done, the heartbeat can go too
        let mut s = state().lock().unwrap();
        for t in s.tasks.drain(..) {
            t.abort();
        }
    });
    state().lock().unwrap().tasks.push(task);
}

#[unsafe(no_mangle)]
pub extern "C" fn launcher_stop() {
    let mut s = state().lock().unwrap();
    for t in s.tasks.drain(..) {
        t.abort();
    }
    s.phase = OFF;
    s.message = String::new();
}

/// 0 off, 1 starting, 2 running, 3 failed
#[unsafe(no_mangle)]
pub extern "C" fn launcher_phase() -> i32 {
    state().lock().unwrap().phase
}

#[unsafe(no_mangle)]
pub extern "C" fn launcher_message() -> *mut c_char {
    out(state().lock().unwrap().message.clone())
}

/// blocking. json array of {"id","name","type"} or {"error"}
#[unsafe(no_mangle)]
pub extern "C" fn launcher_apps(pairing_path: *const c_char) -> *mut c_char {
    let pairing = arg(pairing_path);
    let res: Result<serde_json::Value, String> = rt().block_on(async move {
        let provider = provider(&pairing)?;
        let mut ip = InstallationProxyClient::connect(&*provider)
            .await
            .map_err(|e| format!("installation proxy: {e}"))?;
        let apps = ip
            .get_apps(Some("Any"), None)
            .await
            .map_err(|e| format!("app list: {e}"))?;
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
        Ok(serde_json::Value::Array(list))
    });
    out(match res {
        Ok(v) => v.to_string(),
        Err(e) => serde_json::json!({ "error": e }).to_string(),
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn launcher_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}
