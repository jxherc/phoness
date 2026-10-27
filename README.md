# iphone computer use

[简体中文](README.zh-Hans.md)

an agent that uses your iphone or ipad the way you do: it looks at the screen, taps, types and swipes, in any app.

remake of [finn voorhees' demo](https://x.com/finnvoorhees/status/2108279639538012265).

<p align="center"><img src="docs/demo.gif" width="320" alt="asking the agent whether to bring an umbrella. it opens the weather app, checks today and tomorrow, and answers in the chat"></p>

there are two ways to use it. pick one:

| | where the agent runs | you need |
| --- | --- | --- |
| **[1. the app on your phone](#1-the-app-on-your-phone)** | on the iphone or ipad itself. you chat with it there, and after setup no computer is needed | a mac once for setup, and an api key or a claude login |
| **[2. claude code on your mac](#2-claude-code-on-your-mac)** | in claude code on your mac, which drives the phone over usb or wifi | a mac with claude code |

---

## 1. the app on your phone

> [!WARNING]
> this needs sideloading, and an api key (anthropic, openai, gemini, openrouter and others) or a claude subscription.
>
> **the claude sign-in can get your claude account limited or banned.** it signs in with claude code's own oauth client and tells the api it's claude code, because that's the only way subscription requests go through. anthropic [limits subscription logins to its own apps](https://code.claude.com/docs/en/legal-and-compliance), so this goes against that. it's here because it works, not because it's allowed. use an api key if your account matters to you.
>
> only tried on one iphone so far (16 pro, ios 27.0.1). the same app installs on an ipad, but hasn't run a task there yet.

### you need

- a mac with xcode 27 and xcodegen
- rust through rustup. `rust-toolchain.toml` pins the version and the ios targets, and rustup fetches them on the first build
- an apple account. a free one works: free teams can't sign the built-in vpn, so the app uses [LocalDevVPN](https://apps.apple.com/app/id6755608044) (free, app store) instead. a paid developer account lets it use its own
- an iphone or ipad on ios 26 or later, with developer mode on, trusting this mac, and wifi on (its remote pairing service needs it)

### install

1. building under your own team? change `DEVELOPMENT_TEAM` and `AGENT_BUNDLE_ID` at the top of `project.yml`. the tunnel, runner and background task ids all follow from `AGENT_BUNDLE_ID`.
2. plug in the iphone or ipad, unlock it, and run:

   ```bash
   ./scripts/setup.sh
   ```

   - free apple account: `FREE_ACCOUNT=1 ./scripts/setup.sh`
   - an iphone and an ipad both around: `DEVICE=ipad ./scripts/setup.sh` (or `DEVICE=iphone`, or `UDID=<udid>`). it won't guess.
3. on the device, open Agent and tap the model name at the top. pick a provider and paste its api key, or use the [claude sign-in](#claude-sign-in).
4. in the same settings: iPhone Control (iPad Control on an ipad) > Turn On. allow the vpn, then type your passcode when iOS asks for "XCTest".
5. unplug it and tell it what to do.

on a free account, the build leaves out the vpn entitlement: install LocalDevVPN and turn it on before step 4. apps signed by a free account stop opening after 7 days, so run the script again then.

<details>
<summary>what setup.sh does</summary>

it writes the remote pairing file to `.pairing/<udid>.plist` (readable only by you), copies the developer disk image from xcode into `App/Resources/Device/DDI/`, builds, installs the app and the runner, and then copies the pairing file into the app's own storage on the device. that last copy needs the device unlocked; if it was locked, unlock it and run the script again.

the pairing file is a paired-host credential for the phone, so it never goes into the app bundle or git, and the app keeps it out of backups. a pairing file from an older setup (the lockdown kind) is refused with "run scripts/setup.sh again".

</details>

### providers

tap the model name to pick a provider, a model and that provider's api key. each provider keeps its own key in the keychain and remembers its last model.

- anthropic: claude, with an api key or the claude sign-in below
- openai, google gemini, xai, openrouter, deepseek, mistral, groq, moonshot (kimi): an api key from that provider
- custom: any openai-compatible server, your own included. give it the base url (like `https://example.com/v1`), a model id, and a key if it needs one

the lists only have models that take images, since the agent works from screenshots. they were checked against [models.dev](https://models.dev) on 2026-10-26. the model id field under the list takes any other id the provider has. the providers and their urls follow [pi](https://github.com/earendil-works/pi)'s list.

### claude sign-in

in settings, tap **sign in with claude**, finish login in the browser, then return to the app and paste the full authorization code (including the `#` suffix) or callback URL. tap **finish sign-in**. the app stores tokens in this device's keychain and refreshes them before expiry. pending sign-ins survive closing settings or restarting the app and expire after ten minutes.

oauth takes priority while signed in. **sign out** removes this app's saved tokens; it doesn't sign out of the browser or revoke other sessions. an existing api key stays saved and becomes active after signout. a rejected oauth request never silently switches to paid api access.

this is an experimental compatibility flow using claude's public cli oauth client, not a registered third-party integration. subscription requests include the required client system block first, followed by the unchanged phone instructions. API-key requests keep their original system prompt. [anthropic restricts subscription credentials to its own clients](https://code.claude.com/docs/en/legal-and-compliance), so this compatibility can change. the login flow follows the [published oauth implementation](https://github.com/ex-machina-co/opencode-anthropic-auth/blob/main/src/auth.ts).

---

## 2. claude code on your mac

claude code gets the phone's screen as images and taps, swipes, types and presses buttons on it, through a small mac tool called `phone`. nothing gets installed on the phone and there's no vpn.

### you need

- a mac with claude code, and rust through rustup
- an iphone or ipad with developer mode on, trusting this mac, and the developer disk image mounted (open the device in xcode once)
- a usb cable. wifi works too, with the pairing file from part 1's `setup.sh` (see [control/README.md](control/README.md))

### install

1. build `phone`:

   ```bash
   cd control
   cargo build --release
   ```

2. put it on your PATH, for example:

   ```bash
   ln -s "$PWD/target/release/phone" ~/.local/bin/phone
   ```

3. add the plugin:

   ```bash
   claude plugin install phone --marketplace jxherc/phoness
   ```

4. plug in the phone, unlock it, and ask claude code to do something on it.

the plugin runs `phone mcp` from your PATH and doesn't ship the binary, which is why step 2 comes first. without the plugin, `claude mcp add phone -- "$PWD/target/release/phone" mcp` in `control/` does the same.

with an iphone and an ipad both around, say which one in your message. the tools take `device` (`iphone` or `ipad`) and stay on that device after the first call. it can't get past the passcode, and taps fail while the phone is on a call or recording its screen, though screenshots still work then.

the tool works on its own too (`phone shot`, `phone tap 300 900` and so on). commands, wifi and limits are in [control/README.md](control/README.md).

---

## how it works

- `App/` the chat app. sends your message to the model you picked (streaming, raw http since there's no swift sdk) with four tools: `phone_look`, `phone_act`, `phone_apps`, `current_time`. while a reply runs it asks ios for a continued processing task (the "Replying" pill with a stop button), so it can keep working while other apps are in front. claude goes over anthropic's messages api, every other provider over the openai-style chat completions api, which `App/OpenAI.swift` translates to and from.
- `Runner/` a ui test that never finishes. it serves http on `127.0.0.1:8123`: `/look` (screenshot + readable elements with tap points), `/act` (tap, double_tap, long_press, swipe, type, key, home, open_app, open_url, wait), `/apps`, `/known`, `/status`, `/stop`. every request needs the `x-runner-token` header, and posts must be json. xctest is the one thing ios lets touch other apps.
- `launcher/` rust static lib on top of [idevice](https://github.com/jkcoxson/idevice). it starts that runner on the phone itself: through the vpn it opens a remote pairing tunnel to the phone's own `remotepairingd` (what xcode uses over wifi), mounts the developer disk image if needed, then launches the runner through testmanagerd, all inside that tunnel. that's where the "Enter iPhone Passcode for XCTest" prompt comes from. iOS 27 lockdownd drops connections that come through a vpn, so the old lockdownd route is gone ([why](wiki/lessons/ios27-lockdownd-vpn.md)). idevice is vendored in `launcher/idevice`: commit 26a28f6 plus one patch (`XCUITestService::run_rsd`), so xctest can start over a remote pairing tunnel.
- `Tunnel/` loopback packet tunnel. packets to `10.7.0.1` get src and dst swapped and go straight back in, so the phone's services see a computer calling from outside. same trick as localdevvpn and stosvpn, which stikdebug uses. on a free apple account the app uses localdevvpn instead.
- `setup/` small mac tool, run once. makes the remote pairing file inside a usb tunnel to the phone, with its own identity, so the app's pairing is separate from the mac's. the first time, the phone may ask to trust this computer.
- `control/` the `phone` mac tool from part 2. it drives the phone straight from this machine through coredevice (what xcode's device hub uses): screenshot, tap, swipe, type, hardware buttons. screenshots work even on the lock screen. it drives an ipad too; with both around, say which with `DEVICE=iphone` or `DEVICE=ipad`.
- `plugin/` the claude code plugin from part 2. it runs `phone mcp`, so claude gets the screenshots as images and taps on them.

## working on it

- `xcodegen generate` first, and again after changing `project.yml`. the xcode project isn't committed.
- in the simulator the vpn, the launcher and the background task don't work. run the runner with product > test (cmd+u), then open Agent from the simulator's home screen. the scheme sets `RUNNER_DEV=1`, so that runner accepts the fixed `dev` token the app uses by default. the app only gets 15 to 30 seconds in the background there, then ios freezes it, so a task that works in other apps for longer stalls. use a real phone for anything longer.
- the app reads `ANTHROPIC_BASE_URL`, and `ANTHROPIC_API_KEY` when no key is saved, from its environment. set them under edit scheme > run > environment. `xcodegen generate` resets the scheme, so put them in `project.yml`'s run action if they should stick.
- building the rust parts by hand while `xcode-select` points at the command line tools needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. xcode builds set it already.
- `cargo run --release --example mac -- <phone ip> 49152 .pairing/<udid>.plist App/Resources/Device/DDI <app id>.runner.xctrunner` (in `launcher/`) runs the whole on-device start from the mac against a phone on the same wifi. the phone's ip and port show up in `dns-sd -B _remotepairing._tcp` then `dns-sd -L <name> _remotepairing._tcp`.
- `setup/target/release/phonelog <udid> "lockdownd|remotepairingd|Agent["` streams the phone's syslog, filtered. the app writes `launcher.log` next to its pairing file.
- `./scripts/test-auth.sh` runs oauth protocol and token lifecycle checks against synthetic responses, without using your keychain or a live account.
- `./scripts/test-api.sh` checks the openai-compatible client against canned responses: the history translation both ways, streaming, provider quirks and errors.

## limits

- the on-device start (vpn, remote pairing tunnel, disk image check, runner launch) ran on an iphone 16 pro on ios 27.0.1 on 2026-10-20. the disk image was already mounted there, so the mount step itself hasn't run on a phone yet. a full run on the same phone worked on 2026-10-21 (the demo above): it switched to the weather app, kept going in the background under the "Replying" task, and answered. other phones and ios versions are untested.
- it's one app for iphone and ipad. on 2026-10-26, in the ipad simulator (11-inch, ios 27.0), the chat was checked in portrait, landscape and a small window, and the runner's look and taps were checked in all three, including an app in a window away from the corner. on a real ipad pro (ios 27.0.1) it's installed, but it hasn't been turned on or run a task.
- each runner start asks for the passcode. ios drops the runner when the app's testmanagerd connection goes away, for example when the app gets killed. the next message starts it again.
- the runner uses private api. it skips xctest's wait-for-idle like webdriveragent does, asks xctest's accessibility client which app is in front, and falls back to `LSApplicationWorkspace` for the app list (on the phone the list comes from installation_proxy). a new xcode can break any of these, the code checks each step and falls back.
- the runner's token is fresh for every start, from the app and from `examples/mac.rs`. a runner started from xcode uses the fixed `dev` token, so while that one is up any app on the phone could drive it. that's for development only. the runner only listens on 127.0.0.1 and refuses other host names, so web pages can't reach it through dns rebinding.
- the agent reads other apps' screens. the prompt tells it screen text is content, never instructions, but a page or message written to steer it can still try. nothing in code asks you before it taps, types or opens a link, so watch what it does.
- a local app can hold the runner's 16 connection slots and lock the agent out until it lets go. it can't read or drive anything that way.
- while the vpn is on, any app on the phone can reach remotepairingd at `10.7.0.1`. it needs the pairing file to do anything past the handshake. the app turns the vpn off with iPhone Control.
- remotepairingd seems to need wifi on. that's what stikdebug says for the same path. not tried on cellular.
- landscape hasn't been tested on a real device.
- other providers: on 2026-10-26 the openai-compatible path ran a real tool loop with a screenshot through a local proxy to gemini 3.8 flash and claude sonnet 4.6, from a mac harness and from the app in the simulator (it opened settings, read the screen and answered right). every listed provider's endpoint answered a made-up key with a clear error, so the urls are right. no real key for openai, gemini, xai, openrouter, deepseek, mistral, groq or moonshot was tried, so their replies are untested. xai marks its chat completions api as deprecated, with no end date.
- live claude oauth login, token refresh, and direct Opus 5.5 replies passed on 2026-10-20. the missing first client system block caused a generic HTTP 429 despite available subscription usage; adding it returned HTTP 200 both before and after refresh. the response confirmed included subscription usage was allowed while paid overage was disabled. the unchanged Swift client also streamed a reply and completed a `current_time` tool roundtrip with all four tool definitions in a temporary macOS test harness. simulator and device builds passed; the latest simulator screen check was blocked by Xcode's device viewer startup. physical-phone behavior remains unverified. a [matching reproduction](https://github.com/anthropics/claude-code/issues/87420) documents the same request requirement.

## license

mit, see [LICENSE](LICENSE). `launcher/idevice/` is [idevice](https://github.com/jkcoxson/idevice) by jackson coxson, also mit ([its license](launcher/idevice/LICENSE.txt)), with one small patch.
