// c api the app uses to start the ui test runner on this same phone.
//
// the app's loopback vpn makes 10.7.0.1 "the phone, seen from outside". through it we
// pair-verify with the phone's own remotepairingd (what xcode talks to over wifi), open its
// encrypted tunnel, and do everything inside that: mount the disk image, find the runner,
// start it as a ui test. lockdownd is out, iOS 27 drops connections that come in through a vpn.
// same path stikdebug takes. idevice does the heavy lifting.

use std::ffi::{CStr, CString, c_char};
use std::io::Write;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use idevice::{
    IdeviceError, RsdService,
    heartbeat::HeartbeatClient,
    lockdown::LockdownClient,
    mobile_image_mounter::ImageMounter,
    remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native},
    rsd::RsdHandshake,
    services::dvt::xctest::{TestConfig, XCUITestService, listener::XCUITestListener},
    services::installation_proxy::InstallationProxyClient,
    tcp::{adapter::Adapter, handle::AdapterHandle},
};
use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

// optional debug log, set by launcher_start. appends lines.
fn logpath() -> &'static Mutex<Option<String>> {
    static L: OnceLock<Mutex<Option<String>>> = OnceLock::new();
    L.get_or_init(|| Mutex::new(None))
}

pub fn set_log(path: Option<String>) {
    *logpath().lock().unwrap_or_else(|e| e.into_inner()) = path;
}

fn logln(msg: &str) {
    let path = logpath().lock().unwrap_or_else(|e| e.into_inner()).clone();
    if let Some(path) = path
        && let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path)
    {
        let _ = writeln!(f, "{}", msg);
    }
}

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
    // json, filled in while the runner starts. the app asks for it once the runner is up
    apps: String,
}

fn lock() -> MutexGuard<'static, State> {
    static S: OnceLock<Mutex<State>> = OnceLock::new();
    S.get_or_init(|| {
        Mutex::new(State {
            generation: 0,
            phase: OFF,
            message: String::new(),
            tasks: vec![],
            apps: "[]".into(),
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
    let msg = msg.into();
    logln(&format!("[phase {phase}] {msg}"));
    let mut s = lock();
    if s.generation == generation {
        s.phase = phase;
        s.message = msg;
    }
}

fn note(generation: u64, msg: impl Into<String>) {
    let msg = msg.into();
    logln(&msg);
    let mut s = lock();
    if s.generation == generation {
        s.message = msg;
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
        Ok(Err(e)) => {
            logln(&format!("ERROR {what}: {e}"));
            Err(format!("{what}: {e}"))
        }
        Err(_) => {
            logln(&format!("TIMEOUT after {secs}s: {what}"));
            Err(format!("{what}: timed out, is the vpn on?"))
        }
    }
}

// pair-verify with remotepairingd, then open the tunnel it offers and say hi to rsd,
// which lists every service we can reach inside it
async fn tunnel(addr: SocketAddr, pairing: &str) -> Result<(AdapterHandle, RsdHandshake), String> {
    let bytes = std::fs::read(pairing)
        .map_err(|e| format!("pairing file unreadable, run scripts/setup.sh again ({e})"))?;
    // older setups wrote a lockdown pairing file, which iOS 27 has no use for here
    let mut rpf = RpPairingFile::from_bytes(&bytes)
        .map_err(|_| "old pairing file, run scripts/setup.sh again".to_string())?;

    let stream = within(8, "can't reach remote pairing", tokio::net::TcpStream::connect(addr)).await?;
    let mut rp = RemotePairingClient::new(RpPairingSocket::new(stream), "agent");
    within(10, "remote pairing", rp.attempt_pair_verify()).await?;
    // verify only. a new pairing needs the trust prompt, setup.sh does that over usb
    within(10, "pairing rejected, run scripts/setup.sh again", rp.validate_pairing(&mut rpf)).await?;

    let port = within(10, "tunnel listener", rp.create_tcp_listener()).await?;
    let stream = within(8, "tunnel connect", tokio::net::TcpStream::connect((addr.ip(), port))).await?;
    let tunnel = within(10, "tunnel handshake", connect_tls_psk_tunnel_native(stream, rp.encryption_key())).await?;

    let ip = |s: &str| s.parse::<IpAddr>().map_err(|e| format!("tunnel address {s}: {e}"));
    let (client, server) = (ip(&tunnel.info.client_address)?, ip(&tunnel.info.server_address)?);
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), client, server);
    adapter.set_mss(mtu.min(8192) - 60);
    let mut adapter = adapter.to_async_handle();

    let rsd = within(10, "rsd connect", adapter.connect(rsd_port)).await?;
    let handshake = within(10, "rsd handshake", RsdHandshake::new(rsd)).await?;
    Ok((adapter, handshake))
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

// keeps the tunnel's services from timing us out during long runs. stikdebug does the same
async fn heartbeat(mut hb: HeartbeatClient) {
    let mut interval = 15;
    loop {
        match hb.get_marco(interval).await {
            Ok(i) => interval = i + 5,
            Err(_) => return,
        }
        if hb.send_polo().await.is_err() {
            return;
        }
    }
}

async fn mount_ddi(
    generation: u64,
    adapter: &mut AdapterHandle,
    handshake: &mut RsdHandshake,
    ddi: &str,
    chip: u64,
) -> Result<(), String> {
    let mut mounter = within(10, "image mounter", ImageMounter::connect_rsd(adapter, handshake)).await?;
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

    // the image is 16 MB plus a request to apple's signing server, so this one gets longer
    within(
        120,
        "mount",
        mounter.mount_personalized_rsd(adapter, handshake, image, trust, &manifest, None, chip),
    )
    .await
}

fn app_list(apps: std::collections::HashMap<String, plist::Value>) -> String {
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
    serde_json::Value::Array(list).to_string()
}

/// the whole start: tunnel, disk image, runner. returns when the runner stops.
/// `addr` is 10.7.0.1 on the phone, or the phone's wifi address when testing from a mac.
pub async fn run(
    generation: u64,
    addr: SocketAddr,
    pairing: String,
    ddi: String,
    runner: String,
    port: u16,
    token: String,
) -> Result<(), String> {
    note(generation, "connecting to the phone");
    let (mut adapter, mut handshake) = tunnel(addr, &pairing).await?;

    if let Ok(Ok(hb)) =
        tokio::time::timeout(Duration::from_secs(10), HeartbeatClient::connect_rsd(&mut adapter, &mut handshake)).await
        && !track(generation, tokio::spawn(heartbeat(hb)))
    {
        return Err("stopped".into());
    }

    // lockdown inside the tunnel is already trusted, no session needed
    let mut lockdown = within(10, "lockdown", LockdownClient::connect_rsd(&mut adapter, &mut handshake)).await?;
    let version = within(10, "ios version", lockdown.get_value(Some("ProductVersion"), None)).await?;
    let major = version
        .as_string()
        .and_then(|v| v.split('.').next())
        .and_then(|v| v.parse::<u8>().ok())
        .ok_or("ios version: not a version")?;
    let chip = within(10, "chip id", lockdown.get_value(Some("UniqueChipID"), None))
        .await?
        .as_unsigned_integer()
        .ok_or("chip id: not a number")?;
    drop(lockdown);

    note(generation, "checking developer disk image");
    mount_ddi(generation, &mut adapter, &mut handshake, &ddi, chip).await?;

    note(generation, "finding the runner app");
    let mut ip =
        within(10, "installation proxy", InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake)).await?;
    // the app wants the app list too, grab it while we're here
    if let Ok(apps) = within(15, "app list", ip.get_apps(Some("Any"), None)).await {
        lock().apps = app_list(apps);
    }
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
    XCUITestService::run_rsd(&mut adapter, &handshake, major, cfg, &mut Listener { generation }, None)
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
/// `rp_port` is remotepairingd's port (bonjour `_remotepairing._tcp`, usually 49152).
///
/// # Safety
/// every pointer is null or a valid nul-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn launcher_start(
    pairing_path: *const c_char,
    ddi_dir: *const c_char,
    runner_bundle: *const c_char,
    rp_port: u16,
    port: u16,
    token: *const c_char,
) {
    let (pairing, ddi, runner, token) =
        unsafe { (arg(pairing_path), arg(ddi_dir), arg(runner_bundle), arg(token)) };

    // log next to the pairing file (the app's Application Support), truncated each start
    if let Some(dir) = std::path::Path::new(&pairing).parent() {
        let path = dir.join("launcher.log");
        let _ = std::fs::write(&path, b"");
        set_log(path.to_str().map(String::from));
    }
    logln(&format!("start: rp_port={rp_port} ddi={ddi} runner={runner}"));

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
    let addr = SocketAddr::new(IpAddr::V4(PHONE), rp_port);

    // a panic must not unwind into swift
    let started = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        rt().spawn(async move {
            let res = run(generation, addr, pairing, ddi, runner, port, token).await;
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

/// json array of {"id","name","type"} from the last start. "[]" before that.
#[unsafe(no_mangle)]
pub extern "C" fn launcher_apps() -> *mut c_char {
    out(lock().apps.clone())
}

/// # Safety
/// `s` is null or a pointer this library returned and hasn't freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn launcher_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}
