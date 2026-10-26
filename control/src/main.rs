// drive the phone from the mac, over usb or wifi. no on-device app, no vpn.
// usb when usbmuxd sees the phone. otherwise wifi straight to its remotepairingd with the
// pairing file setup.sh made: PHONE_IP=192.168.2.103 phone shot s.png
//
//   phone serve                 read commands on stdin, one per line (for an agent)
//   phone mcp                   the same commands as an mcp server, for claude code
//   phone shot out.png          save a screenshot and print its size
//   phone tap 200 400           tap at pixel 200,400 (of the last/again-taken screenshot)
//   phone swipe 200 600 200 200 swipe between two pixels
//   phone text "hello"          type on the keyboard
//   phone key return            press one key (return, esc, up, ... or 0x04)
//   phone button lock           press a hardware button (lock, home, volume-up, siri, ...)
//   phone info                  udid + screen size
//
// coords are screen pixels by default (matched to the screenshot). add a trailing
// `n` to a command (tapn, swipen) for raw 0-65535 hid coordinates.
//
// works with the phone on the lock screen: it can wake it, swipe, tap and press
// buttons there. it can't enter or get past the passcode, and nothing in software can.

mod mcp;
mod stream;
mod wifi;

use std::io::Write as _;

use idevice::{
    IdeviceService, RsdService,
    core_device::{
        ImageFormat, IndigoHidClient, ScreenCaptureServiceClient, UniversalHidServiceClient,
        hid::ButtonState,
    },
    core_device_proxy::CoreDeviceProxy,
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
};
use tokio::io::{AsyncBufReadExt, BufReader};

type Hid = UniversalHidServiceClient<Box<dyn idevice::ReadWrite>>;
type Indigo = IndigoHidClient<Box<dyn idevice::ReadWrite>>;

const MAX: f64 = 65535.0;

// named hardware buttons -> (usage_page, usage_code, hold_ms)
const BUTTONS: &[(&str, u64, u64, u64)] = &[
    ("home", 0x0C, 0x40, 80),
    ("power", 0x0C, 0x30, 200),
    ("lock", 0x0C, 0x30, 200),
    ("sleep", 0x0C, 0x30, 200),
    ("wake", 0x0C, 0x30, 120),
    ("volume-up", 0x0C, 0xE9, 80),
    ("volume-down", 0x0C, 0xEA, 80),
    ("mute", 0x0C, 0xE2, 80),
    ("siri", 0x0C, 0xCF, 1200),
];

struct Phone {
    adapter: AdapterHandle,
    handshake: RsdHandshake,
    // the media stream authenticates synthetic input. only started once input is sent
    // (a screenshot doesn't need it), then kept open so later taps have no setup cost.
    media: Option<stream::ScreenMediaStream>,
    touch: Option<Hid>,
    keys: Option<Indigo>,
    udid: String,
    // cached from the last screenshot, for pixel -> normalized
    size: Option<(u32, u32)>,
}

impl Phone {
    // usb when usbmuxd sees the phone (plugged in, or wifi sync while it's awake),
    // otherwise wifi straight to remotepairingd, which keeps answering while it's locked
    async fn connect(udid: Option<String>) -> Result<Phone, String> {
        // with no UDID, the phone scripts/setup.sh paired (usbmuxd lists ipads too)
        let udid = udid.or_else(paired_udid);
        let (adapter, handshake, udid, via) = match usb(udid.as_deref()).await {
            Some((adapter, handshake, udid)) => (adapter, handshake, udid, "usb"),
            None => {
                let udid = udid.ok_or("no phone plugged in and no pairing file in .pairing/. run scripts/setup.sh first")?;
                let (adapter, handshake) = wifi(&udid).await?;
                (adapter, handshake, udid, "wifi")
            }
        };
        eprintln!("connected over {via}");
        if via == "wifi" {
            // remote pairing here doesn't check the phone's own key, so a host on the same
            // network could stand in for it. fine at home, use usb on networks you don't trust
            eprintln!("note: wifi doesn't verify it's really your phone. use usb on untrusted networks");
        }
        Ok(Phone { adapter, handshake, media: None, touch: None, keys: None, udid, size: None })
    }

    // start the media stream auth gate and connect the input services, once.
    async fn ensure_input(&mut self) -> Result<(), String> {
        if self.media.is_some() {
            return Ok(());
        }
        let media = stream::start(&mut self.adapter, &mut self.handshake, 1).await.map_err(|e| {
            if e.contains("9022") || e.contains("call is currently in progress") {
                format!("{e}\nthe phone won't share its screen while a call or another mirroring/recording session is active. end it and retry")
            } else if e.starts_with("no display service") {
                format!("{e}\nneeds the developer disk image mounted. open this phone in xcode once, then retry")
            } else {
                // seen once: a session from the previous run was still closing. the retry worked
                format!("{e}\nretry in a few seconds")
            }
        })?;
        // backboardd needs a beat to match the hid surfaces to the new stream
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        self.touch = Some(
            UniversalHidServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake)
                .await
                .map_err(|e| format!("no touch service ({e})"))?,
        );
        self.keys = Some(
            IndigoHidClient::connect_rsd(&mut self.adapter, &mut self.handshake)
                .await
                .map_err(|e| format!("no keyboard/button service ({e})"))?,
        );
        self.media = Some(media);
        Ok(())
    }

    async fn screenshot(&mut self) -> Result<Vec<u8>, String> {
        let mut cap = ScreenCaptureServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake)
            .await
            .map_err(|e| format!("no screen capture service ({e})"))?;
        let png = cap
            .take_screenshot(None, ImageFormat::Png)
            .await
            .map_err(|e| format!("screenshot failed ({e})"))?;
        if let Some(wh) = png_size(&png) {
            self.size = Some(wh);
        }
        Ok(png)
    }

    // pixel -> 0-65535, using the cached screenshot size (take one if we have none yet)
    async fn norm(&mut self, x: f64, y: f64) -> Result<(u16, u16), String> {
        if self.size.is_none() {
            self.screenshot().await?;
        }
        let (w, h) = self.size.ok_or("don't know the screen size yet")?;
        let nx = (x / w as f64 * MAX).round().clamp(0.0, MAX) as u16;
        let ny = (y / h as f64 * MAX).round().clamp(0.0, MAX) as u16;
        Ok((nx, ny))
    }

    async fn tap(&mut self, x: u16, y: u16) -> Result<(), String> {
        self.ensure_input().await?;
        self.touch.as_mut().unwrap().tap(x, y).await.map_err(|e| format!("tap ({e})"))
    }

    async fn swipe(&mut self, x1: u16, y1: u16, x2: u16, y2: u16) -> Result<(), String> {
        self.ensure_input().await?;
        // 30 frames over ~0.6s reads as a deliberate drag, not a flick
        self.touch.as_mut().unwrap().drag(x1, y1, x2, y2, 30, 20).await.map_err(|e| format!("swipe ({e})"))
    }

    async fn text(&mut self, s: &str) -> Result<usize, String> {
        let mut n = 0;
        for c in s.chars() {
            if let Some((usage, shift)) = ascii_to_usage(c) {
                self.type_key(usage, shift).await?;
                n += 1;
            }
        }
        Ok(n)
    }

    async fn type_key(&mut self, usage: u64, shift: bool) -> Result<(), String> {
        const LSHIFT: u64 = 0xE1;
        self.ensure_input().await?;
        let keys = self.keys.as_mut().unwrap();
        if shift {
            keys.send_keyboard(LSHIFT, ButtonState::Down).await.map_err(|e| e.to_string())?;
        }
        keys.send_keyboard(usage, ButtonState::Down).await.map_err(|e| e.to_string())?;
        keys.send_keyboard(usage, ButtonState::Up).await.map_err(|e| e.to_string())?;
        if shift {
            keys.send_keyboard(LSHIFT, ButtonState::Up).await.map_err(|e| e.to_string())?;
        }
        tokio::time::sleep(std::time::Duration::from_millis(12)).await;
        Ok(())
    }

    async fn button(&mut self, name: &str) -> Result<(), String> {
        let (_, page, code, hold) = *BUTTONS
            .iter()
            .find(|(n, ..)| *n == name)
            .ok_or_else(|| format!("unknown button '{name}'. try: {}", button_names()))?;
        self.ensure_input().await?;
        let keys = self.keys.as_mut().unwrap();
        keys.send_button(page, code, ButtonState::Down).await.map_err(|e| e.to_string())?;
        tokio::time::sleep(std::time::Duration::from_millis(hold)).await;
        keys.send_button(page, code, ButtonState::Up).await.map_err(|e| e.to_string())?;
        Ok(())
    }
}

// setup.sh keeps one remote pairing file per phone in the repo's .pairing/
const PAIRING_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../.pairing");

fn paired_udid() -> Option<String> {
    let files: Vec<String> = std::fs::read_dir(PAIRING_DIR)
        .ok()?
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter_map(|n| n.strip_suffix(".plist").map(String::from))
        .collect();
    // more than one phone: make them say which with UDID
    if files.len() == 1 { files.into_iter().next() } else { None }
}

// None when usbmuxd doesn't list the phone, or the usb tunnel won't open
async fn usb(udid: Option<&str>) -> Option<(AdapterHandle, RsdHandshake, String)> {
    let mut mux = UsbmuxdConnection::default().await.ok()?;
    let devs = mux.get_devices().await.ok()?;
    let dev = match udid {
        Some(want) => devs.into_iter().find(|d| d.udid == want)?,
        None => devs.into_iter().next()?,
    };
    let provider = dev.to_provider(UsbmuxdAddr::default(), "phone-control");
    let attempt = async {
        let proxy = CoreDeviceProxy::connect(&provider).await.map_err(|e| e.to_string())?;
        let rsd_port = proxy.tunnel_info().server_rsd_port;
        let mut adapter = proxy.create_software_tunnel().map_err(|e| e.to_string())?.to_async_handle();
        let rsd = adapter.connect(rsd_port).await.map_err(|e| e.to_string())?;
        let handshake = RsdHandshake::new(rsd).await.map_err(|e| e.to_string())?;
        Ok::<_, String>((adapter, handshake))
    };
    match tokio::time::timeout(std::time::Duration::from_secs(10), attempt).await {
        Ok(Ok((adapter, handshake))) => Some((adapter, handshake, dev.udid)),
        Ok(Err(e)) => {
            eprintln!("usb tunnel failed ({e}), trying wifi");
            None
        }
        Err(_) => {
            eprintln!("usb tunnel timed out, trying wifi");
            None
        }
    }
}

async fn wifi(udid: &str) -> Result<(AdapterHandle, RsdHandshake), String> {
    let host = std::env::var("PHONE_IP").map_err(|_| {
        "phone isn't plugged in. for wifi set PHONE_IP to its address \
         (Settings > Wi-Fi > (i) on the phone), or plug it in"
            .to_string()
    })?;
    let port: u16 = std::env::var("PHONE_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(49152);
    let pairing = std::env::var("PHONE_PAIRING").unwrap_or_else(|_| format!("{PAIRING_DIR}/{udid}.plist"));
    // a hostname like Erics-iPhone.local works too, macos resolves .local itself
    let addr = tokio::net::lookup_host((host.as_str(), port))
        .await
        .map_err(|e| format!("can't resolve {host} ({e})"))?
        .next()
        .ok_or_else(|| format!("can't resolve {host}"))?;
    wifi::tunnel(addr, &pairing).await
}

fn button_names() -> String {
    BUTTONS.iter().map(|(n, ..)| *n).collect::<Vec<_>>().join(", ")
}

// png width/height from the IHDR chunk
fn png_size(b: &[u8]) -> Option<(u32, u32)> {
    if b.len() < 24 || &b[..8] != b"\x89PNG\r\n\x1a\n" {
        return None;
    }
    let w = u32::from_be_bytes(b[16..20].try_into().ok()?);
    let h = u32::from_be_bytes(b[20..24].try_into().ok()?);
    Some((w, h))
}

fn json_ok(fields: &str) -> String {
    if fields.is_empty() { "{\"ok\":true}".into() } else { format!("{{\"ok\":true,{fields}}}") }
}

fn json_err(msg: &str) -> String {
    format!("{{\"ok\":false,\"error\":{}}}", serde_json::Value::String(msg.into()))
}

// one command line -> one json line. the agent reads these.
async fn run(phone: &mut Phone, line: &str) -> String {
    let mut it = line.split_whitespace();
    let Some(cmd) = it.next() else { return json_ok("") };
    let rest: Vec<&str> = it.collect();

    let num = |s: &str| s.parse::<f64>().ok();

    match cmd {
        "shot" | "screenshot" => {
            let path = rest.first().copied().unwrap_or("screen.png");
            // only png files, so a bad command line can't clobber some other file
            if !path.to_ascii_lowercase().ends_with(".png") {
                return json_err("shot only writes .png files");
            }
            match phone.screenshot().await {
                Ok(png) => match std::fs::write(path, &png) {
                    Ok(_) => {
                        let (w, h) = phone.size.unwrap_or((0, 0));
                        json_ok(&format!("\"path\":{},\"w\":{w},\"h\":{h},\"bytes\":{}",
                            serde_json::Value::String(path.into()), png.len()))
                    }
                    Err(e) => json_err(&format!("write {path}: {e}")),
                },
                Err(e) => json_err(&e),
            }
        }
        "tap" | "tapn" => {
            let (Some(x), Some(y)) = (rest.first().and_then(|s| num(s)), rest.get(1).and_then(|s| num(s)))
            else { return json_err("usage: tap <x> <y>") };
            let (nx, ny) = if cmd == "tapn" {
                (x.clamp(0.0, MAX) as u16, y.clamp(0.0, MAX) as u16)
            } else {
                match phone.norm(x, y).await { Ok(v) => v, Err(e) => return json_err(&e) }
            };
            match phone.tap(nx, ny).await { Ok(_) => json_ok(""), Err(e) => json_err(&e) }
        }
        "swipe" | "swipen" => {
            let a: Vec<f64> = rest.iter().filter_map(|s| num(s)).collect();
            if a.len() < 4 { return json_err("usage: swipe <x1> <y1> <x2> <y2>") }
            let (p1, p2) = if cmd == "swipen" {
                ((a[0] as u16, a[1] as u16), (a[2] as u16, a[3] as u16))
            } else {
                let p1 = match phone.norm(a[0], a[1]).await { Ok(v) => v, Err(e) => return json_err(&e) };
                let p2 = match phone.norm(a[2], a[3]).await { Ok(v) => v, Err(e) => return json_err(&e) };
                (p1, p2)
            };
            match phone.swipe(p1.0, p1.1, p2.0, p2.1).await { Ok(_) => json_ok(""), Err(e) => json_err(&e) }
        }
        "text" | "type" => {
            // everything after the command, spaces kept
            let s = line[cmd.len()..].trim_start();
            match phone.text(s).await {
                Ok(n) => json_ok(&format!("\"typed\":{n}")),
                Err(e) => json_err(&e),
            }
        }
        "key" => {
            let Some(name) = rest.first() else { return json_err("usage: key <name|0xNN>") };
            let Some(usage) = parse_key(name) else { return json_err(&format!("unknown key '{name}'")) };
            match phone.type_key(usage, false).await { Ok(_) => json_ok(""), Err(e) => json_err(&e) }
        }
        "button" | "press" => {
            let Some(name) = rest.first() else { return json_err(&format!("usage: button <{}>", button_names())) };
            match phone.button(name).await { Ok(_) => json_ok(""), Err(e) => json_err(&e) }
        }
        "info" => {
            if phone.size.is_none() { let _ = phone.screenshot().await; }
            let (w, h) = phone.size.unwrap_or((0, 0));
            json_ok(&format!("\"udid\":{},\"w\":{w},\"h\":{h}", serde_json::Value::String(phone.udid.clone())))
        }
        "quit" | "exit" => json_ok("\"bye\":true"),
        other => json_err(&format!("unknown command '{other}'")),
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let udid = std::env::var("UDID").ok();

    // mcp connects on the first tool call, so claude code can start it with the phone unplugged
    if args.first().is_some_and(|a| a == "mcp") {
        mcp::serve(udid).await;
        return;
    }

    let mut phone = match Phone::connect(udid).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    };

    // one-shot: `phone tap 10 20` runs the one command and exits
    if let Some(first) = args.first()
        && first != "serve"
    {
        println!("{}", run(&mut phone, &args.join(" ")).await);
        return;
    }

    // serve: a command per line on stdin, a json line per command on stdout.
    // the media stream stays open the whole time, so taps land with no per-tap setup.
    eprintln!("ready. commands: shot <path> | tap x y | swipe x1 y1 x2 y2 | text ... | key <k> | button <b> | info | quit");
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut stdout = std::io::stdout();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let res = run(&mut phone, line).await;
        let quit = line == "quit" || line == "exit";
        let _ = writeln!(stdout, "{res}");
        let _ = stdout.flush();
        if quit {
            break;
        }
    }
}

// ascii -> hid keyboard usage + shift (us layout)
fn ascii_to_usage(c: char) -> Option<(u64, bool)> {
    Some(match c {
        'a'..='z' => (0x04 + (c as u64 - 'a' as u64), false),
        'A'..='Z' => (0x04 + (c as u64 - 'A' as u64), true),
        '1'..='9' => (0x1E + (c as u64 - '1' as u64), false),
        '0' => (0x27, false),
        '\n' => (0x28, false),
        '\t' => (0x2B, false),
        ' ' => (0x2C, false),
        '!' => (0x1E, true),
        '@' => (0x1F, true),
        '#' => (0x20, true),
        '$' => (0x21, true),
        '%' => (0x22, true),
        '^' => (0x23, true),
        '&' => (0x24, true),
        '*' => (0x25, true),
        '(' => (0x26, true),
        ')' => (0x27, true),
        '-' => (0x2D, false),
        '_' => (0x2D, true),
        '=' => (0x2E, false),
        '+' => (0x2E, true),
        '[' => (0x2F, false),
        '{' => (0x2F, true),
        ']' => (0x30, false),
        '}' => (0x30, true),
        '\\' => (0x31, false),
        '|' => (0x31, true),
        ';' => (0x33, false),
        ':' => (0x33, true),
        '\'' => (0x34, false),
        '"' => (0x34, true),
        '`' => (0x35, false),
        '~' => (0x35, true),
        ',' => (0x36, false),
        '<' => (0x36, true),
        '.' => (0x37, false),
        '>' => (0x37, true),
        '/' => (0x38, false),
        '?' => (0x38, true),
        _ => return None,
    })
}

fn parse_key(name: &str) -> Option<u64> {
    Some(match name.to_ascii_lowercase().as_str() {
        "return" | "enter" => 0x28,
        "esc" | "escape" => 0x29,
        "backspace" => 0x2A,
        "delete" | "del" => 0x4C,
        "tab" => 0x2B,
        "space" => 0x2C,
        "right" => 0x4F,
        "left" => 0x50,
        "down" => 0x51,
        "up" => 0x52,
        "home" => 0x4A,
        "end" => 0x4D,
        "pageup" => 0x4B,
        "pagedown" => 0x4E,
        other => {
            return other
                .strip_prefix("0x")
                .and_then(|h| u64::from_str_radix(h, 16).ok())
                .or_else(|| other.parse::<u64>().ok());
        }
    })
}
