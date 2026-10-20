import BackgroundTasks
import Foundation
import Observation
import UIKit

// one chat. keeps the api history and the stuff the ui shows side by side.
@Observable @MainActor
final class Agent {
    struct Item: Identifiable, Codable, Equatable {
        enum Kind: String, Codable { case user, assistant, tool, error }
        var id = UUID()
        var kind: Kind
        var text: String
        var detail = ""
        var date = Date()
    }

    var items: [Item] = []
    var running = false
    var status = ""

    private var messages: [[String: Any]] = []
    private var job: Task<Void, Never>?
    private var bg: BGContinuedProcessingTask?
    private var bgShort: UIBackgroundTaskIdentifier = .invalid
    private var steps = 0

    static let shared = Agent()

    init() { load() }

    var model: String { UserDefaults.standard.string(forKey: "model") ?? Models.all[0].id }

    // MARK: run

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        items.append(Item(kind: .user, text: text))
        messages.append(["role": "user", "content": text])
        running = true
        status = "Thinking"
        steps = 0
        startBackground()
        job = Task {
            await loop()
            running = false
            status = ""
            endBackground()
            save()
        }
    }

    func stop() {
        job?.cancel()
    }

    func reset() {
        stop()
        items = []
        messages = []
        save()
    }

    private func loop() async {
        // env var is for running from xcode without typing the key in
        guard let key = Keychain.get("anthropic") ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
            items.append(Item(kind: .error, text: "Add your Anthropic API key in Settings."))
            return
        }
        let claude = Claude(key: key, model: model)

        // hard cap so a confused run can't go forever
        for _ in 0..<150 {
            if Task.isCancelled { return stopped() }
            setStatus("Thinking")

            var live: Int?
            let res: (content: [[String: Any]], stop: String)
            do {
                res = try await claude.send(system: Self.system, tools: Tools.defs, messages: trimmed()) { ev in
                    switch ev {
                    case .text(let t):
                        if live == nil {
                            self.items.append(Item(kind: .assistant, text: ""))
                            live = self.items.count - 1
                        }
                        self.items[live!].text += t
                        self.setStatus("Writing")
                    case .thinking:
                        self.setStatus("Thinking")
                    case .tool(let name):
                        live = nil
                        self.setStatus("Running \(name)")
                    }
                }
            } catch is CancellationError {
                return stopped()
            } catch let e as URLError where e.code == .cancelled {
                return stopped()
            } catch {
                items.append(Item(kind: .error, text: error.localizedDescription))
                return
            }

            if let live, items[live].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                items.remove(at: live)
            }
            messages.append(["role": "assistant", "content": res.content])

            if res.stop == "refusal" {
                items.append(Item(kind: .error, text: "Claude declined this request."))
                return
            }
            let calls = res.content.filter { $0["type"] as? String == "tool_use" }
            if calls.isEmpty || res.stop != "tool_use" {
                if res.stop == "max_tokens" { items.append(Item(kind: .error, text: "The reply hit the length limit.")) }
                return
            }

            // one at a time, they all touch the same screen
            var results: [[String: Any]] = []
            for call in calls {
                let name = call["name"] as? String ?? ""
                let input = call["input"] as? [String: Any] ?? [:]
                var r: [String: Any] = ["type": "tool_result", "tool_use_id": call["id"] as? String ?? ""]
                // every tool_use needs a result, even the ones we skip
                if Task.isCancelled {
                    r["content"] = "Stopped by the user."
                    r["is_error"] = true
                    results.append(r)
                    continue
                }
                setStatus("Running \(name)")
                let out = await Tools.run(name, input)
                items.append(Item(kind: .tool, text: Tools.title(name), detail: Tools.summary(name, input, out)))
                r["content"] = out.content
                if out.error { r["is_error"] = true }
                results.append(r)
                steps += 1
                tick()
            }
            messages.append(["role": "user", "content": results])
            save()
        }
    }

    private func stopped() {
        // if the last assistant turn asked for tools, the api wants results for them next time
        if let last = messages.last, last["role"] as? String == "assistant",
           let content = last["content"] as? [[String: Any]] {
            let ids = content.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
            if !ids.isEmpty {
                messages.append(["role": "user", "content": ids.map {
                    ["type": "tool_result", "tool_use_id": $0, "content": "Stopped by the user.", "is_error": true]
                }])
            }
        }
        items.append(Item(kind: .error, text: "Stopped."))
    }

    // keep the last few screenshots, older ones just eat context
    private func trimmed(keep: Int = 3) -> [[String: Any]] {
        var seen = 0
        var out = messages
        for m in out.indices.reversed() {
            guard var content = out[m]["content"] as? [[String: Any]] else { continue }
            for b in content.indices.reversed() {
                guard var inner = content[b]["content"] as? [[String: Any]] else { continue }
                for k in inner.indices.reversed() where inner[k]["type"] as? String == "image" {
                    seen += 1
                    if seen > keep { inner[k] = ["type": "text", "text": "(old screenshot removed)"] }
                }
                content[b]["content"] = inner
            }
            out[m]["content"] = content
        }
        return out
    }

    // MARK: background

    // a continued processing task keeps us alive while other apps are in front.
    // the system shows it as "Replying" with a stop button.
    private func startBackground() {
        // plain ~30s of background time as a backup, in case the continued task is refused
        // (it always is in the simulator)
        bgShort = UIApplication.shared.beginBackgroundTask(withName: "agent run") {
            MainActor.assumeIsolated { Agent.shared.endShort() }
        }

        let id = "com.jxherc.agent.run.\(UUID().uuidString.prefix(8))"
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated {
                self.bg = task
                task.progress.totalUnitCount = 100
                task.updateTitle("Replying", subtitle: self.status)
                // system wants the time back, so stop the run
                task.expirationHandler = {
                    Task { @MainActor in Agent.shared.stop() }
                }
            }
        }
        let req = BGContinuedProcessingTaskRequest(identifier: id, title: "Replying", subtitle: "Thinking")
        req.strategy = .fail
        // fails in the simulator, that's fine
        do { try BGTaskScheduler.shared.submit(req) } catch { NSLog("bg task: %@", "\(error)") }
    }

    private func setStatus(_ s: String) {
        guard s != status else { return }
        status = s
        bg?.updateTitle("Replying", subtitle: s)
    }

    private func tick() {
        // no real total, so creep toward 95%
        guard let p = bg?.progress else { return }
        p.completedUnitCount = min(95, p.completedUnitCount + max(1, (95 - p.completedUnitCount) / 8))
    }

    private func endShort() {
        guard bgShort != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgShort)
        bgShort = .invalid
    }

    private func endBackground() {
        endShort()
        guard let bg else { return }
        bg.progress.completedUnitCount = 100
        bg.setTaskCompleted(success: true)
        self.bg = nil
    }

    // MARK: storage

    private static var file: URL { URL.documentsDirectory.appending(path: "chat.json") }

    private func save() {
        // screenshots are huge, the saved chat doesn't need them
        let slim = trimmed(keep: 0)
        let obj: [String: Any] = [
            "items": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(items))) ?? [],
            "messages": slim,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: Self.file) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        messages = obj["messages"] as? [[String: Any]] ?? []
        if let raw = obj["items"], let d = try? JSONSerialization.data(withJSONObject: raw) {
            items = (try? JSONDecoder().decode([Item].self, from: d)) ?? []
        }
        // a run that died mid tool call leaves a dangling tool_use, drop it
        if let last = messages.last, last["role"] as? String == "assistant",
           (last["content"] as? [[String: Any]])?.contains(where: { $0["type"] as? String == "tool_use" }) == true {
            messages.removeLast()
        }
    }

    static let system = """
    You run on the user's iPhone and can operate it: see the screen, tap, type, swipe and open apps, using the phone tools.

    How the phone tools work:
    - Coordinates are screen points. They match the screenshot pixels exactly, with 0,0 at the top left.
    - The element list next to each screenshot gives tap points (@ x,y). Prefer those over guessing from the image.
    - Open an app with phone_act open_app and its bundle id. Call phone_apps if you don't know the id.
    - To type, tap the field first, then use type. Use key return to submit.
    - To scroll down, swipe upward, for example from 200,650 to 200,250.
    - Go back with the app's back button, or swipe from the left edge (x 2) to the right.
    - Every phone_act returns a fresh screenshot. Check it before the next step instead of assuming the action worked.
    - Pop-ups and permission prompts happen. Deal with them like a person would.

    Ask the user first before anything that spends money, sends a message or email, posts publicly, deletes things, or changes account or security settings. Get to that screen, stop, and ask.
    If you hit a login, captcha or passcode, stop and say what you need.

    When you're done, answer in a few short sentences of plain text: what you found or did, and what's left on screen. It shows in a chat bubble, so no headers, tables or markdown.
    """
}

enum Models {
    static let all: [(id: String, name: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5"),
        ("claude-fable-5-1", "Claude Fable 5.1"),
    ]

    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}
