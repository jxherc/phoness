# iphone computer use

> [!WARNING]
> this will need sideloading on iphone and a claude subscription (for now)

an agent that runs on the iphone and drives any app on it. it looks at the screen, taps, types and swipes. after a one-time setup it's meant to need no computer at all, though the on-device start hasn't run on a real phone yet (see limits).

remake of [finn voorhees' demo](https://x.com/finnvoorhees/status/2108279639538012265).

## how it works

- `App/` the chat app. sends your message to claude over the messages api (streaming, raw http since there's no swift sdk) with four tools: `phone_look`, `phone_act`, `phone_apps`, `current_time`. while a reply runs it asks ios for a continued processing task (the "Replying" pill with a stop button), so it can keep working while other apps are in front.
- `Runner/` a ui test that never finishes. it serves http on `127.0.0.1:8123`: `/look` (screenshot + readable elements with tap points), `/act` (tap, double_tap, long_press, swipe, type, key, home, open_app, open_url, wait), `/apps`, `/known`, `/status`, `/stop`. every request needs the `x-runner-token` header, and posts must be json. xctest is the one thing ios lets touch other apps.
- `launcher/` rust static lib on top of [idevice](https://github.com/jkcoxson/idevice). it starts that runner on the phone itself: connects to the phone's own lockdownd through the vpn, mounts the developer disk image if needed, then launches the runner through testmanagerd. that's where the "Enter iPhone Passcode for XCTest" prompt comes from.
- `Tunnel/` loopback packet tunnel. packets to `10.7.0.1` get src and dst swapped and go straight back in, so lockdownd thinks a paired computer is calling over wifi. same trick as localdevvpn and stosvpn, which stikdebug uses. on a free apple account the app uses localdevvpn instead (see setup).
- `setup/` small mac tool, run once. makes the pairing file and turns on network connections for lockdownd. over a cable it pairs with its own host id, so the app's pairing is separate from the mac's.

## setup

you need:

- xcode 27 and xcodegen
- rust through rustup. `rust-toolchain.toml` pins the version and the ios targets, rustup fetches them on the first build
- an apple account. a free one works: free teams can't sign the built-in vpn, so the app uses [LocalDevVPN](https://apps.apple.com/app/id6755608044) (free, app store) instead. a paid developer account lets it use its own
- an iphone on ios 26 or later, with developer mode on, that trusts this mac

the first build also downloads [idevice](https://github.com/jkcoxson/idevice) from github, pinned to one commit.

building under your own team: change `DEVELOPMENT_TEAM` and `AGENT_BUNDLE_ID` at the top of `project.yml`. the tunnel, runner and background task ids all follow from `AGENT_BUNDLE_ID`.

then with the phone plugged in and unlocked:

```bash
./scripts/setup.sh
```

on a free account:

```bash
FREE_ACCOUNT=1 ./scripts/setup.sh
```

that build leaves out the vpn entitlement. install LocalDevVPN and turn it on before iPhone Control > Turn On. apps signed by a free account stop opening after 7 days, so run the script again then.

it writes the pairing file to `.pairing/<udid>.plist` (readable only by you), copies the developer disk image from xcode into `App/Resources/Device/DDI/`, builds, installs the app and the runner, and then copies the pairing file into the app's own storage on the phone. the pairing file is a full paired-host credential for the phone, so it never goes into the app bundle or git, and the app keeps it out of backups. with more than one phone: `UDID=<udid> ./scripts/setup.sh`.

on the phone: open Agent, tap the model name, add an anthropic api key or use the experimental claude sign-in below, then iPhone Control > Turn On. allow the vpn and type your passcode when iOS asks for "XCTest".

## claude sign-in

in settings, tap **sign in with claude**, finish login in the browser, then return to the app and paste the full authorization code (including the `#` suffix) or callback URL. tap **finish sign-in**. the app stores tokens in this iphone's keychain and refreshes them before expiry. pending sign-ins survive closing settings or restarting the app and expire after ten minutes.

oauth takes priority while signed in. **sign out** removes this app's saved tokens; it doesn't sign out of the browser or revoke other sessions. an existing api key stays saved and becomes active after signout. a rejected oauth request never silently switches to paid api access.

this is an experimental compatibility flow using claude's public cli oauth client, not a registered third-party integration. subscription requests include the required client system block first, followed by the unchanged phone instructions. API-key requests keep their original system prompt. [anthropic restricts subscription credentials to its own clients](https://code.claude.com/docs/en/legal-and-compliance), so this compatibility can change. the login flow follows the [published oauth implementation](https://github.com/ex-machina-co/opencode-anthropic-auth/blob/main/src/auth.ts).

## working on it

- `xcodegen generate` first, and again after changing `project.yml`. the xcode project isn't committed.
- in the simulator the vpn, the launcher and the background task don't work. run the runner with product > test (cmd+u), then open Agent from the simulator's home screen. the scheme sets `RUNNER_DEV=1`, so that runner accepts the fixed `dev` token the app uses by default. the app only gets about 30 seconds in the background there.
- the app reads `ANTHROPIC_BASE_URL`, and `ANTHROPIC_API_KEY` when no key is saved, from its environment. set them under edit scheme > run > environment. `xcodegen generate` resets the scheme, so put them in `project.yml`'s run action if they should stick.
- building the rust parts by hand while `xcode-select` points at the command line tools needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. xcode builds set it already.
- `./scripts/test-auth.sh` runs oauth protocol and token lifecycle checks against synthetic responses, without using your keychain or a live account.

## limits

- the on-device start (vpn, lockdownd, disk image mount, runner launch) builds and signs, but hasn't run on a real phone yet. everything after the runner is up was tested in the simulator.
- each runner start asks for the passcode. ios drops the runner when the app's testmanagerd connection goes away, for example when the app gets killed. the next message starts it again.
- the runner uses private api. it skips xctest's wait-for-idle like webdriveragent does, asks xctest's accessibility client which app is in front, and falls back to `LSApplicationWorkspace` for the app list (on the phone the list comes from installation_proxy). a new xcode can break any of these, the code checks each step and falls back.
- the runner's token is fresh for every start from the app. a runner started from xcode uses the fixed `dev` token, so while that one is up any app on the phone could drive it. that's for development only.
- while the vpn is on, any app on the phone can reach lockdownd at `10.7.0.1` for the queries that need no pairing (device name, model). the app turns the vpn off with iPhone Control.
- landscape hasn't been tested.
- live claude oauth login, token refresh, and direct Opus 5.5 replies passed on 2026-10-20. the missing first client system block caused a generic HTTP 429 despite available subscription usage; adding it returned HTTP 200 both before and after refresh. the response confirmed included subscription usage was allowed while paid overage was disabled. the unchanged Swift client also streamed a reply and completed a `current_time` tool roundtrip with all four tool definitions in a temporary macOS test harness. simulator and device builds passed; the latest simulator screen check was blocked by Xcode's device viewer startup. physical-phone behavior remains unverified. a [matching reproduction](https://github.com/anthropics/claude-code/issues/87420) documents the same request requirement.
