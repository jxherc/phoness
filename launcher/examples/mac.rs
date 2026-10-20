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
    let res = launcher::run(0, addr, a[2].clone(), a[3].clone(), a[4].clone(), 8123, "dev".into()).await;
    println!("{res:?}");
}
