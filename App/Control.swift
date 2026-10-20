import Foundation
import NetworkExtension
import Observation
import Launcher

// the runner is the ui test bundle (Runner target). it serves http on the phone's loopback.
enum Runner {
    static let port: UInt16 = 8123
    static let bundle = "com.jxherc.agent.runner.xctrunner"
    // new one each time we launch the runner
    nonisolated(unsafe) static var token = ""

    static func call(_ path: String, body: [String: Any]? = nil, timeout: Double = 60) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.timeoutInterval = timeout
        req.setValue(token, forHTTPHeaderField: "x-runner-token")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        if let arr = try JSONSerialization.jsonObject(with: data) as? [Any] { return ["list": arr] }
        return [:]
    }

    static func alive() async -> Bool {
        (try? await call("/status", timeout: 1.5))?["ok"] as? Bool == true
    }
}

@Observable @MainActor
final class Control {
    enum Phase { case off, starting, on, failed }

    var phase: Phase = .off
    var message = ""
    var hasPairing = false
    var apps: [[String: String]] = []

    static let shared = Control()

    private var job: Task<Void, Never>?

    init() { hasPairing = Self.pairingURL != nil }

    // imported file wins over one bundled by scripts/setup.sh
    static var importedPairing: URL {
        URL.applicationSupportDirectory.appending(path: "pairing.plist")
    }

    static var pairingURL: URL? {
        if FileManager.default.fileExists(atPath: importedPairing.path) { return importedPairing }
        return Bundle.main.url(forResource: "pairing", withExtension: "plist", subdirectory: "Device")
    }

    static var ddiDir: URL? {
        Bundle.main.url(forResource: "DDI", withExtension: nil, subdirectory: "Device")
    }

    func importPairing(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] != nil else {
                message = "That file isn't a pairing file."
                return
            }
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try data.write(to: Self.importedPairing)
            hasPairing = true
            message = ""
        } catch {
            message = "Couldn't import: \(error.localizedDescription)"
        }
    }

    // safe to call a lot. returns once the runner answers or start failed.
    func ensureOn() async -> Bool {
        if await Runner.alive() {
            if phase != .on || apps.isEmpty { await up() }
            return true
        }
        if job == nil { start() }
        await job?.value
        return phase == .on
    }

    func start() {
        guard job == nil else { return }
        job = Task {
            await run()
            job = nil
        }
    }

    private func run() async {
        phase = .starting
        message = ""
        if await Runner.alive() { return await up() }

        #if targetEnvironment(simulator)
        fail("In the simulator, start the runner from Xcode with Product > Test.")
        #else
        guard let pairing = Self.pairingURL else { return fail("Import a pairing file first.") }
        guard let ddi = Self.ddiDir else { return fail("The developer disk image is missing. Run scripts/setup.sh and rebuild.") }

        message = "Turning on the VPN"
        do { try await Tunnel.on() } catch { return fail("VPN: \(error.localizedDescription)") }

        Runner.token = UUID().uuidString
        launcher_start(pairing.path, ddi.path, Runner.bundle, Runner.port, Runner.token)

        // the passcode prompt can take a while, give it 2 minutes
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            let msg = Self.take(launcher_message())
            if !msg.isEmpty { message = msg.prefix(1).uppercased() + msg.dropFirst() }
            if launcher_phase() == 3 { return fail(message) }
            if await Runner.alive() { return await up() }
        }
        launcher_stop()
        fail("The runner didn't start. Try again.")
        #endif
    }

    private func up() async {
        phase = .on
        message = ""
        await loadApps()
        // give the runner the app list so it can tell which app is in front
        _ = try? await Runner.call("/known", body: ["apps": apps.compactMap { $0["id"] }])
    }

    private func fail(_ msg: String) {
        phase = .failed
        message = msg
    }

    func stop() {
        job?.cancel()
        job = nil
        Task { _ = try? await Runner.call("/stop", body: [:], timeout: 2) }
        #if !targetEnvironment(simulator)
        launcher_stop()
        Task { await Tunnel.off() }
        #endif
        phase = .off
        message = ""
    }

    func loadApps() async {
        var list: [[String: String]] = []
        #if !targetEnvironment(simulator)
        if let pairing = Self.pairingURL {
            let json = await Task.detached { Self.take(launcher_apps(pairing.path)) }.value
            if let arr = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: String]] {
                list = arr.filter { $0["type"] == "User" || $0["type"] == "System" }
            }
        }
        #endif
        if list.isEmpty, let res = try? await Runner.call("/apps"), let arr = res["list"] as? [[String: String]] {
            list = arr
        }
        apps = list.sorted { ($0["name"] ?? "") < ($1["name"] ?? "") }
    }

    nonisolated static func take(_ p: UnsafeMutablePointer<CChar>?) -> String {
        guard let p else { return "" }
        defer { launcher_free(p) }
        return String(cString: p)
    }
}

// the loopback vpn lives in the Tunnel extension
enum Tunnel {
    static let bundle = "com.jxherc.agent.tunnel"

    static func manager() async throws -> NETunnelProviderManager {
        let m = try await NETunnelProviderManager.loadAllFromPreferences().first ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = bundle
        proto.serverAddress = "10.7.0.1"
        m.protocolConfiguration = proto
        m.localizedDescription = "Agent loopback"
        m.isEnabled = true
        // first time this shows the "add vpn configuration" prompt
        try await m.saveToPreferences()
        try await m.loadFromPreferences()
        return m
    }

    static func on() async throws {
        let m = try await manager()
        if m.connection.status == .connected { return }
        try m.connection.startVPNTunnel()
        for _ in 0..<40 {
            if m.connection.status == .connected { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Claude.Failure(message: "it didn't connect")
    }

    static func off() async {
        try? await NETunnelProviderManager.loadAllFromPreferences().first?.connection.stopVPNTunnel()
    }
}
