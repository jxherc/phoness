// streams the phone's syslog, filtered. for watching the app, runner and vpn while testing.
// usage: phonelog <udid> [word|word|...]

use idevice::{
    IdeviceService,
    syslog_relay::SyslogRelayClient,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
};

#[tokio::main]
async fn main() {
    let udid = std::env::args().nth(1).expect("usage: phonelog <udid> [word|word]");
    let words: Vec<String> = std::env::args()
        .nth(2)
        .map(|w| w.split('|').map(String::from).collect())
        .unwrap_or_default();

    let mut mux = UsbmuxdConnection::default().await.expect("usbmuxd");
    let dev = mux.get_device(&udid).await.expect("that phone isn't connected");
    let provider = dev.to_provider(UsbmuxdAddr::default(), "phonelog");
    let mut log = SyslogRelayClient::connect(&provider).await.expect("syslog relay");
    loop {
        let Ok(line) = log.next().await else { break };
        if words.is_empty() || words.iter().any(|w| line.contains(w.as_str())) {
            println!("{line}");
        }
    }
}
