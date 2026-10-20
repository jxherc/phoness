# architecture

```
you type -> App (Agent.swift) -> claude api (Claude.swift, sse)
                 |  tool_use phone_act / phone_look
                 v
           Tools.swift -> http 127.0.0.1:8123 + x-runner-token
                 v
           Runner (RunnerTests.testServe, never returns)
                 v
           XCUIApplication / XCUIScreen -> any app on screen
```

starting the runner on the phone (Control.swift -> launcher):

```
Tunnel on (10.7.0.0 <-> 10.7.0.1 swap)
launcher_start -> lockdownd at 10.7.0.1 with the pairing file
               -> heartbeat (keeps the "wifi" client alive)
               -> mount personalized ddi if nothing's mounted
               -> installation_proxy: find com.jxherc.agent.runner.xctrunner
               -> testmanagerd (coredevice proxy + rsd): launch runner with RUNNER_PORT, RUNNER_TOKEN
```

files
- App/Agent.swift: chat state, the tool loop, screenshot trimming (keeps last 3), background task, saving to Documents/chat.json
- App/Claude.swift: messages api request + stream parsing, retries, fallbacks
- App/Tools.swift: tool schemas and what each one calls
- App/Control.swift: runner client, start/stop, vpn manager, pairing import
- Runner/RunnerTests.swift: the endpoints, element list, foreground app detection
- Runner/Server.swift: the tiny http server
- launcher/src/lib.rs: c api over idevice
- Tunnel/PacketTunnelProvider.swift: the swap
- setup/src/main.rs: pairing file maker
