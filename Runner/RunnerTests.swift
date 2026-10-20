import XCTest

// not really a test. it's a long running xctest that serves a small http api
// so the app can see the screen and tap/type anywhere on the phone.
final class RunnerTests: XCTestCase {
    private var phone: Phone!

    override func record(_ issue: XCTIssue) {
        // don't fail the run, just hand the message back to the agent
        Phone.lastIssue = issue.compactDescription
    }

    @MainActor
    func testServe() throws {
        continueAfterFailure = true
        let port = UInt16(ProcessInfo.processInfo.environment["RUNNER_PORT"] ?? "") ?? 8123
        let phone = Phone()
        self.phone = phone
        // set when the app launched us. from xcode there's none, and that's fine for dev
        let token = ProcessInfo.processInfo.environment["RUNNER_TOKEN"] ?? ""
        let server = try Server(port: port) { req in
            if !token.isEmpty, req.token != token { return .json(["error": "bad token"], status: 403) }
            return MainActor.assumeIsolated { phone.handle(req) }
        }
        server.start()
        NSLog("runner listening on 127.0.0.1:%d", port)
        while !phone.stopped {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }
}

@MainActor
final class Phone {
    nonisolated(unsafe) static var lastIssue: String?

    var stopped = false
    private var current: String?
    private var known: [String] = []
    // reusing these skips xctest's per-instance setup, which is slow
    private var cache: [String: XCUIApplication] = [:]

    private func handleFor(_ id: String) -> XCUIApplication {
        if let a = cache[id] { return a }
        let a = XCUIApplication(bundleIdentifier: id)
        cache[id] = a
        return a
    }
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    init() {
        Self.skipIdleWaits()
        known = Self.installedApps().map { $0["id"] ?? "" }.filter { !$0.isEmpty }
    }

    // xctest waits for an app to stop animating before every action. busy apps never do,
    // so one tap can hang for a minute. skip the wait like webdriveragent does
    // and settle with a short fixed delay after each action instead.
    nonisolated(unsafe) static var skipIdle = true

    static func skipIdleWaits() {
        guard let cls = NSClassFromString("XCUIApplicationProcess") else { return }

        // (BOOL animations, BOOL preEvent)
        let two = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
        if let m = class_getInstanceMethod(cls, two), returnsVoid(m) {
            typealias F = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, Bool, Bool) -> Void = { obj, a, b in
                if !Phone.skipIdle { orig(obj, two, a, b) }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }

        // (BOOL animations, BOOL usingActivity, BOOL preEvent), going by its type encoding
        let three = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:usingActivity:isPreEvent:")
        if let m = class_getInstanceMethod(cls, three), returnsVoid(m),
           String(cString: method_getTypeEncoding(m)!).hasSuffix("B16B20B24") {
            typealias F = @convention(c) (AnyObject, Selector, Bool, Bool, Bool) -> Void
            let orig = unsafeBitCast(method_getImplementation(m), to: F.self)
            let block: @convention(block) (AnyObject, Bool, Bool, Bool) -> Void = { obj, a, b, c in
                if !Phone.skipIdle { orig(obj, three, a, b, c) }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    private static func returnsVoid(_ m: Method) -> Bool {
        guard let enc = method_getTypeEncoding(m) else { return false }
        return String(cString: enc).hasPrefix("v")
    }

    // springboard's frame is the whole screen, in points
    private(set) lazy var screen: CGSize = springboard.frame.size

    func handle(_ req: Server.Request) -> Server.Response {
        Phone.lastIssue = nil
        switch (req.method, req.path) {
        case ("GET", "/status"):
            return .json(["ok": true, "width": screen.width, "height": screen.height])
        case ("GET", "/look"):
            return look()
        case ("POST", "/act"):
            return act(req.json)
        case ("GET", "/apps"):
            return .json(Self.installedApps())
        case ("POST", "/known"):
            if let ids = req.json["apps"] as? [String] { known = ids }
            return .json(["ok": true])
        case ("POST", "/stop"):
            stopped = true
            return .json(["ok": true])
        default:
            return .json(["error": "no such endpoint"], status: 404)
        }
    }

    // MARK: look

    private func look() -> Server.Response {
        let (app, id) = foreground()

        // shrink to points so image pixels == tap coordinates
        let shot = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: screen, format: format).image { _ in
            shot.draw(in: CGRect(origin: .zero, size: screen))
        }
        let jpeg = img.jpegData(compressionQuality: 0.6) ?? Data()

        var elements: String
        do {
            elements = describe(try app.snapshot())
        } catch {
            elements = "(couldn't read elements: \(error.localizedDescription))"
        }
        return .json([
            "app": id,
            "width": screen.width,
            "height": screen.height,
            "image": jpeg.base64EncodedString(),
            "elements": elements,
        ])
    }

    // which app is in front. checks the last one first, then scans.
    // there's no public api for this, so it's a loop over app states.
    private func foreground() -> (XCUIApplication, String) {
        var seen = Set<String>()
        for id in [current].compactMap({ $0 }) + known {
            guard seen.insert(id).inserted, id != "com.apple.springboard" else { continue }
            let app = handleFor(id)
            if app.state == .runningForeground {
                current = id
                return (app, id)
            }
        }
        current = nil
        return (springboard, "com.apple.springboard")
    }

    private func describe(_ root: XCUIElementSnapshot) -> String {
        let bounds = CGRect(origin: .zero, size: screen)
        var lines: [String] = []
        var keyboard = false

        func walk(_ e: XCUIElementSnapshot, parentLabel: String) {
            if lines.count >= 300 { return }
            let t = e.elementType
            if t == .keyboard {
                keyboard = true
                return
            }

            let label = String(e.label.prefix(80))
            let value = String((e.value as? String ?? "").prefix(80))
            let hint = e.placeholderValue ?? ""
            let f = e.frame.intersection(bounds)

            let named = !label.isEmpty || !value.isEmpty || !hint.isEmpty
            // unnamed cells and containers are just noise, their children carry the text
            let skip = [.application, .window].contains(t)
                || ([.other, .cell, .table, .collectionView, .scrollView].contains(t) && label.isEmpty)
                || label.hasSuffix("scroll bar, 1 page") || label.contains("scroll bar,")
            if !f.isNull, f.width > 1, f.height > 1, named || Self.tappable.contains(t), !skip,
               !(label == parentLabel && value.isEmpty) {
                var line = Self.name(t)
                if !label.isEmpty { line += " \"\(label)\"" }
                if !value.isEmpty, value != label { line += " value=\"\(value)\"" }
                if !hint.isEmpty, value.isEmpty { line += " placeholder=\"\(hint)\"" }
                if e.isSelected { line += " selected" }
                if !e.isEnabled { line += " disabled" }
                line += " @ \(Int(f.midX)),\(Int(f.midY))"
                if lines.last != line { lines.append(line) }
            }
            for c in e.children { walk(c, parentLabel: label.isEmpty ? parentLabel : label) }
        }
        walk(root, parentLabel: "")

        if keyboard { lines.append("(keyboard is open)") }
        return lines.isEmpty ? "(no readable elements, use the screenshot)" : lines.joined(separator: "\n")
    }

    static let tappable: [XCUIElement.ElementType] = [
        .button, .textField, .secureTextField, .searchField, .textView, .switch, .toggle,
        .slider, .link, .cell, .tab, .segmentedControl, .stepper, .picker, .pickerWheel, .menuItem,
    ]

    static func name(_ t: XCUIElement.ElementType) -> String {
        switch t {
        case .button: "button"
        case .staticText: "text"
        case .textField: "field"
        case .secureTextField: "password field"
        case .searchField: "search field"
        case .textView: "text area"
        case .image, .icon: "image"
        case .cell: "cell"
        case .link: "link"
        case .switch, .toggle: "switch"
        case .slider: "slider"
        case .tab: "tab"
        case .segmentedControl: "segments"
        case .navigationBar: "nav bar"
        case .alert: "alert"
        case .sheet: "sheet"
        case .webView: "web view"
        case .picker, .pickerWheel: "picker"
        case .menuItem: "menu item"
        case .table, .collectionView, .scrollView: "list"
        default: "element"
        }
    }

    // MARK: act

    private func act(_ a: [String: Any]) -> Server.Response {
        let action = a["action"] as? String ?? ""
        let (app, _) = foreground()
        let origin = app.coordinate(withNormalizedOffset: .zero)
        func num(_ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue }
        func point(_ kx: String, _ ky: String) -> XCUICoordinate? {
            guard let x = num(kx), let y = num(ky),
                  (0...screen.width).contains(x), (0...screen.height).contains(y) else { return nil }
            return origin.withOffset(CGVector(dx: x, dy: y))
        }
        let text = a["text"] as? String ?? ""

        switch action {
        case "tap", "double_tap", "long_press":
            guard let p = point("x", "y") else { return bad("\(action) needs x and y on screen (0-\(Int(screen.width)), 0-\(Int(screen.height)))") }
            if action == "tap" { p.tap() }
            if action == "double_tap" { p.doubleTap() }
            if action == "long_press" { p.press(forDuration: num("seconds") ?? 1) }
        case "swipe":
            guard let from = point("x", "y"), let to = point("to_x", "to_y") else {
                return bad("swipe needs x, y, to_x, to_y, all on screen")
            }
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0)
        case "type":
            guard !text.isEmpty else { return bad("type needs text") }
            app.typeText(text)
        case "key":
            let keys: [String: String] = [
                "return": XCUIKeyboardKey.return.rawValue, "enter": XCUIKeyboardKey.return.rawValue,
                "delete": XCUIKeyboardKey.delete.rawValue, "backspace": XCUIKeyboardKey.delete.rawValue,
                "tab": XCUIKeyboardKey.tab.rawValue, "space": " ",
            ]
            guard let k = keys[text.lowercased()] else { return bad("unknown key \(text)") }
            let times = max(1, min(Int(num("count") ?? 1), 50))
            app.typeText(String(repeating: k, count: times))
        case "home":
            XCUIDevice.shared.press(.home)
            current = nil
        case "open_app":
            guard let id = a["bundle_id"] as? String, !id.isEmpty else { return bad("open_app needs bundle_id") }
            handleFor(id).activate()
            current = id
            // no idle wait anymore, give the launch a moment
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        case "open_url":
            guard let url = URL(string: a["url"] as? String ?? "") else { return bad("open_url needs a url") }
            XCUIDevice.shared.system.open(url)
            current = nil
        case "wait":
            RunLoop.current.run(until: Date().addingTimeInterval(min(num("seconds") ?? 1, 10)))
        default:
            return bad("unknown action \(action)")
        }

        if let issue = Phone.lastIssue { return .json(["error": issue]) }
        // let animations settle before the next look
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        return .json(["ok": true])
    }

    private func bad(_ msg: String) -> Server.Response { .json(["error": msg], status: 400) }

    // MARK: apps

    // private api, but this runs as a test runner so nobody's reviewing it
    static func installedApps() -> [[String: String]] {
        guard let cls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let ws = cls.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
        else { return [] }
        let sel = NSSelectorFromString("allApplications")
        guard ws.responds(to: sel),
              let apps = ws.perform(sel)?.takeUnretainedValue() as? [NSObject]
        else { return [] }

        return apps.compactMap { p in
            let get = { (k: String) in p.responds(to: NSSelectorFromString(k)) ? p.value(forKey: k) as? String : nil }
            guard let id = get("applicationIdentifier"), let type = get("applicationType"),
                  type == "User" || type == "System",
                  let name = get("localizedName"), !name.isEmpty
            else { return nil }
            if p.responds(to: NSSelectorFromString("appTags")),
               let tags = p.value(forKey: "appTags") as? [String], tags.contains("hidden") { return nil }
            return ["id": id, "name": name]
        }
        .sorted { $0["name"]! < $1["name"]! }
    }
}
