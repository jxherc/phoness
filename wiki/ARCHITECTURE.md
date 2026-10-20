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
launcher_start -> lockdownd at 10.7.0.1 with the pairing file
               -> heartbeat (keeps the "wifi" client alive)
               -> mount personalized ddi if nothing's mounted
               -> installation_proxy: find com.jxherc.agent.runner.xctrunner
               -> testmanagerd (coredevice proxy + rsd): launch runner with RUNNER_PORT, RUNNER_TOKEN
```

files
- App/Agent.swift: chat state, the tool loop, history repair, batched screenshot trimming, background task, saving to Application Support/chat.json
- App/Claude.swift: messages api request + stream parsing, retries, fallbacks
- App/ClaudeAuth.swift, App/Keychain.swift: credentials (api key, sign-in)
- App/Tools.swift: tool schemas and what each one calls
- App/Control.swift: runner client, start/stop, vpn manager, pairing file
- App/ChatView.swift, App/SettingsView.swift, App/AgentApp.swift: the ui
- Runner/RunnerTests.swift: the endpoints, element list, front app detection
- Runner/Server.swift: the tiny http server (token, size caps, read deadline)
- launcher/src/lib.rs: c api over idevice
- Tunnel/PacketTunnelProvider.swift: the swap
- setup/src/main.rs: pairing file maker
- scripts/setup.sh: one-time phone setup. scripts/build-launcher.sh: called by xcode. scripts/test-auth.sh: auth checks
