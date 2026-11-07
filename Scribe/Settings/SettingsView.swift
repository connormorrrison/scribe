import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.appearance) private var appearance = Appearance.system
    @AppStorage(AppSettings.pageBackground) private var pageBackground = PageBackground.dots
    @AppStorage(AppSettings.drawWithFinger) private var drawWithFinger = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                ModelKeyRows(model: .ai)
            } header: {
                Text("AI Model")
            } footer: {
                Text("Your Anthropic API key. The agents use it to read your page and write, draw and build alongside you. Scribe only ever uses \(ClaudeModel.displayName).")
            }

            Section {
                ModelKeyRows(model: .voice)
            } header: {
                Text("Voice Model")
            } footer: {
                Text("Your ElevenLabs API key, used to hear you think out loud and to speak back.")
            }

            Section("Appearance") {
                LabeledContent("Theme") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
            }

            Section("Pages") {
                LabeledContent("Background") {
                    Picker("Background", selection: $pageBackground) {
                        ForEach(PageBackground.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
            }

            Section {
                Toggle("Draw with Finger", isOn: $drawWithFinger)
            } header: {
                Text("Drawing")
            } footer: {
                Text("When off, only Apple Pencil draws, and your finger scrolls and selects.")
            }

            Section {
                LabeledContent("Version", value: version)
            } header: {
                Text("About")
            } footer: {
                Text("API keys are stored in this iPad's Keychain and are only ever sent to Anthropic and ElevenLabs.")
            }
        }
        .roundedTitle("Settings", inline: true)
    }
}

/// A Keychain-backed API key and a connection test, as rows of one section.
private struct ModelKeyRows: View {
    let model: ModelService

    @State private var key = ""
    @State private var revealed = false
    @State private var loaded = false
    @State private var status = ConnectionStatus.idle

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if revealed {
                    TextField("API Key", text: $key)
                } else {
                    SecureField("API Key", text: $key)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 17, weight: .regular, design: .rounded).monospaced())

            if !key.isEmpty {
                Button(revealed ? "Hide Key" : "Show Key", systemImage: revealed ? "eye.slash" : "eye") {
                    revealed.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)

                Button("Remove Key", systemImage: "xmark.circle.fill") { key = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }

        HStack(spacing: 12) {
            Button("Test Connection") {
                status = .testing
                Task { status = await ConnectionTester.test(model, key: key) }
            }
            .disabled(key.isEmpty || status == .testing)

            Spacer(minLength: 0)
            statusLabel
        }
        .onAppear {
            guard !loaded else { return }
            key = Keychain.read(model) ?? ""
            loaded = true
        }
        .onChange(of: key) { _, new in
            guard loaded else { return }
            Keychain.save(new, for: model)
            status = .idle
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

}

#Preview {
    NavigationStack { SettingsView() }
}
