import Foundation

// tools claude gets. phone_* go to the runner over loopback http.
@MainActor
enum Tools {
    struct Output {
        var content: [[String: Any]]
        var error = false
        var text: String { content.compactMap { $0["text"] as? String }.joined(separator: "\n") }
    }

    static let defs: [[String: Any]] = [
        [
            "name": "phone_look",
            "description": "Screenshot the iPhone and list the readable elements of the app in front, each with a tap point. Coordinates are screen points and match the screenshot pixels.",
            "input_schema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "phone_act",
            "description": """
            Do one thing on the iPhone, then get a fresh screenshot back.
            tap / double_tap / long_press: x, y (long_press takes optional seconds).
            swipe: drag from x, y to to_x, to_y. Swipe upward to scroll down.
            type: types text into the focused field. Tap the field first.
            key: text is return, delete, tab or space. count repeats it.
            home: go to the home screen.
            open_app: bundle_id. open_url: url (web links or app deep links).
            wait: seconds, up to 10, for slow loading.
            """,
            "input_schema": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["tap", "double_tap", "long_press", "swipe", "type", "key", "home", "open_app", "open_url", "wait"],
                    ],
                    "x": ["type": "number"],
                    "y": ["type": "number"],
                    "to_x": ["type": "number"],
                    "to_y": ["type": "number"],
                    "text": ["type": "string"],
                    "count": ["type": "integer"],
                    "bundle_id": ["type": "string"],
                    "url": ["type": "string"],
                    "seconds": ["type": "number"],
                ],
                "required": ["action"],
            ],
        ],
        [
            "name": "phone_apps",
            "description": "List the apps on the iPhone with their bundle ids.",
            "input_schema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "current_time",
            "description": "The current local date, time and time zone.",
            "input_schema": ["type": "object", "properties": [String: Any]()],
        ],
    ]

    static func run(_ name: String, _ input: [String: Any]) async -> Output {
        if Task.isCancelled { return fail("Stopped by the user.") }
        switch name {
        case "current_time":
            let now = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())
            return text("\(now), \(TimeZone.current.identifier)")
        case "phone_apps":
            if let off = await needControl() { return off }
            let c = Control.shared
            if c.apps.isEmpty { await c.loadApps() }
            if c.apps.isEmpty { return fail("Couldn't read the app list.") }
            return text(c.apps.map { "\($0["name"] ?? ""): \($0["id"] ?? "")" }.joined(separator: "\n"))
        case "phone_look":
            if let off = await needControl() { return off }
            return await look()
        case "phone_act":
            if let off = await needControl() { return off }
            do {
                let res = try await Runner.call("/act", body: input)
                if let err = res["error"] as? String { return await failedAct(err) }
                return await look(prefix: "Done.\n\n")
            } catch let e as Runner.Failure where e.status == 400 {
                // bad input from the model, show it the screen and what to fix
                return await failedAct(e.message)
            } catch {
                return fail("The runner didn't answer: \(error.localizedDescription)")
            }
        default:
            return fail("Unknown tool \(name).")
        }
    }

    private static func failedAct(_ err: String) async -> Output {
        var out = await look(prefix: "That didn't work: \(err)\n\n")
        out.error = true
        return out
    }

    private static func needControl() async -> Output? {
        let c = Control.shared
        if await c.ensureOn() { return nil }
        if Task.isCancelled { return fail("Stopped by the user.") }
        let why = c.message.isEmpty ? "" : " (\(c.message))"
        return fail("iPhone Control isn't on\(why). Tell the user to tap the model name at the top of the chat, then iPhone Control, and turn it on.")
    }

    private static func look(prefix: String = "") async -> Output {
        do {
            let r = try await Runner.call("/look")
            let w = (r["width"] as? NSNumber)?.intValue ?? 0
            let h = (r["height"] as? NSNumber)?.intValue ?? 0
            let info = """
            \(prefix)App in front: \(r["app"] as? String ?? "?")
            Screen: \(w) x \(h) points
            Elements:
            \(r["elements"] as? String ?? "")
            """
            var content: [[String: Any]] = [["type": "text", "text": info]]
            if let img = r["image"] as? String, !img.isEmpty {
                content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": img]])
            }
            return Output(content: content)
        } catch {
            return fail("Couldn't look at the screen: \(error.localizedDescription)")
        }
    }

    private static func text(_ s: String) -> Output { Output(content: [["type": "text", "text": s]]) }
    private static func fail(_ s: String) -> Output { Output(content: [["type": "text", "text": s]], error: true) }

    // MARK: ui strings

    static func title(_ name: String) -> String {
        switch name {
        case "phone_look": "Used phone look"
        case "phone_act": "Used phone act"
        case "phone_apps": "Used phone apps"
        case "current_time": "Used current time"
        default: "Used \(name)"
        }
    }

    static func summary(_ name: String, _ input: [String: Any], _ out: Output) -> String {
        var s = ""
        if name == "phone_act" {
            let a = input["action"] as? String ?? ""
            func n(_ k: String) -> String { (input[k] as? NSNumber).map { "\(Int($0.doubleValue))" } ?? "?" }
            switch a {
            case "tap", "double_tap", "long_press": s = "\(a.replacingOccurrences(of: "_", with: " ")) at \(n("x")), \(n("y"))"
            case "swipe": s = "swipe \(n("x")), \(n("y")) to \(n("to_x")), \(n("to_y"))"
            case "type": s = "type \"\(input["text"] as? String ?? "")\""
            case "key": s = "press \(input["text"] as? String ?? "")"
            case "open_app": s = "open \(input["bundle_id"] as? String ?? "")"
            case "open_url": s = "open \(input["url"] as? String ?? "")"
            case "wait": s = "wait \(n("seconds"))s"
            default: s = a
            }
        }
        let firstLine = out.text.split(separator: "\n").first.map(String.init) ?? ""
        if out.error { s += (s.isEmpty ? "" : "\n") + firstLine }
        if name == "phone_look", let app = out.text.split(separator: "\n").first(where: { $0.hasPrefix("App in front") }) {
            s = String(app)
        }
        return s
    }
}
