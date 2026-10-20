# architecture

```
you type -> App (Agent.swift) -> claude api (Claude.swift, sse)
                 |  tool_use phone_act / phone_look
                 v
           Tools.swift -> http 127.0.0.1:8123 + x-runner-token (json only)
                 v
           Runner (RunnerTests.testServe, never returns)
                 v
           XCUIApplication / XCUIScreen -> any app on screen
```

starting the runner on the phone (Control.swift -> launcher):

```
Tunnel on (10.7.0.0 <-> 10.7.0.1 swap), or LocalDevVPN on a free team
remotepairingd port: 49152, else bonjour _remotepairing._tcp (Control.remotePairingPort)
launcher_start -> remotepairingd at 10.7.0.1: pair-verify with the remote pairing file
               -> createListener + tls-psk tunnel (cdtunnel), userspace tcp (jktcp) inside it
               -> rsd handshake: lists the services reachable in the tunnel
               -> heartbeat over rsd (keepalive, best effort)
               -> lockdown.remote.trusted: ios version + chip id, no session needed
               -> mount personalized ddi if nothing's mounted
               -> installation_proxy: app list (cached for launcher_apps), find <app id>.runner.xctrunner
               -> testmanagerd + dtservicehub over rsd (XCUITestService::run_rsd): launch runner with RUNNER_PORT, RUNNER_TOKEN
```

lockdownd at 10.7.0.1 is a dead end on iOS 27: it accepts the tcp connection, then resets it
before reading anything when it came in on a vpn (utun) interface. see wiki/lessons/ios27-lockdownd-vpn.md.

files
- App/Agent.swift: chat state, the tool loop, history repair, batched screenshot trimming, background task, saving to Application Support/chat.json
- App/Claude.swift: messages api request + stream parsing, retries, fallbacks
- App/ClaudeAuth.swift, App/Keychain.swift: credentials (api key, sign-in)
- App/Tools.swift: tool schemas and what each one calls
- App/Control.swift: runner client, start/stop, vpn manager, pairing file
- App/ChatView.swift, App/SettingsView.swift, App/AgentApp.swift: the ui
- Runner/RunnerTests.swift: the endpoints, element list, front app detection
- Runner/Server.swift: the tiny http server (token, size caps, read deadline)
- launcher/src/lib.rs: c api over idevice. launcher/examples/mac.rs runs the same start from a mac against a phone on wifi
- launcher/idevice/: vendored idevice 26a28f6 plus the run_rsd patch in services/dvt/xctest/mod.rs
- Tunnel/PacketTunnelProvider.swift: the swap
- setup/src/main.rs: remote pairing file maker (pairs inside a usb coredevice tunnel). setup/src/bin/phonelog.rs: filtered phone syslog
- scripts/setup.sh: one-time phone setup. scripts/build-launcher.sh: called by xcode. scripts/test-auth.sh: auth checks
