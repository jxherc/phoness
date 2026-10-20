# iphone computer use

an agent that runs on the iphone and drives any app on it. it looks at the screen, taps, types and swipes. after a one-time setup there's no computer in the loop.

remake of [finn voorhees' demo](https://x.com/finnvoorhees/status/2108279639538012265).

## how it works

- `App/` the chat app. sends your message to claude over the messages api (streaming, raw http since there's no swift sdk) with four tools: `phone_look`, `phone_act`, `phone_apps`, `current_time`. while a reply runs it holds a continued processing task, which is the "Replying" pill with a stop button in the dynamic island, so it keeps working while other apps are in front.
- `Runner/` a ui test that never finishes. it serves http on `127.0.0.1:8123`: `/look` (screenshot + readable elements with tap points), `/act` (tap, double_tap, long_press, swipe, type, key, home, open_app, open_url, wait), `/apps`. xctest is the one thing ios lets touch other apps.
- `launcher/` rust static lib on top of [idevice](https://github.com/jkcoxson/idevice). it starts that runner on the phone itself: connects to the phone's own lockdownd through the vpn, mounts the developer disk image if needed, then launches the runner through testmanagerd. that's where the "Enter iPhone Passcode for XCTest" prompt comes from.
- `Tunnel/` loopback packet tunnel. packets to `10.7.0.1` get src and dst swapped and go straight back in, so lockdownd thinks a paired computer is calling over wifi. same trick as stikdebug and localdevvpn.
- `setup/` small mac tool, run once. writes the pairing file and turns on network connections for lockdownd.

## setup

you need xcode 27, rust, xcodegen, a paid developer account (the vpn needs the network extension entitlement) and developer mode on the phone.

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
```

then with the phone plugged in and unlocked:

```bash
./scripts/setup.sh
```

it makes `App/Resources/Device/pairing.plist`, copies the developer disk image from xcode into `App/Resources/Device/DDI/`, builds, and installs the app and the runner. both files are gitignored.

on the phone: open Agent, tap the model name, paste an anthropic api key, then iPhone Control > Turn On. allow the vpn and type your passcode when iOS asks for "XCTest".

## working on it

- `xcodegen generate` after changing `project.yml`. the xcode project isn't committed.
- in the simulator the vpn, the launcher and the background task don't work. run the runner with product > test (cmd+u) instead, the app finds it on localhost. the app only gets about 30 seconds in the background there.
- `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL` in the scheme's environment skip typing the key, or point at a fake server.

## limits

- the on-device start (vpn, lockdownd, disk image mount, runner launch) builds and signs, but hasn't run on a real phone yet. everything after the runner is up was tested in the simulator.
- each runner start asks for the passcode. ios drops the runner when the app's testmanagerd connection goes away, for example when the app gets killed. the next message starts it again.
- the runner uses private api: `LSApplicationWorkspace` for the app list, and it skips xctest's wait-for-idle like webdriveragent does. a new xcode can break either.
- the runner's http api wants a token that the app makes per start. started from xcode it has none.
- api key only. claude subscription sign-in isn't wired up.
