---
name: phone
description: drive a real iphone from this mac with the `phone` cli. take screenshots, tap, swipe, type text, press keys and hardware buttons. use it when the user wants to test or use an app on their physical iphone, see what's on the phone's screen, or says things like "screenshot my phone", "tap that on the iphone", "open discord on my phone", "type this on the phone", "go to the home screen".
---

# phone

`phone` controls the iphone from the mac, over usb when it's plugged in and over wifi when it isn't. no app on the phone.

## running it

use `phone` if it's on PATH. if not, it's `control/target/release/phone` in a checkout of the repo this plugin comes from (github.com/jxherc/phoness). build it with `cargo build --release` in `control/`. the plugin doesn't ship the binary.

- usb is picked when the phone is plugged in. for wifi, set `PHONE_IP` to the phone's address or `.local` name: `PHONE_IP=192.168.2.103 phone info`
- with more than one paired phone, set `UDID=<udid>`
- each call prints one json line: `{"ok":true,...}` or `{"ok":false,"error":"..."}`. read the error, it says what to fix

## commands

coords are screen **pixels** by default, matched to the last screenshot. add `n` (tapn, swipen) for raw 0-65535 hid coordinates.

- `shot [path]` screenshot to png (default `screen.png`, the path must end in `.png`), prints its pixel size
- `tap x y` / `tapn x y`
- `swipe x1 y1 x2 y2` / `swipen ...` (a real drag, ~0.6s, so it scrolls instead of flicking)
- `text "hello world"` type on the keyboard (us layout, ascii)
- `key <name|0xNN>` one key: return, esc, tab, space, backspace, delete, up/down/left/right, or a hex hid usage
- `button <name>` a hardware button: home, lock/power/sleep, wake, volume-up, volume-down, mute, siri
- `info` udid + screen size

## how to work with it

1. `phone shot /tmp/phone.png`, then open the png with the Read tool to see the screen.
2. pick the spot in that image and `tap` or `swipe` it. `shot` prints the real size as `w` and `h`. if the image you see is scaled down, scale your coords up to that size first.
3. take a new shot after every action that changes the screen. don't act on an old one.

to scroll a list down, swipe from low to high on the screen: `swipe 600 2000 600 800`. to type, tap the text field first so the keyboard is up, then `text`, then `key return` if it needs submitting.

every call opens a new connection. for a long run of inputs there's `phone serve`, which reads one command per line on stdin and keeps the connection open. see `control/README.md`.

## what it can't do

- input fails while the phone is on a call or already mirroring/recording the screen. screenshots still work then.
- it can't enter the passcode or get past the lock screen. ask the user to unlock the phone.
- `text` is us-layout ascii only. no emoji, no ime.
- over wifi it doesn't check that it's really the user's phone. use usb on networks you don't trust.
- it needs developer mode on and the developer disk image mounted (open the phone in xcode once), and a pairing from `scripts/setup.sh` for wifi.
