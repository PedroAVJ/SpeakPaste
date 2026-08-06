import AppIntents
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
                triggerSection
                transcriptionSection
                clipboardSection
                HistoryRetentionSection(history: model.history)
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

    /// The everyday trigger lives entirely in iOS Settings, so this section
    /// can only name the path and open the two places the user has to visit.
    /// Nothing here claims to assign Back Tap — no API does.
    private var triggerSection: some View {
        Section {
            ShortcutsLink()
                .shortcutsLinkStyle(.dark)

            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("Open iOS Settings", systemImage: "arrow.up.forward.app")
            }
            .accessibilityHint(
                "Opens SpeakPaste's page in Settings, where Live Activities are turned on."
            )
        } header: {
            Text("Dictation Trigger")
        } footer: {
            Text(
                "Back Tap runs the Toggle Dictation shortcut: the first double tap starts recording where you are, and later taps pause and resume. Assign it in Settings › Accessibility › Touch › Back Tap › Double Tap. Background capture also needs Live Activities turned on for SpeakPaste."
            )
        }
        .listRowBackground(Theme.surface)
    }

    private var transcriptionSection: some View {
        Section {
            NavigationLink {
                LanguagePickerView(selection: $model.language)
            } label: {
                LabeledContent {
                    Text(model.language.title)
                        .foregroundStyle(Theme.inkMuted)
                } label: {
                    Text("Language")
                        .foregroundStyle(Theme.ink)
                }
            }
            .accessibilityHint("Opens the full list of transcription languages.")

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

/// Full Scribe catalog picker. Auto, English, and Spanish stay one tap away at
/// the top; everything else is reachable by scrolling or searching.
private struct LanguagePickerView: View {
    @Binding var selection: TranscriptionLanguage
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private static let quickChoices: [TranscriptionLanguage] = [
        .automatic, .english, .spanish,
    ]

    private var otherLanguages: [TranscriptionLanguage] {
        TranscriptionLanguage.supportedCases.filter {
            !Self.quickChoices.contains($0)
        }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchResults: [TranscriptionLanguage] {
        TranscriptionLanguage.supportedCases.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.rawValue.localizedCaseInsensitiveContains(trimmedQuery)
                || ($0.apiCode?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
        }
    }

    var body: some View {
        List {
            if trimmedQuery.isEmpty {
                Section("Quick Choices") {
                    ForEach(Self.quickChoices) { language in
                        row(language)
                    }
                }
                .listRowBackground(Theme.surface)

                Section("All Languages") {
                    ForEach(otherLanguages) { language in
                        row(language)
                    }
                }
                .listRowBackground(Theme.surface)
            } else {
                Section {
                    ForEach(searchResults) { language in
                        row(language)
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .overlay {
            if !trimmedQuery.isEmpty, searchResults.isEmpty {
                ContentUnavailableView.search(text: trimmedQuery)
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search languages"
        )
        .navigationTitle("Language")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ language: TranscriptionLanguage) -> some View {
        Button {
            selection = language
            dismiss()
        } label: {
            HStack {
                Text(language.title)
                    .foregroundStyle(Theme.ink)
                Spacer()
                if language == selection {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(language == selection ? [.isSelected] : [])
    }
}

/// Retention picker that never deletes silently: choosing a policy that would
/// remove saved transcripts requires an explicit destructive confirmation.
private struct HistoryRetentionSection: View {
    @ObservedObject var history: HistoryStore
    @State private var pendingChange: PendingRetentionChange?

    private struct PendingRetentionChange: Identifiable {
        let policy: HistoryRetentionPolicy
        let itemsRemoved: Int
        var id: String { policy.id }
    }

    private var retentionBinding: Binding<HistoryRetentionPolicy> {
        Binding(
            get: { history.retention },
            set: { newPolicy in
                guard newPolicy != history.retention else { return }
                let removed = history.itemsRemoved(by: newPolicy)
                if removed > 0 {
                    pendingChange = PendingRetentionChange(
                        policy: newPolicy,
                        itemsRemoved: removed
                    )
                } else {
                    history.setRetention(newPolicy)
                }
            }
        )
    }

    var body: some View {
        Section {
            Picker("Keep History", selection: retentionBinding) {
                ForEach(HistoryRetentionPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            .pickerStyle(.menu)
            .foregroundStyle(Theme.ink)
        } header: {
            Text("History")
        } footer: {
            Text(history.retention.settingsDescription)
        }
        .listRowBackground(Theme.surface)
        .confirmationDialog(
            "Change history retention?",
            isPresented: Binding(
                get: { pendingChange != nil },
                set: { if !$0 { pendingChange = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingChange
        ) { change in
            Button(role: .destructive) {
                history.setRetention(change.policy)
            } label: {
                Text("Delete ^[\(change.itemsRemoved) Transcript](inflect: true)")
            }
            Button("Cancel", role: .cancel) {}
        } message: { change in
            if change.policy == .never {
                Text(
                    "History will be turned off, and ^[\(change.itemsRemoved) saved transcript](inflect: true) will be deleted from this iPhone."
                )
            } else {
                Text(
                    "Transcripts will be kept for \(change.policy.title.lowercased()), and ^[\(change.itemsRemoved) older transcript](inflect: true) will be deleted from this iPhone."
                )
            }
        }
    }
}
