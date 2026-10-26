# phone — drive the phone from the mac

a mac command-line tool that controls the iphone from this machine, over usb or wifi.
no on-device app, no vpn, no iPhone Control. it uses coredevice, the same remote-control
path xcode's device hub uses.

made for testing phone apps: screenshot the screen, tap, swipe, type, press hardware buttons.

```
cargo build --release          # in this folder
target/release/phone info      # udid + screen size
target/release/phone shot s.png
target/release/phone tap 300 900
```

it uses usb when usbmuxd sees the phone. otherwise it goes over wifi, straight to the
phone's remotepairingd with the pairing file `scripts/setup.sh` made:

```
PHONE_IP=192.168.2.103 target/release/phone info
```

`PHONE_IP` can also be a `.local` name. `PHONE_PORT` (default 49152) and `PHONE_PAIRING`
(default `.pairing/<udid>.plist`) override the rest. with no `UDID` set it uses the one phone
in `.pairing/`. with more than one, pass `UDID=<udid>`.

## commands

coords are screen **pixels** by default, matched to the last screenshot. add `n` (tapn,
swipen) for raw 0-65535 hid coordinates.

- `shot [path]` screenshot to png (default `screen.png`, the path must end in `.png`), prints its pixel size
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

## mcp mode (for claude code)

`phone mcp` is the same set of commands as an mcp server on stdin/stdout: `screenshot`, `tap`,
`swipe`, `text`, `key`, `button`, `info`. screenshots come back as jpeg images shrunk to claude's
standard image limits (1568 px long edge, 1568 visual tokens), so no model shrinks them again.
that's 721x1568 on a 16 pro. `tap` and `swipe` take coords in that image's pixels, not the screen's.

it connects on the first tool call, and again after a call fails, so it can start with the phone
unplugged. the plugin in `../plugin` runs it from your PATH. without the plugin:

```
claude mcp add phone -- "$PWD/target/release/phone" mcp
claude mcp add phone -e PHONE_IP=192.168.2.103 -- "$PWD/target/release/phone" mcp   # wifi
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
- it can't enter or get past the passcode. that's the secure enclave.
- over wifi it doesn't check the phone's own key (idevice's pair-verify skips that), so another machine on
  the same network could pretend to be your phone and see what you send. it says so when it connects
  over wifi. use usb on networks you don't trust.
- the wifi path uses the same pairing file as the app. if the app's runner is up at the same
  time, the two connections share one identity. not tested together.
- needs the developer disk image mounted (open the phone in xcode once). developer mode on.
- `text` is us-layout ascii. no ime, no emoji.

## tested (2026-10-20, iphone 16 pro, ios 27.0.1)

- `info` and `shot` over usb and over wifi
- tap, text, key, swipe and `button home`, on the unlocked phone in serve mode: opened discord
  from the dock, opened a dm, typed and sent a message, typed `x` and deleted it with
  `key backspace`, scrolled the chat, went back to the home screen
- volume buttons: the phone's input daemon accepted them, nothing on screen confirmed it
- input on the lock screen: not tested
