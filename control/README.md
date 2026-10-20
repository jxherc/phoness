# phone — drive the phone from the mac

a mac command-line tool that controls the iphone over usb, straight from this machine.
no on-device app, no vpn, no iPhone Control. it uses coredevice, the same remote-control
path xcode's device hub uses, so it works even while the phone is on its lock screen.

made for testing phone apps: screenshot the screen, tap, swipe, type, press hardware buttons.

```
cargo build --release          # in this folder
target/release/phone info      # udid + screen size
target/release/phone shot s.png
target/release/phone tap 300 900
```

more than one device plugged in? `UDID=<udid> target/release/phone ...`. with none set it
takes the first device usbmuxd lists, which may be an ipad.

## commands

coords are screen **pixels** by default, matched to the last screenshot. add `n` (tapn,
swipen) for raw 0-65535 hid coordinates.

- `shot [path]` screenshot to png (default `screen.png`), prints its pixel size
- `tap x y` / `tapn x y`
- `swipe x1 y1 x2 y2` / `swipen ...` (a real drag, ~0.6s, so it scrolls instead of flicking)
- `text "hello world"` type on the keyboard (us layout, ascii)
- `key <name|0xNN>` one key: return, esc, tab, space, backspace, delete, up/down/left/right, or a hex hid usage
- `button <name>` a hardware button: home, lock/power/sleep, wake, volume-up, volume-down, mute, siri
- `info` udid + screen size

## serve mode (for an agent / scripts)

`phone serve` reads one command per line on stdin and writes one json line per command on
stdout. the screen-sharing gate that input needs is opened once and held, so taps after the
first have no setup cost.

```
mkfifo /tmp/p.in
target/release/phone serve < /tmp/p.in &
exec 3>/tmp/p.in
echo 'shot /tmp/s.png' >&3
echo 'tap 300 900' >&3
echo 'text hello' >&3
echo 'quit' >&3
```

## how it works

over usbmuxd it opens a coredevice tunnel to the phone, then rsd (the service list) inside it.

- screenshots use `com.apple.coredevice.screencaptureservice`. no gate, works during anything.
- taps/keys/buttons go through coredevice hid (`hid.universalhidservice` for touch,
  `hid.indigo` for keyboard and buttons). the device drops synthetic hid events unless a
  displayservice screen-sharing stream is live, so the tool starts one on the first input and
  keeps it open. the video it sends back is discarded; only the stream's existence matters.

## limits

- input needs the screen-sharing gate, and ios refuses that while the phone is **on a call**
  or already mirroring/recording. screenshots still work then.
- it drives the **lock screen** (wake, swipe, tap, buttons) but can't enter or get past the
  passcode. that's the secure enclave, not something software gets around.
- needs the developer disk image mounted (open the phone in xcode once). developer mode on.
- `text` is us-layout ascii. no ime, no emoji.
