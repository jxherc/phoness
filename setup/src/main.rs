// usage: pairing <out.plist> [udid]
//        pairing --list
//
// writes a remote pairing file the phone uses to reach its own remotepairingd later,
// through the app's loopback vpn. (iOS 27 lockdownd won't take connections that come
// through a vpn, so the old lockdown pairing file is no use there.)
// the file is a paired-host credential for that phone, so it's written 0600.
//
// it pairs inside a usb tunnel, same as xcode does. the first time the phone asks to
// trust this computer. reruns keep a pairing that still works.

use std::os::unix::fs::PermissionsExt;
use std::process::exit;

use idevice::{
    IdeviceService, RemoteXpcClient,
    core_device_proxy::CoreDeviceProxy,
    remote_pairing::{RemotePairingClient, RpPairingFile},
    rsd::RsdHandshake,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};

fn die(msg: &str) -> ! {
    eprintln!("{msg}");
    exit(1)
}

#[tokio::main]
async fn main() {
    let out = std::env::args().nth(1).unwrap_or("pairing.plist".into());
    let want = std::env::args().nth(2);

    let mut mux = UsbmuxdConnection::default()
        .await
        .unwrap_or_else(|e| die(&format!("can't reach usbmuxd, is this a mac with xcode? ({e})")));
    let mut devs = mux
        .get_devices()
        .await
        .unwrap_or_else(|e| die(&format!("can't list devices ({e})")));
    if out == "--list" {
        for d in &devs {
            println!("{} {:?}", d.udid, d.connection_type);
        }
        return;
    }
    // an ipad paired to the same mac shows up here too, so match the udid when given
    if let Some(want) = &want {
        devs.retain(|d| &d.udid == want);
    }
    // cable first
    devs.sort_by_key(|d| d.connection_type != Connection::Usb);
    let Some(dev) = devs.into_iter().next() else {
        die("that phone isn't connected. plug it in, unlock it, and trust this mac")
    };
    println!(
        "phone: {} ({})",
        dev.udid,
        if dev.connection_type == Connection::Usb { "usb" } else { "wifi" }
    );
    let provider = dev.to_provider(UsbmuxdAddr::default(), "agent-setup");

    // usb tunnel -> rsd -> the tunnel service, which is where pairing happens
    let proxy = CoreDeviceProxy::connect(&provider)
        .await
        .unwrap_or_else(|e| die(&format!("can't open a tunnel to the phone, unlock it and try again ({e})")));
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let mut adapter = proxy
        .create_software_tunnel()
        .unwrap_or_else(|e| die(&format!("can't open a tunnel to the phone ({e})")))
        .to_async_handle();
    let rsd = adapter
        .connect(rsd_port)
        .await
        .unwrap_or_else(|e| die(&format!("can't reach the phone's service list ({e})")));
    let handshake = RsdHandshake::new(rsd)
        .await
        .unwrap_or_else(|e| die(&format!("can't read the phone's service list ({e})")));
    let ts = handshake
        .services
        .get("com.apple.internal.dt.coredevice.untrusted.tunnelservice")
        .unwrap_or_else(|| die("the phone has no tunnel service, is it on iOS 17 or later?"));
    let ts = adapter
        .connect(ts.port)
        .await
        .unwrap_or_else(|e| die(&format!("can't reach the tunnel service ({e})")));
    let mut xpc = RemoteXpcClient::new(ts)
        .await
        .unwrap_or_else(|e| die(&format!("tunnel service didn't answer ({e})")));
    xpc.do_handshake()
        .await
        .unwrap_or_else(|e| die(&format!("tunnel service didn't answer ({e})")));
    let _ = xpc.recv_root().await;

    // keep a pairing that still works, so reruns don't pile up trusted hosts
    let existing = std::fs::read(&out).ok().and_then(|b| RpPairingFile::from_bytes(&b).ok());
    let fresh = existing.is_none();
    let mut pairing = existing.unwrap_or_else(|| RpPairingFile::generate("agent"));
    if fresh {
        println!("pairing, tap trust on the phone and enter the passcode");
    }
    let mut rp = RemotePairingClient::new(xpc, "agent");
    // verifies the file, or pairs fresh when that fails. iphones use the fixed pin 000000
    rp.connect(&mut pairing, async || "000000".to_string())
        .await
        .unwrap_or_else(|e| die(&format!("pairing failed, tap trust on the phone and rerun ({e})")));

    // created 0600 from the start, so it's never readable by others, even briefly
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&out)
            .unwrap_or_else(|e| die(&format!("couldn't write {out} ({e})")));
        f.write_all(&pairing.to_bytes()).unwrap_or_else(|e| die(&format!("couldn't write {out} ({e})")));
    }
    std::fs::set_permissions(&out, std::fs::Permissions::from_mode(0o600))
        .unwrap_or_else(|e| die(&format!("couldn't lock down {out} ({e})")));
    println!("wrote {out}");
}
