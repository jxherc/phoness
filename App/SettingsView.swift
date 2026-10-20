import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var control = Control.shared
    @State private var key = Keychain.get("anthropic") ?? ""
    @AppStorage("model") private var model = Models.all[0].id

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: key) { Keychain.set("anthropic", key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                } header: {
                    Text("Anthropic API key")
                } footer: {
                    Text("Kept in the keychain on this iPhone.")
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
