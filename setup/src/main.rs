// usage: pairing <out.plist> [udid]
//        pairing --list
//
// writes a pairing file the phone can use to talk to its own lockdownd later.
// the file is a full paired-host credential for that phone, so it's written 0600.
//
// over usb it makes a fresh pairing with its own host id (the phone asks to trust),
// so the app's pairing is separate from the mac's. over wifi a fresh pairing isn't
// possible, so it falls back to the mac's own record and says so.

use std::os::unix::fs::PermissionsExt;
use std::process::exit;

use idevice::{
    IdeviceService,
    lockdown::LockdownClient,
    pairing_file::PairingFile,
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
    let usb = dev.connection_type == Connection::Usb;
    println!("phone: {} ({})", dev.udid, if usb { "usb" } else { "wifi" });

    let provider = dev.to_provider(UsbmuxdAddr::default(), "agent-setup");
    let mut lockdown = LockdownClient::connect(&provider)
        .await
        .unwrap_or_else(|e| die(&format!("can't talk to the phone, unlock it and try again ({e})")));

    // keep a pairing that still works, so reruns don't pile up trusted hosts
    let mut existing = std::fs::read(&out).ok().and_then(|b| PairingFile::from_bytes(&b).ok());
    if let Some(p) = &existing
        && lockdown.start_session(p).await.is_err()
    {
        existing = None;
    }
    let mut pairing = match existing {
        Some(p) => {
            println!("existing pairing still works, keeping it");
            p
        }
        None if usb => {
            println!("making a new pairing, tap trust on the phone and enter the passcode");
            let buid = mux
                .get_buid()
                .await
                .unwrap_or_else(|e| die(&format!("can't read this mac's id ({e})")));
            let id = uuid::Uuid::new_v4().to_string().to_uppercase();
            let mut lockdown = LockdownClient::connect(&provider)
                .await
                .unwrap_or_else(|e| die(&format!("can't talk to the phone ({e})")));
            lockdown
                .pair(id, buid, Some("agent"))
                .await
                .unwrap_or_else(|e| die(&format!("pairing failed, tap trust on the phone and rerun ({e})")))
        }
        None => {
            println!("phone is on wifi, so reusing this mac's pairing. plug in a cable for a separate one");
            mux.get_pair_record(&dev.udid)
                .await
                .unwrap_or_else(|e| die(&format!("this mac isn't paired with the phone ({e})")))
        }
    };

    let mut lockdown = LockdownClient::connect(&provider)
        .await
        .unwrap_or_else(|e| die(&format!("can't talk to the phone ({e})")));
    lockdown
        .start_session(&pairing)
        .await
        .unwrap_or_else(|e| die(&format!("the phone rejected the pairing, rerun setup ({e})")));

    // lockdownd only takes "network" clients (that's the app, through its vpn) with this on
    lockdown
        .set_value(
            "EnableWifiConnections",
            plist::Value::Boolean(true),
            Some("com.apple.mobile.wireless_lockdown"),
        )
        .await
        .unwrap_or_else(|e| die(&format!("couldn't turn on network connections ({e})")));

    pairing.udid = Some(dev.udid.clone());
    let bytes = pairing
        .serialize()
        .unwrap_or_else(|e| die(&format!("couldn't encode the pairing ({e})")));
    std::fs::write(&out, bytes).unwrap_or_else(|e| die(&format!("couldn't write {out} ({e})")));
    std::fs::set_permissions(&out, std::fs::Permissions::from_mode(0o600))
        .unwrap_or_else(|e| die(&format!("couldn't lock down {out} ({e})")));
    println!("wrote {out}");
}
