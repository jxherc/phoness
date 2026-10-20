// usage: cargo run --release -- <out.plist>
// phone has to trust this mac. cable is best, wifi works if xcode already pairs over network.

use idevice::{
    IdeviceService,
    lockdown::LockdownClient,
    usbmuxd::{Connection, UsbmuxdAddr, UsbmuxdConnection},
};

#[tokio::main]
async fn main() {
    let out = std::env::args().nth(1).unwrap_or("pairing.plist".into());

    let mut mux = UsbmuxdConnection::default().await.expect("can't reach usbmuxd");
    let mut devs = mux.get_devices().await.expect("can't list devices");
    // cable first
    devs.sort_by_key(|d| d.connection_type != Connection::Usb);
    let dev = devs.into_iter().next().expect("no phone found. plug it in and unlock it");
    println!("phone: {}", dev.udid);

    let provider = dev.to_provider(UsbmuxdAddr::default(), "agent-setup");
    let mut lockdown = LockdownClient::connect(&provider).await.expect("lockdown");

    // reuse the mac's pairing if there is one, otherwise pair fresh (phone asks to trust)
    let mut pairing = match mux.get_pair_record(&dev.udid).await {
        Ok(p) => p,
        Err(_) => {
            println!("no pairing yet, tap trust on the phone");
            let buid = mux.get_buid().await.expect("buid");
            let id = uuid::Uuid::new_v4().to_string().to_uppercase();
            lockdown.pair(id, buid, Some("agent")).await.expect("pairing failed")
        }
    };

    lockdown.start_session(&pairing).await.expect("pairing rejected");

    // lockdownd only takes "network" clients (that's us, through the vpn) with this on
    lockdown
        .set_value(
            "EnableWifiConnections",
            plist::Value::Boolean(true),
            Some("com.apple.mobile.wireless_lockdown"),
        )
        .await
        .expect("couldn't turn on network connections");

    pairing.udid = Some(dev.udid.clone());
    std::fs::write(&out, pairing.serialize().expect("serialize")).expect("write");
    println!("wrote {out}");
}
