// `phone mcp`: the same commands as an mcp server on stdin/stdout, for claude code.
// it connects on the first tool call, so it starts fine with the phone unplugged.
// screenshots go back as images, already shrunk to a size the model sees 1:1, and
// tap/swipe take coords in that image's pixels. the model can't scale coords itself.

use std::collections::HashMap;
use std::io::Write as _;

use base64::Engine as _;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, BufReader};

use super::{BUTTONS, MAX, Phone, devices, none_around, parse_key, pick};

// claude's standard image limits: 1568 px on the long edge and 1568 visual tokens of 28x28 px.
// anything bigger gets shrunk again before the model sees it, and then its coords stop matching
// ours. newer models take more, but every model sees an image under these 1:1
const VIEW: u32 = 1568;
const TOKENS: u32 = 1568;

const INSTRUCTIONS: &str = "drives the user's real iphone or ipad from this mac. take a screenshot before \
acting and again after anything that changes the screen. tap and swipe coords are pixels of the last \
screenshot of that device. with both around, pass device (iphone or ipad); later calls stay on it. \
it can't get past the passcode, so ask the user to unlock it. input fails during a call or while the \
screen is being recorded; screenshots still work then.";

#[derive(Default)]
struct Dev {
    phone: Option<Phone>,
    // size of the last image sent, for image pixels -> 0-65535
    view: Option<(u32, u32)>,
}

#[derive(Default)]
struct State {
    // UDID from the environment pins one device
    udid: Option<String>,
    // the device of the last call and its kind, so calls without `device` stay on it
    last: Option<(String, Option<String>)>,
    devs: HashMap<String, Dev>,
}

pub async fn serve(udid: Option<String>) {
    let mut st = State { udid, ..Default::default() };
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut stdout = std::io::stdout();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        // notifications (no id) get no reply
        let (Some(id), Some(method)) = (msg.get("id"), msg["method"].as_str()) else { continue };
        let mut reply = match method {
            "initialize" => json!({ "result": {
                // tools only, which hasn't changed between versions, so take the client's
                "protocolVersion": msg["params"]["protocolVersion"].as_str().unwrap_or("2025-06-18"),
                "capabilities": { "tools": {} },
                "serverInfo": { "name": "phone", "version": env!("CARGO_PKG_VERSION") },
                "instructions": INSTRUCTIONS,
            }}),
            "ping" => json!({ "result": {} }),
            "tools/list" => json!({ "result": { "tools": tools() } }),
            "tools/call" => {
                let p = &msg["params"];
                match call(&mut st, p["name"].as_str().unwrap_or(""), &p["arguments"]).await {
                    Ok(content) => json!({ "result": { "content": content } }),
                    Err(e) => json!({ "result": { "content": [text(&e)], "isError": true } }),
                }
            }
            _ => json!({ "error": { "code": -32601, "message": format!("unknown method {method}") } }),
        };
        reply["jsonrpc"] = json!("2.0");
        reply["id"] = id.clone();
        let _ = writeln!(stdout, "{reply}");
        let _ = stdout.flush();
    }
}

fn tools() -> Value {
    let xy = |d: &str| json!({ "type": "number", "description": d });
    let buttons: Vec<&str> = BUTTONS.iter().map(|(n, ..)| *n).collect();
    let device = json!({
        "type": "string", "enum": ["iphone", "ipad"],
        "description": "which device, when both are around. later calls stay on it",
    });
    let mut tools = json!([
        {
            "name": "screenshot",
            "description": "screenshot the phone. tap and swipe coords are pixels of this image.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "readOnlyHint": true },
        },
        {
            "name": "tap",
            "description": "tap a point on the last screenshot.",
            "inputSchema": { "type": "object", "properties": {
                "x": xy("pixels from the left of the last screenshot"),
                "y": xy("pixels from the top of the last screenshot"),
            }, "required": ["x", "y"] },
        },
        {
            "name": "swipe",
            "description": "drag between two points on the last screenshot over ~0.6s, so it scrolls instead of flicking. to scroll down, swipe from low to high.",
            "inputSchema": { "type": "object", "properties": {
                "x1": xy("start"), "y1": xy("start"), "x2": xy("end"), "y2": xy("end"),
            }, "required": ["x1", "y1", "x2", "y2"] },
        },
        {
            "name": "text",
            "description": "type on the phone's keyboard. us layout ascii only, no emoji. tap a text field first.",
            "inputSchema": { "type": "object", "properties": {
                "text": { "type": "string" },
            }, "required": ["text"] },
        },
        {
            "name": "key",
            "description": "press one key: return, esc, tab, space, backspace, delete, up, down, left, right, or a hex hid usage like 0x04.",
            "inputSchema": { "type": "object", "properties": {
                "key": { "type": "string" },
            }, "required": ["key"] },
        },
        {
            "name": "button",
            "description": "press a hardware button.",
            "inputSchema": { "type": "object", "properties": {
                "name": { "type": "string", "enum": buttons },
            }, "required": ["name"] },
        },
        {
            "name": "info",
            "description": "the iphones and ipads around (kind and udid), and the real screen size of the one in use.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "readOnlyHint": true },
        },
    ]);
    for t in tools.as_array_mut().unwrap() {
        t["inputSchema"]["properties"]["device"] = device.clone();
    }
    tools
}

fn text(s: &str) -> Value {
    json!({ "type": "text", "text": s })
}

// which device this call is for: UDID from the environment, then `device`, then the last one,
// then the only one around
async fn target(st: &State, want: Option<&str>) -> Result<(String, Option<String>), String> {
    if let Some(u) = &st.udid {
        return Ok((u.clone(), None));
    }
    if let Some((u, kind)) = &st.last
        && (want.is_none() || want == kind.as_deref())
    {
        return Ok((u.clone(), kind.clone()));
    }
    let udid = pick(None, want, "device: iphone or ipad").await?;
    let kind = match want {
        Some(k) => Some(k.to_string()),
        None => devices().await.into_iter().find(|(u, _)| *u == udid).and_then(|(_, k)| k),
    };
    Ok((udid, kind))
}

// info lists what's around instead of failing when it can't tell which one is meant
async fn info(st: &mut State, want: Option<&str>) -> Result<Vec<Value>, String> {
    let found = devices().await;
    let mut lines: Vec<String> =
        found.iter().map(|(u, k)| format!("{} {u}", k.as_deref().unwrap_or("device"))).collect();
    if lines.is_empty() {
        return Err(none_around());
    }
    // the size needs a connection. if that fails, still show what's around
    match target(st, want).await {
        Ok((udid, kind)) => match size(st, &udid).await {
            Ok((w, h)) => {
                lines.push(format!("in use: {udid}, screen {w}x{h}"));
                st.last = Some((udid, kind));
            }
            Err(e) => lines.push(format!("{udid}: {e}")),
        },
        Err(e) => lines.push(e),
    }
    Ok(vec![text(&lines.join("\n"))])
}

async fn size(st: &mut State, udid: &str) -> Result<(u32, u32), String> {
    let dev = st.devs.entry(udid.to_string()).or_default();
    if dev.phone.is_none() {
        dev.phone = Some(Phone::connect(udid.to_string()).await?);
    }
    let phone = dev.phone.as_mut().unwrap();
    if phone.size.is_none()
        && let Err(e) = phone.screenshot().await
    {
        dev.phone = None;
        return Err(e);
    }
    Ok(phone.size.unwrap_or((0, 0)))
}

async fn call(st: &mut State, name: &str, a: &Value) -> Result<Vec<Value>, String> {
    let num = |k: &str| a[k].as_f64().ok_or(format!("{k} must be a number"));
    let s = |k: &str| a[k].as_str().ok_or(format!("{k} must be a string"));
    let want = match a["device"].as_str() {
        Some(k @ ("iphone" | "ipad")) => Some(k),
        Some(other) => return Err(format!("device is iphone or ipad, not '{other}'")),
        None => None,
    };
    if name == "info" {
        return info(st, want).await;
    }
    if !["screenshot", "tap", "swipe", "text", "key", "button"].contains(&name) {
        return Err(format!("unknown tool '{name}'"));
    }
    let (udid, kind) = target(st, want).await?;
    let view = st.devs.get(&udid).and_then(|d| d.view);
    // image pixels -> 0-65535
    let norm = |x: f64, y: f64| {
        let (w, h) = view.ok_or("take a screenshot of this device first. tap and swipe coords are pixels of it")?;
        let n = |v: f64, size: u32| (v / size as f64 * MAX).round().clamp(0.0, MAX) as u16;
        Ok::<_, String>((n(x, w), n(y, h)))
    };

    // check the arguments before touching the phone
    let pts = match name {
        "tap" => vec![norm(num("x")?, num("y")?)?],
        "swipe" => vec![norm(num("x1")?, num("y1")?)?, norm(num("x2")?, num("y2")?)?],
        _ => vec![],
    };
    let usage = match name {
        "key" => parse_key(s("key")?).ok_or(format!("unknown key '{}'", s("key")?))?,
        _ => 0,
    };

    let dev = st.devs.entry(udid.clone()).or_default();
    if dev.phone.is_none() {
        dev.phone = Some(Phone::connect(udid.clone()).await?);
    }
    let label = kind.clone().unwrap_or("device".into());
    st.last = Some((udid, kind));
    let phone = dev.phone.as_mut().unwrap();
    let ok = |_| vec![text("ok")];
    let res = match name {
        "screenshot" => shot(phone, &mut dev.view, &label).await,
        "tap" => phone.tap(pts[0].0, pts[0].1).await.map(ok),
        "swipe" => phone.swipe(pts[0].0, pts[0].1, pts[1].0, pts[1].1).await.map(ok),
        "text" => phone.text(s("text")?).await.map(|n| vec![text(&format!("typed {n} characters"))]),
        "key" => phone.type_key(usage, false).await.map(ok),
        _ => phone.button(s("name")?).await.map(ok),
    };
    // a dead usb or wifi link never comes back on its own, so connect fresh next call
    if res.is_err() {
        dev.phone = None;
    }
    res
}

async fn shot(phone: &mut Phone, view: &mut Option<(u32, u32)>, kind: &str) -> Result<Vec<Value>, String> {
    let png = phone.screenshot().await?;
    let (w, h) = phone.size.ok_or("the screenshot wasn't a png")?;
    let (jpg, vw, vh) = shrink(&png, w, h)?;
    *view = Some((vw, vh));
    Ok(vec![
        json!({ "type": "image", "data": base64::engine::general_purpose::STANDARD.encode(&jpg), "mimeType": "image/jpeg" }),
        text(&format!("{vw}x{vh} image of the {kind}'s {w}x{h} screen. tap and swipe use this image's pixels")),
    ])
}

// the biggest size under both limits. a phone only hits the long edge, an ipad the tokens too
fn fit(w: u32, h: u32) -> (u32, u32) {
    let size = |k: f64| ((w as f64 * k).round() as u32, (h as f64 * k).round() as u32);
    let mut k = (VIEW as f64 / w.max(h) as f64).min(1.0);
    while { let (a, b) = size(k); a.div_ceil(28) * b.div_ceil(28) > TOKENS } {
        k *= 0.995;
    }
    size(k)
}

// png -> jpeg at fit()'s size. sips ships with macos, so no image crate
fn shrink(png: &[u8], w: u32, h: u32) -> Result<(Vec<u8>, u32, u32), String> {
    let (vw, vh) = fit(w, h);

    let tmp = std::env::temp_dir();
    let (src, dst) = (tmp.join(format!("phone-mcp-{}.png", std::process::id())),
                      tmp.join(format!("phone-mcp-{}.jpg", std::process::id())));
    std::fs::write(&src, png).map_err(|e| format!("write {}: {e}", src.display()))?;
    let out = std::process::Command::new("sips")
        .args(["-s", "format", "jpeg", "-s", "formatOptions", "80", "-z", &vh.to_string(), &vw.to_string()])
        .arg(&src).arg("--out").arg(&dst)
        .output()
        .map_err(|e| format!("sips: {e}"))?;
    let _ = std::fs::remove_file(&src);
    if !out.status.success() {
        return Err(format!("sips failed: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    let jpg = std::fs::read(&dst).map_err(|e| format!("read {}: {e}", dst.display()))?;
    let _ = std::fs::remove_file(&dst);
    Ok((jpg, vw, vh))
}

#[cfg(test)]
mod tests {
    #[test]
    fn fit_stays_under_both_limits() {
        // 16 pro, 16 pro max, 11-inch and 13-inch ipads, and one already small enough
        for (w, h) in [(1206, 2622), (1320, 2868), (1668, 2420), (2064, 2752), (600, 800)] {
            let (a, b) = super::fit(w, h);
            assert!(a.max(b) <= super::VIEW, "{w}x{h} -> {a}x{b}");
            assert!(a.div_ceil(28) * b.div_ceil(28) <= super::TOKENS, "{w}x{h} -> {a}x{b}");
            // same shape, give or take rounding
            assert!((a as f64 / b as f64 - w as f64 / h as f64).abs() < 0.01, "{w}x{h} -> {a}x{b}");
        }
        assert_eq!(super::fit(1206, 2622), (721, 1568));
        assert_eq!(super::fit(600, 800), (600, 800));
    }

    // a phone-sized png made from a system icon, shrunk the way screenshots are
    #[test]
    fn shrink_keeps_the_size_it_reports() {
        let icon = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns";
        let png = std::env::temp_dir().join("phone-mcp-test.png");
        let ok = std::process::Command::new("sips")
            .args(["-s", "format", "png", "-z", "2622", "1206", icon, "--out"])
            .arg(&png)
            .output()
            .unwrap()
            .status
            .success();
        assert!(ok);
        let (jpg, w, h) = super::shrink(&std::fs::read(&png).unwrap(), 1206, 2622).unwrap();
        let _ = std::fs::remove_file(&png);
        assert_eq!((w, h), (721, 1568));
        assert_eq!(&jpg[..2], b"\xff\xd8");
        // jpeg SOF0 holds the real height and width
        let sof = jpg.windows(2).position(|b| b == b"\xff\xc0").unwrap();
        let dim = |i: usize| u16::from_be_bytes([jpg[sof + i], jpg[sof + i + 1]]) as u32;
        assert_eq!((dim(7), dim(5)), (w, h));
    }
}
