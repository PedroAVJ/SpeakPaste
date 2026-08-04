import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput = ""
    @State private var apiKeyErrorMessage: String?
    @State private var showRemoveConfirmation = false

    private var trimmedInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                apiKeySection
                transcriptionSection
                clipboardSection
                privacySection
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .alert(
            "Couldn't Update Key",
            isPresented: Binding(
                get: { apiKeyErrorMessage != nil },
                set: { if !$0 { apiKeyErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(apiKeyErrorMessage ?? "")
        }
        .confirmationDialog(
            "Remove the saved API key?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Key", role: .destructive) {
                do {
                    try model.deleteAPIKey()
                } catch {
                    apiKeyErrorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to paste a key again before your next dictation.")
        }
    }

    private var apiKeySection: some View {
        Section {
            if model.hasAPIKey {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("API key saved")
                            .foregroundStyle(Theme.ink)
                        Text("Stored in the Keychain — never shown again.")
                            .font(.footnote)
                            .foregroundStyle(Theme.inkMuted)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            SecureField(
                model.hasAPIKey ? "Paste a replacement key" : "Paste your ElevenLabs API key",
                text: $apiKeyInput
            )
            .textContentType(.password)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .foregroundStyle(Theme.ink)

            Button {
                saveKey()
            } label: {
                Label("Save Key", systemImage: "key.fill")
            }
            .disabled(trimmedInput.isEmpty)

            if model.hasAPIKey {
                Button(role: .destructive) {
                    showRemoveConfirmation = true
                } label: {
                    Label("Remove Key", systemImage: "trash")
                        .foregroundStyle(Theme.danger)
                }
            }
        } header: {
            Text("ElevenLabs API Key")
        } footer: {
            Text(
                "Transcription runs on your ElevenLabs account and spends your Speech-to-Text credits. The key is stored only in this device's Keychain and is never displayed after saving."
            )
        }
        .listRowBackground(Theme.surface)
    }

    private var transcriptionSection: some View {
        Section {
            Picker("Language", selection: $model.language) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Clean Speech", isOn: $model.cleanSpeech)
                .foregroundStyle(Theme.ink)
        } header: {
            Text("Transcription")
        } footer: {
            Text(
                "Auto detects the spoken language. Clean Speech asks ElevenLabs to drop filler words and stumbles for paste-ready text."
            )
        }
        .listRowBackground(Theme.surface)
    }

    private var clipboardSection: some View {
        Section {
            Toggle("Auto-copy transcript", isOn: $model.autoCopy)
                .foregroundStyle(Theme.ink)
        } header: {
            Text("Clipboard")
        } footer: {
            Text(
                "Applies only to recordings started manually in this app. Keyboard dictations return through the SpeakPaste keyboard and type at the cursor instead."
            )
        }
        .listRowBackground(Theme.surface)
    }

    private var privacySection: some View {
        Section {
            EmptyView()
        } header: {
            Text("Privacy")
        } footer: {
            Text(
                "Audio leaves this device only when you transcribe, and goes directly to ElevenLabs. Transcripts, history, and settings stay on your iPhone."
            )
        }
    }

    private func saveKey() {
        do {
            try model.saveAPIKey(apiKeyInput)
            apiKeyInput = ""
        } catch {
            apiKeyErrorMessage = error.localizedDescription
        }
    }
}
