// the wifi path: pair-verify with the phone's remotepairingd and open the tunnel it
// offers, then rsd inside. the same route the launcher takes from the phone itself
// (launcher/src/lib.rs tunnel()), copied so this tool doesn't pull in xctest and friends.

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use idevice::{
    remote_pairing::{RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native},
    rsd::RsdHandshake,
    tcp::{adapter::Adapter, handle::AdapterHandle},
};

async fn within<T, E: std::fmt::Display>(
    secs: u64,
    what: &str,
    fut: impl std::future::Future<Output = Result<T, E>>,
) -> Result<T, String> {
    match tokio::time::timeout(Duration::from_secs(secs), fut).await {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => Err(format!("{what}: {e}")),
        Err(_) => Err(format!("{what}: timed out")),
    }
}

pub async fn tunnel(addr: SocketAddr, pairing: &str) -> Result<(AdapterHandle, RsdHandshake), String> {
    let bytes = std::fs::read(pairing).map_err(|e| format!("can't read pairing file {pairing} ({e})"))?;
    let mut rpf = RpPairingFile::from_bytes(&bytes)
        .map_err(|_| format!("{pairing} isn't a remote pairing file, run scripts/setup.sh"))?;

    let stream = within(8, "can't reach the phone's remote pairing service", tokio::net::TcpStream::connect(addr)).await?;
    let mut rp = RemotePairingClient::new(RpPairingSocket::new(stream), "agent");
    within(10, "remote pairing", rp.attempt_pair_verify()).await?;
    // verify only. a fresh pairing needs the trust prompt, setup does that over usb
    within(10, "pairing rejected, run scripts/setup.sh", rp.validate_pairing(&mut rpf)).await?;

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
