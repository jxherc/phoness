import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var control = Control.shared
    @State private var auth = ClaudeAuth.shared
    @State private var key = Keychain.get("anthropic") ?? ""
    @State private var loginCode = ""
    @State private var loginError: String?
    @State private var keyError: String?
    @AppStorage("model") private var model = Models.all[0].id

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if auth.isSignedIn {
                        Text("signed in")
                        Button("sign out", role: .destructive) {
                            do {
                                try auth.signOut()
                                loginCode = ""
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                            }
                        }
                        .accessibilityIdentifier("claude.signOut")
                    } else if auth.pendingLogin {
                        Text("finish signing in in your browser, then paste the code here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        SecureField("authorization code", text: $loginCode)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .disabled(auth.isExchanging)
                            .accessibilityIdentifier("claude.code")
                        Button {
                            loginError = nil
                            Task {
                                do {
                                    try await auth.finishSignIn(loginCode)
                                    loginCode = ""
                                } catch {
                                    loginError = error.localizedDescription
                                }
                            }
                        } label: {
                            HStack {
                                Text(auth.isExchanging ? "signing in…" : "finish sign in")
                                if auth.isExchanging { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(auth.isExchanging || loginCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("claude.finish")
                        if let url = auth.authorizationURL {
                            Button("reopen browser") { openLogin(url) }
                                .disabled(auth.isExchanging)
                        }
                        Button("cancel sign in", role: .cancel) {
                            do {
                                try auth.cancelSignIn()
                                loginCode = ""
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                            }
                        }
                        .disabled(auth.isExchanging)
                        .accessibilityIdentifier("claude.cancel")
                    } else {
                        Button("sign in with claude") {
                            do {
                                loginError = nil
                                openLogin(try auth.beginSignIn())
                            } catch {
                                loginError = error.localizedDescription
                            }
                        }
                        .accessibilityIdentifier("claude.signIn")
                    }
                    if let loginError {
                        Text(loginError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("claude login")
                } footer: {
                    Text("experimental. anthropic may reject subscription access from this app, even after sign in.")
                }

                Section {
                    SecureField("sk-ant-…", text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: key) {
                            do {
                                try Keychain.set("anthropic", key.trimmingCharacters(in: .whitespacesAndNewlines))
                                keyError = nil
                            } catch {
                                keyError = error.localizedDescription
                            }
                        }
                    if let keyError {
                        Text(keyError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Anthropic API key")
                } footer: {
                    Text("kept in the keychain on this iPhone. used when signed out of claude.")
                }

                Section("Agent") {
                    NavigationLink {
                        ControlView()
                    } label: {
                        LabeledContent {
                            Text(control.phase.label)
                        } label: {
                            Label("iPhone Control", systemImage: "hand.tap")
                        }
                    }
                }

                Section("Model") {
                    Picker("Model", selection: $model) {
                        ForEach(Models.all, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.navigationLink)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func openLogin(_ url: URL) {
        openURL(url) { accepted in
            if !accepted {
                loginError = "couldn't open the browser. tap reopen browser to try again."
            }
        }
    }
}

struct ControlView: View {
    @State private var control = Control.shared
    @State private var importing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if control.phase == .starting { ProgressView().controlSize(.small) }
                        Text(control.phase.label)
                    }
                }
                if !control.message.isEmpty {
                    Text(control.message)
                        .font(.footnote)
                        .foregroundStyle(control.phase == .failed ? .red : .secondary)
                }
                switch control.phase {
                case .off, .failed:
                    Button("Turn On") { control.start() }
                        .disabled(!ready)
                case .starting:
                    Button("Cancel", role: .cancel) { control.stop() }
                case .on:
                    Button("Turn Off", role: .destructive) { control.stop() }
                }
            } footer: {
                Text("Starts a UI test runner on this iPhone through a local VPN, so the agent can see the screen and tap anywhere. iOS asks for your passcode each time it starts.")
            }

            Section("Setup") {
                LabeledContent("Pairing file") {
                    Text(pairingState)
                }
                Button(control.hasPairing ? "Replace Pairing File" : "Import Pairing File") { importing = true }
                LabeledContent("Developer disk image") {
                    Text(Control.ddiDir == nil ? "Missing" : "Included")
                }
            }

        }
        .navigationTitle("iPhone Control")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data]) { result in
            if case .success(let url) = result { control.importPairing(from: url) }
        }
        .task {
            // pick up a runner started from xcode
            if control.phase == .off, await Runner.alive() { _ = await control.ensureOn() }
        }
    }

    private var ready: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        control.hasPairing && Control.ddiDir != nil
        #endif
    }

    private var pairingState: String {
        guard let url = Control.pairingURL else { return "Missing" }
        return url == Control.importedPairing ? "Imported" : "Included"
    }
}

extension Control.Phase {
    var label: String {
        switch self {
        case .off: "Off"
        case .starting: "Starting"
        case .on: "On"
        case .failed: "Failed"
        }
    }
}
