// runs the launcher from a mac against a phone on the same wifi, to test the tunnel path
// without building the app. starts the real runner on the phone, ctrl+c stops it.
//
// cargo run --release --example mac -- <phone ip> <rp port> <rppairing.plist> <ddi dir> <runner bundle id>

#[tokio::main]
async fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    if a.len() != 5 {
        eprintln!("usage: mac <phone ip> <rp port> <rppairing.plist> <ddi dir> <runner bundle id>");
        std::process::exit(2);
    }
    let addr = std::net::SocketAddr::new(a[0].parse().expect("ip"), a[1].parse().expect("port"));
    launcher::set_log(Some("/dev/stderr".into()));
    // a fresh token, not the fixed "dev" one, so other apps on the phone can't use this runner
    let mut raw = [0u8; 16];
    std::io::Read::read_exact(&mut std::fs::File::open("/dev/urandom").expect("urandom"), &mut raw).expect("urandom");
    let token: String = raw.iter().map(|b| format!("{b:02x}")).collect();
    eprintln!("runner token: {token}");
    let res = launcher::run(0, addr, a[2].clone(), a[3].clone(), a[4].clone(), 8123, token).await;
    println!("{res:?}");
}
