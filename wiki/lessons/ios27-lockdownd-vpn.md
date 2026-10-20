# iOS 27: lockdownd won't take loopback vpn clients

symptom: Turn On failed with "pairing rejected, run scripts/setup.sh again: device socket io failed". rerunning setup didn't help.

what was going on (iPhone 16 Pro, iOS 27.0.1, 2026-10-20):
- the pairing file was fine. from the mac, the same file opened a lockdownd session over wifi.
- the vpn was fine too. the phone's syslog showed the app's connection arriving at lockdownd on `utun13`.
- lockdownd accepted the tcp connection, got our first 329 bytes, and reset it in `socket_accept_callback` without reading or sending anything (`tcp_drop`, RST out 1, bytes out 0). so it filters by interface or peer at accept time. a wifi peer gets in, a vpn one doesn't.
- idevice turns that reset into "device socket io failed". it also uses that text for a failed tls handshake, so the message alone doesn't tell you which.

fix: don't use lockdownd. stikdebug moved to the same path for iOS 27 (its issues #414, #476):
- a remote pairing file, made by setup over usb inside a coredevice tunnel (pin 000000 on iphones).
- on the phone: connect to remotepairingd at 10.7.0.1 (port 49152, or whatever bonjour `_remotepairing._tcp` says), pair-verify, ask it for a tunnel listener, tls-psk + cdtunnel, then rsd inside.
- every service has an rsd name: lockdown.remote.trusted (no session needed), image mounter, installation_proxy, heartbeat, testmanagerd, dtservicehub.
- idevice's XCUITestService only knew how to get testmanagerd through lockdownd, hence the small run_rsd patch in the vendored copy.

how to look next time:
- `setup/target/release/phonelog <udid> "lockdownd|remotepairingd|Agent[|Agent("` while tapping Turn On. the kernel's tcp lines show which side closed and how.
- `launcher/examples/mac.rs` runs the whole start from the mac over wifi. if that works and the phone doesn't, the difference is the vpn hop.
- the app writes `launcher.log` next to its pairing file (Application Support). `xcrun devicectl device copy from --domain-type appDataContainer` pulls it.
