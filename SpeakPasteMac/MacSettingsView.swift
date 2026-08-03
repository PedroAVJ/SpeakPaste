import SwiftUI

struct MacSettingsView: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        TabView {
            MacGeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            MacVocabularySettings()
                .tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            MacReplacementSettings()
                .tabItem { Label("Replacements", systemImage: "arrow.left.arrow.right") }
            MacHistorySettings()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            MacPermissionSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .environmentObject(model)
        .frame(width: 560, height: 460)
    }
}

// MARK: General

private struct MacGeneralSettings: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Language", selection: $model.language) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Toggle("Clean up filler words and stumbles", isOn: $model.cleanSpeech)
                Text("Every dictation uses ElevenLabs Scribe. There is no model to choose — the best available one is the only one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Delivery") {
                Toggle("Paste into the app you were using", isOn: $model.autoPaste)
                Toggle(
                    "Play sounds",
                    isOn: Binding(
                        get: { model.sounds.isEnabled },
                        set: { model.sounds.isEnabled = $0 }
                    )
                )
                Text("Tap \(model.hotKeyLabel) to start and stop. Press \(model.releaseHotKeyLabel) to place held text at your cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle(
                    "Launch SpeakPaste at login",
                    isOn: Binding(
                        get: { model.permissions.granted[.launchAtLogin] ?? false },
                        set: { model.permissions.setLaunchAtLogin($0) }
                    )
                )
            }

            Section("ElevenLabs API key") {
                if model.hasSavedAPIKey {
                    HStack {
                        Label("A key is saved in the Keychain", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Remove") { model.deleteAPIKey() }
                    }
                }
                HStack {
                    SecureField(
                        model.hasSavedAPIKey ? "Replace the saved key" : "Paste your API key",
                        text: $model.apiKeyDraft
                    )
                    Button("Save") { model.saveAPIKey() }
                        .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Vocabulary

private struct MacVocabularySettings: View {
    @EnvironmentObject private var model: MacAppModel
    @State private var draft = ""
    @State private var failure: String?
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Names, jargon, and spellings Scribe should expect. These are sent with every dictation so recognition leans toward them — they are a hint, not a find-and-replace, so an unused term costs nothing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Add a word or phrase", text: $draft)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            List(model.vocabulary.terms, id: \.self, selection: $selection) { term in
                Text(term)
            }
            .listStyle(.bordered)

            HStack {
                Text("\(model.vocabulary.terms.count) of \(MacVocabularyStore.maximumTerms)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Import…") { importFile() }
                Button("Remove") {
                    for term in selection { model.vocabulary.remove(term) }
                    selection.removeAll()
                }
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
    }

    private func add() {
        let term = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = MacVocabularyStore.validationFailure(for: term) {
            failure = reason
            return
        }
        failure = model.vocabulary.add(term) ? nil : "That term is already in the list."
        if failure == nil { draft = "" }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return }
        let added = model.vocabulary.importDelimited(raw)
        failure = "Imported \(added) term\(added == 1 ? "" : "s")."
    }
}

// MARK: Replacements

private struct MacReplacementSettings: View {
    @EnvironmentObject private var model: MacAppModel
    @State private var spoken = ""
    @State private var written = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exact substitutions applied to every transcript after it comes back. Unlike vocabulary, these always fire — use them for things Scribe reliably gets wrong.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Heard as", text: $spoken)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Written as", text: $written)
                Button("Add") {
                    model.replacements.add(spoken: spoken, written: written)
                    spoken = ""
                    written = ""
                }
                .disabled(spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List {
                ForEach(model.replacements.replacements) { replacement in
                    HStack {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { replacement.isEnabled },
                                set: { isEnabled in
                                    var updated = replacement
                                    updated.isEnabled = isEnabled
                                    model.replacements.update(updated)
                                }
                            )
                        )
                        .labelsHidden()
                        Text(replacement.spoken)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(replacement.written)
                            .fontWeight(.medium)
                        Spacer()
                        Button {
                            model.replacements.remove(replacement.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.bordered)
        }
        .padding(20)
    }
}

// MARK: History

private struct MacHistorySettings: View {
    @EnvironmentObject private var model: MacAppModel
    @State private var query = ""
    @State private var confirmingPurge = false

    private var records: [MacTranscriptRecord] {
        query.isEmpty ? model.history.records : model.history.search(query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search transcripts", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker(
                    "Keep for",
                    selection: Binding(
                        get: { model.history.retentionDays },
                        set: { model.history.retentionDays = $0 }
                    )
                ) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                .frame(width: 170)
            }

            List(records) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.text)
                        .lineLimit(3)
                    HStack(spacing: 6) {
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let destination = record.destination {
                            Text("· \(destination)")
                        }
                        Spacer()
                        Button("Copy") {
                            model.copyText(record.text)
                        }
                        .buttonStyle(.borderless)
                        Button("Paste here") {
                            model.pasteText(record.text)
                        }
                        .buttonStyle(.borderless)
                        Button {
                            model.history.delete(record.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)

            HStack {
                Text("\(model.history.records.count) transcript\(model.history.records.count == 1 ? "" : "s") on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete All…", role: .destructive) { confirmingPurge = true }
            }
        }
        .padding(20)
        .confirmationDialog(
            "Delete every saved transcript?",
            isPresented: $confirmingPurge
        ) {
            Button("Delete All", role: .destructive) { model.history.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases the history file on disk. It cannot be undone.")
        }
    }
}

// MARK: Permissions

private struct MacPermissionSettings: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SpeakPaste checks these live. macOS can revoke any of them at any time, and a revoked grant is otherwise invisible — the shortcut simply stops working.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(MacPermission.allCases) { permission in
                let isGranted = model.permissions.granted[permission] ?? false
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(isGranted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title)
                            .fontWeight(.medium)
                        Text(permission.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if !isGranted {
                        Button("Grant") { model.permissions.request(permission) }
                    }
                    Button("Settings") { model.permissions.openSettings(for: permission) }
                        .controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            }

            if !model.isShortcutGlobal {
                Text("The \(model.hotKeyLabel) shortcut currently works only while SpeakPaste is the frontmost app. Grant Accessibility to use it from anywhere.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(20)
        .onAppear { model.permissions.refresh() }
    }
}
