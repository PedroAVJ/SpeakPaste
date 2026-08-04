import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The macOS language menus pin SpeakPaste's original three choices at the
/// top; the rest of the Scribe catalog follows alphabetically behind a
/// separator so a hundred entries never bury Auto, English, and Spanish.
extension TranscriptionLanguage {
    static let macPinnedChoices: [TranscriptionLanguage] = [.automatic, .english, .spanish]
    static let macAdditionalChoices: [TranscriptionLanguage] =
        allCases.filter { !macPinnedChoices.contains($0) }
}

struct MacSettingsView: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        TabView {
            MacGeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            MacAudioHUDSettings()
                .tabItem { Label("Audio & Indicator", systemImage: "waveform.badge.mic") }
            MacDictionarySettings()
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
            MacAppRulesSettings()
                .tabItem { Label("App Rules", systemImage: "macwindow.badge.plus") }
            MacHistorySettings()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            MacPermissionSettings()
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .environmentObject(model)
        .frame(minWidth: 620, idealWidth: 640, minHeight: 480, idealHeight: 520)
    }
}

// MARK: - General

private struct MacGeneralSettings: View {
    @EnvironmentObject private var model: MacAppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingAPIKeyRemoval = false

    var body: some View {
        Form {
            Section("Transcription") {
                Picker("Language", selection: $model.language) {
                    ForEach(TranscriptionLanguage.macPinnedChoices) { language in
                        Text(language.title).tag(language)
                    }
                    Divider()
                    ForEach(TranscriptionLanguage.macAdditionalChoices) { language in
                        Text(language.title).tag(language)
                    }
                }
                Toggle("Clean up filler words and stumbles", isOn: $model.cleanSpeech)
                Toggle("Spoken formatting commands", isOn: $model.spokenFormattingCommands)
                Text("Saying “new line”, “new paragraph”, or a punctuation name produces the formatting instead of the words. Every dictation uses ElevenLabs Scribe — there is no model to choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Delivery") {
                Toggle("Paste into the app you were using", isOn: $model.autoPaste)
                Toggle(
                    "Hold delivery while recording",
                    isOn: $model.holdDeliveryWhileRecording
                )
                Text("Keeps finished chunks in spoken order while the microphone is live, then delivers them in the pauses between chunks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Context awareness", isOn: $model.contextAwareness)
                Text("When on, SpeakPaste extracts candidate names and code identifiers from a small caret-local text window, the selection, the window title, and the app name. When hints are found, they are sent as ElevenLabs keyterms and use keyterm pricing. Per-app rules can override this global setting. Separately, local spacing and capitalization may read up to 256 characters before the caret in memory; that text is never uploaded or stored, and secure fields are never read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance & startup") {
                Toggle("Show SpeakPaste in the Dock", isOn: $model.showInDock)
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
                        Button("Remove…", role: .destructive) {
                            confirmingAPIKeyRemoval = true
                        }
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
                if let notice = model.apiKeyNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Setup") {
                HStack {
                    Text("First-run walkthrough")
                    Spacer()
                    Button("Replay Onboarding…") {
                        model.showOnboardingAgain()
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
                Text("Reopens the guided setup in the main window: API key, permissions, microphone test, and shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remove the saved ElevenLabs API key?",
            isPresented: $confirmingAPIKeyRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Key", role: .destructive) { model.deleteAPIKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SpeakPaste will no longer be able to transcribe until another key is saved or provided through the environment.")
        }
    }
}

// MARK: - Audio & Indicator

private struct MacAudioHUDSettings: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        Form {
            Section("Status indicator") {
                Toggle("Show the floating status indicator", isOn: $model.hudEnabled)
                Picker("Placement", selection: $model.hudPlacement) {
                    Text("Top").tag(MacHUDPlacement.top)
                    Text("Bottom").tag(MacHUDPlacement.bottom)
                    Text("Left").tag(MacHUDPlacement.left)
                    Text("Right").tag(MacHUDPlacement.right)
                }
                .disabled(!model.hudEnabled)
                Text("A wordless, click-through Liquid Glass capsule spring-morphs between a connecting pulse, your live voice waveform, release, and estimated transcription progress, then disappears. A new hold gets one count-free tray acknowledgment for two seconds; recovery entries never replay here. A stalled transcription cannot keep it onscreen for more than 90 seconds. It has no buttons and never takes focus; the main window and menu bar remain authoritative for errors, offline status, and waiting text. Top keeps it clear of the text fields most apps put at the bottom of the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sounds") {
                Toggle(
                    "Play capture, delivery, and error sounds",
                    isOn: Binding(
                        get: { model.sounds.isEnabled },
                        set: { model.sounds.isEnabled = $0 }
                    )
                )
                Text("Three single pings rise through capture, release, and verified delivery. Errors are the family's only phrase: low and falling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                shortcutRow(model.hotKeyLabel, spokenKey: "Right Command key", purpose: "Start or stop a dictation")
                shortcutRow(model.switchInputHotKeyLabel, spokenKey: "Right Command key twice", purpose: "Switch between Mac and iPhone input — even mid-dictation")
                shortcutRow(model.cancelHotKeyLabel, spokenKey: "Escape key", purpose: "Cancel immediately — the recording is discarded, nothing is transcribed")
                shortcutRow(model.releaseHotKeyLabel, spokenKey: "Option Command V", purpose: "Paste held or recovered text at the cursor")
                shortcutRow(model.pasteLastHotKeyLabel, spokenKey: "Control Command V", purpose: "Paste the last transcript again")
                shortcutRow(model.copyLastHotKeyLabel, spokenKey: "Control Command C", purpose: "Copy the last transcript")
                Text("The bare right ⌘ tap is reserved for dictation. Ordinary shortcuts that use the left ⌘ key remain available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Text("Microphone selection, fallback order, input gain, and the 3-second record-and-playback test live in the main window, along with its live level meter and result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ key: String, spokenKey: String, purpose: String) -> some View {
        HStack {
            Text(purpose)
            Spacer()
            Text(key)
                .font(.callout.weight(.medium))
                .monospaced()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(purpose): \(spokenKey)")
    }
}

// MARK: - Dictionary (vocabulary + replacements)

private struct MacDictionarySettings: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case vocabulary = "Vocabulary"
        case replacements = "Replacements"

        var id: String { rawValue }
    }

    @State private var pane: Pane = .vocabulary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Section", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 280)
            .accessibilityLabel("Dictionary section")

            switch pane {
            case .vocabulary: MacVocabularyPane()
            case .replacements: MacReplacementPane()
            }
        }
        .padding(20)
    }
}

private struct MacVocabularyPane: View {
    @EnvironmentObject private var model: MacAppModel
    @State private var draft = ""
    @State private var searchQuery = ""
    @State private var failure: String?
    @State private var selection: Set<String> = []
    @State private var termsPendingRemoval: Set<String> = []
    @State private var termPendingEdit: MacVocabularyEditTarget?
    @State private var showingPasteImport = false

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleTerms: [String] {
        guard !trimmedSearchQuery.isEmpty else { return model.vocabulary.terms }
        return model.vocabulary.terms.filter { $0.localizedStandardContains(trimmedSearchQuery) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Names, jargon, and spellings Scribe should expect. These are recognition hints, not find-and-replace rules. When at least one is sent, ElevenLabs currently adds a 20% keyterm surcharge; more than 100 also makes each request bill for at least 20 seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Add a word or phrase", text: $draft)
                    .onSubmit(add)
                    .onChange(of: draft) {
                        failure = nil
                    }
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField("Search terms", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search vocabulary terms")

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let persistenceError = model.vocabulary.lastPersistenceError {
                Label(
                    "Vocabulary changes are not being saved: \(persistenceError)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            List(visibleTerms, id: \.self, selection: $selection) { term in
                HStack {
                    Text(term)
                    Spacer()
                    Button("Edit") { termPendingEdit = MacVocabularyEditTarget(term: term) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityLabel("Edit the term \(term)")
                }
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "Edit term") {
                    termPendingEdit = MacVocabularyEditTarget(term: term)
                }
            }
            .listStyle(.bordered)
            .overlay {
                if visibleTerms.isEmpty, !model.vocabulary.terms.isEmpty {
                    Text("No terms match “\(trimmedSearchQuery)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Paste List…") { showingPasteImport = true }
                Button("Import File…") { importFile() }
                Button("Remove") {
                    termsPendingRemoval = selectedVisibleTerms
                }
                .disabled(selectedVisibleTerms.isEmpty)
            }
        }
        .sheet(item: $termPendingEdit) { target in
            MacVocabularyTermEditor(
                original: target.term,
                onSave: { edited in
                    if let problem = commitEdit(of: target.term, to: edited) {
                        return problem
                    }
                    termPendingEdit = nil
                    return nil
                },
                onCancel: { termPendingEdit = nil }
            )
        }
        .sheet(isPresented: $showingPasteImport) {
            MacVocabularyPasteImportSheet(
                remainingCapacity: max(
                    0,
                    MacVocabularyStore.maximumTerms - model.vocabulary.terms.count
                ),
                onImport: { raw in
                    let added = model.vocabulary.importDelimited(raw)
                    if added > 0 {
                        failure = "Imported \(added) term\(added == 1 ? "" : "s")."
                        showingPasteImport = false
                        return nil
                    }
                    if let persistenceError = model.vocabulary.lastPersistenceError {
                        return "No terms were imported: \(persistenceError)"
                    }
                    return "No new valid terms were found. Entries may be blank, contain unsupported Scribe characters, exceed \(MacVocabularyStore.maximumCharactersPerTerm) characters or \(MacVocabularyStore.maximumWordsPerTerm) words, duplicate the list, or exceed the \(MacVocabularyStore.maximumTerms.formatted())-term limit."
                },
                onCancel: { showingPasteImport = false }
            )
        }
        .confirmationDialog(
            termsPendingRemoval.count == 1
                ? "Remove this vocabulary term?"
                : "Remove \(termsPendingRemoval.count) vocabulary terms?",
            isPresented: Binding(
                get: { !termsPendingRemoval.isEmpty },
                set: { if !$0 { termsPendingRemoval.removeAll() } }
            ),
            titleVisibility: .visible
        ) {
            Button(
                termsPendingRemoval.count == 1 ? "Remove Term" : "Remove Terms",
                role: .destructive
            ) {
                var removed: Set<String> = []
                for term in termsPendingRemoval where model.vocabulary.remove(term) {
                    removed.insert(term)
                }
                selection.subtract(removed)
                if removed.count == termsPendingRemoval.count {
                    failure = nil
                } else {
                    failure = model.vocabulary.lastPersistenceError.map {
                        "The selected terms were not all removed: \($0)"
                    } ?? "The selected terms were not all removed."
                }
                termsPendingRemoval.removeAll()
            }
            Button("Cancel", role: .cancel) { termsPendingRemoval.removeAll() }
        } message: {
            Text("The removed spellings will no longer be sent to Scribe as recognition hints.")
        }
    }

    private var countLabel: String {
        let total = model.vocabulary.terms.count
        let base = "\(total) of \(MacVocabularyStore.maximumTerms.formatted())"
        guard !trimmedSearchQuery.isEmpty else { return base }
        return "\(base) · \(visibleTerms.count) match\(visibleTerms.count == 1 ? "" : "es")"
    }

    /// A search must never leave an off-screen row armed for deletion. The
    /// selection may remain remembered for Finder-like navigation, but the
    /// destructive action is limited to rows the user can currently see.
    private var selectedVisibleTerms: Set<String> {
        selection.intersection(Set(visibleTerms))
    }

    private func add() {
        let term = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = MacVocabularyStore.validationFailure(for: term) {
            failure = reason
            return
        }
        if model.vocabulary.add(term) {
            failure = nil
            draft = ""
        } else if let persistenceError = model.vocabulary.lastPersistenceError {
            failure = "The term was not saved: \(persistenceError)"
        } else {
            failure = "That term is already in the list or the vocabulary is full."
        }
    }

    /// Edits go through `replaceAll` so the change is one atomic document
    /// write — the original term is never dropped unless its replacement
    /// persisted alongside the rest of the list.
    private func commitEdit(of original: String, to newTerm: String) -> String? {
        let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != original else { return nil }
        if let reason = MacVocabularyStore.validationFailure(for: trimmed) {
            return reason
        }
        let newKey = trimmed.lowercased()
        let originalKey = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if newKey != originalKey,
           model.vocabulary.terms.contains(where: { $0.lowercased() == newKey }) {
            return "That term is already in the list."
        }
        let updated = model.vocabulary.terms.map { $0 == original ? trimmed : $0 }
        guard model.vocabulary.replaceAll(updated) else {
            return model.vocabulary.lastPersistenceError
                ?? "The edited term could not be saved."
        }
        selection.remove(original)
        failure = nil
        return nil
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            failure = "The selected vocabulary file could not be read."
            return
        }
        let added = model.vocabulary.importDelimited(raw)
        if added > 0 {
            failure = "Imported \(added) term\(added == 1 ? "" : "s")."
        } else if let persistenceError = model.vocabulary.lastPersistenceError {
            failure = "No terms were imported: \(persistenceError)"
        } else {
            failure = "No new valid terms were found."
        }
    }
}

/// Sheet identity wrapper for editing a single vocabulary term.
private struct MacVocabularyEditTarget: Identifiable {
    let term: String

    var id: String { term }
}

private struct MacVocabularyTermEditor: View {
    let original: String
    /// Returns nil once the edit is durable; a message keeps the sheet open
    /// with the draft intact.
    let onSave: (String) -> String?
    let onCancel: () -> Void

    @State private var draft: String
    @State private var validationMessage: String?

    init(
        original: String,
        onSave: @escaping (String) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Vocabulary Term")
                .font(.headline)

            TextField("Word or phrase", text: $draft)
                .onSubmit(save)
                .accessibilityLabel("Vocabulary term")

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Up to \(MacVocabularyStore.maximumCharactersPerTerm) characters and \(MacVocabularyStore.maximumWordsPerTerm) words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        validationMessage = onSave(draft)
    }
}

private struct MacVocabularyPasteImportSheet: View {
    let remainingCapacity: Int
    /// Returns nil when at least one term was imported and the sheet may
    /// close; a message keeps the sheet open with the pasted text intact.
    let onImport: (String) -> String?
    let onCancel: () -> Void

    @State private var text = ""
    @State private var resultMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste a Vocabulary List")
                .font(.headline)

            Text("One term per line, or separated by commas. Blank, over-limit, and duplicate entries are skipped, so one bad line never blocks the rest.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 460, minHeight: 200)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                )
                .accessibilityLabel("Vocabulary terms to import, one per line")

            if let resultMessage {
                Label(resultMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(
                    remainingCapacity == 1
                        ? "1 more term fits in the list."
                        : "\(remainingCapacity.formatted()) more terms fit in the list."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Add Terms") { resultMessage = onImport(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

private struct MacReplacementPane: View {
    @EnvironmentObject private var model: MacAppModel
    @State private var spoken = ""
    @State private var written = ""
    @State private var searchQuery = ""
    @State private var replacementPendingDeletion: MacTextReplacement?
    @State private var replacementPendingEdit: MacTextReplacement?
    @State private var failure: String?

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleReplacements: [MacTextReplacement] {
        guard !trimmedSearchQuery.isEmpty else { return model.replacements.replacements }
        return model.replacements.replacements.filter {
            $0.spoken.localizedStandardContains(trimmedSearchQuery)
                || $0.written.localizedStandardContains(trimmedSearchQuery)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exact substitutions applied to every transcript after it comes back. Unlike vocabulary, these always fire — use them for things Scribe reliably gets wrong. The Learn Edits button on the main window adds rules here automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField("Heard as", text: $spoken)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Written as", text: $written)
                Button("Add") {
                    if model.replacements.add(spoken: spoken, written: written) {
                        failure = nil
                        spoken = ""
                        written = ""
                    } else {
                        failure = model.replacements.lastPersistenceError.map {
                            "The replacement was not saved: \($0)"
                        } ?? "The replacement was not saved. The list may be full."
                    }
                }
                .disabled(spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            TextField("Search replacements", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search replacements")

            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let persistenceError = model.replacements.lastPersistenceError {
                Label(
                    "Replacement changes are not being saved: \(persistenceError)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            List {
                ForEach(visibleReplacements) { replacement in
                    HStack {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { replacement.isEnabled },
                                set: { isEnabled in
                                    var updated = replacement
                                    updated.isEnabled = isEnabled
                                    if model.replacements.update(updated) {
                                        failure = nil
                                    } else {
                                        failure = model.replacements.lastPersistenceError.map {
                                            "The replacement edit was not saved: \($0)"
                                        } ?? "The replacement edit was not saved."
                                    }
                                }
                            )
                        )
                        .labelsHidden()
                        .accessibilityLabel("Enable replacing \(replacement.spoken) with \(replacement.written)")
                        Text(replacement.spoken)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(replacement.written)
                            .fontWeight(.medium)
                        Spacer()
                        Button("Edit") {
                            replacementPendingEdit = replacement
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityLabel("Edit the \(replacement.spoken) replacement")
                        Button {
                            replacementPendingDeletion = replacement
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete the \(replacement.spoken) replacement")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(named: "Edit replacement") {
                        replacementPendingEdit = replacement
                    }
                    .accessibilityAction(named: "Delete replacement") {
                        replacementPendingDeletion = replacement
                    }
                }
            }
            .listStyle(.bordered)
            .overlay {
                if visibleReplacements.isEmpty, !model.replacements.replacements.isEmpty {
                    Text("No replacements match “\(trimmedSearchQuery)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $replacementPendingEdit) { replacement in
            MacReplacementEditor(
                replacement: replacement,
                onSave: { edited in
                    if model.replacements.update(edited) {
                        replacementPendingEdit = nil
                        failure = nil
                        return nil
                    }
                    return model.replacements.lastPersistenceError
                        ?? "The replacement edit was not saved."
                },
                onCancel: { replacementPendingEdit = nil }
            )
        }
        .confirmationDialog(
            "Delete this replacement?",
            isPresented: Binding(
                get: { replacementPendingDeletion != nil },
                set: { if !$0 { replacementPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let replacement = replacementPendingDeletion {
                Button("Delete Replacement", role: .destructive) {
                    if model.replacements.remove(replacement.id) {
                        failure = nil
                        replacementPendingDeletion = nil
                    } else {
                        failure = model.replacements.lastPersistenceError.map {
                            "The replacement was not deleted: \($0)"
                        } ?? "The replacement was not deleted."
                    }
                }
            }
            Button("Cancel", role: .cancel) { replacementPendingDeletion = nil }
        } message: {
            Text("Future transcripts will no longer replace this heard phrase automatically.")
        }
    }
}

private struct MacReplacementEditor: View {
    let replacement: MacTextReplacement
    /// Returns nil once the edit is durable; a message keeps the sheet open
    /// with both drafts intact.
    let onSave: (MacTextReplacement) -> String?
    let onCancel: () -> Void

    @State private var spoken: String
    @State private var written: String
    @State private var validationMessage: String?

    init(
        replacement: MacTextReplacement,
        onSave: @escaping (MacTextReplacement) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.replacement = replacement
        self.onSave = onSave
        self.onCancel = onCancel
        _spoken = State(initialValue: replacement.spoken)
        _written = State(initialValue: replacement.written)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Replacement")
                .font(.headline)

            HStack {
                TextField("Heard as", text: $spoken)
                    .accessibilityLabel("Heard as")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Written as", text: $written)
                    .accessibilityLabel("Written as")
            }

            Text("The heard phrase matches case-insensitively. Leading and trailing whitespace is trimmed when the rule is saved; an empty written form deletes the phrase from transcripts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        var edited = replacement
        edited.spoken = spoken
        edited.written = written
        validationMessage = onSave(edited)
    }
}

// MARK: - App rules

private extension MacDeliveryMethod {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .menuPaste: "Menu Paste"
        case .typeOut: "Type Out"
        case .clipboardOnly: "Clipboard Only"
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            "SpeakPaste picks the safest route that works: the app's Paste menu, then keystroke fallbacks."
        case .menuPaste:
            "Always uses the app's Edit → Paste menu item. Fails visibly instead of falling back."
        case .typeOut:
            "Types the text character by character. Slower, but works in apps that reject synthetic paste."
        case .clipboardOnly:
            "Only puts the text on the clipboard — SpeakPaste never touches this app. You paste by hand."
        }
    }
}

private struct MacAppRulesSettings: View {
    @EnvironmentObject private var model: MacAppModel
    @State private var editorState: MacDeliveryRuleEditorState?
    @State private var rulePendingDeletion: MacDeliveryPolicy?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Per-app exceptions to delivery and context. Apps without a rule follow the global paste setting, never press Return, and inherit the global Context Awareness setting.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.deliveryPolicies.policies.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No app rules yet")
                        .font(.callout.weight(.medium))
                    Text("Add one for an app where the automatic delivery is a poor fit — a chat app you want auto-sent, or a terminal that needs type-out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.deliveryPolicies.policies) { policy in
                    ruleRow(policy)
                }
                .listStyle(.bordered)
            }

            if let error = model.deliveryPolicies.lastPersistenceError {
                Label("Rules could not be saved: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Add Rule…") {
                    editorState = MacDeliveryRuleEditorState(policy: nil)
                }
            }
        }
        .padding(20)
        .sheet(item: $editorState) { state in
            MacDeliveryRuleEditor(
                existing: state.policy,
                onSave: { policy in
                    let saved = model.deliveryPolicies.upsert(policy)
                    if saved { editorState = nil }
                    return saved
                        ? nil
                        : model.deliveryPolicies.lastPersistenceError
                            ?? "The rule could not be written to disk."
                },
                onCancel: { editorState = nil }
            )
        }
        .confirmationDialog(
            "Delete this app rule?",
            isPresented: Binding(
                get: { rulePendingDeletion != nil },
                set: { if !$0 { rulePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let policy = rulePendingDeletion {
                Button("Delete Rule", role: .destructive) {
                    let removed = model.deliveryPolicies.removePolicy(for: policy.bundleIdentifier)
                    if removed { rulePendingDeletion = nil }
                }
            }
            Button("Cancel", role: .cancel) { rulePendingDeletion = nil }
        } message: {
            Text("Delivery for this app will return to the global defaults.")
        }
    }

    private func ruleRow(_ policy: MacDeliveryPolicy) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(policy.applicationName ?? policy.bundleIdentifier)
                    .font(.callout.weight(.medium))
                if policy.applicationName != nil {
                    Text(policy.bundleIdentifier)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    ruleBadge(policy.deliveryMethod.title, tint: .secondary)
                    if policy.typeOutFallback {
                        ruleBadge("Type-out fallback", tint: .secondary)
                    }
                    if policy.contextKeyterms {
                        ruleBadge("Context on", tint: .blue)
                    }
                    if policy.autoSend {
                        ruleBadge("Auto-send ⏎", tint: .red)
                    }
                }
            }
            Spacer()
            Button("Edit") {
                editorState = MacDeliveryRuleEditorState(policy: policy)
            }
            .controlSize(.small)
            Button {
                rulePendingDeletion = policy
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete the rule for \(policy.applicationName ?? policy.bundleIdentifier)")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit rule") {
            editorState = MacDeliveryRuleEditorState(policy: policy)
        }
        .accessibilityAction(named: "Delete rule") {
            rulePendingDeletion = policy
        }
    }

    private func ruleBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// Sheet identity wrapper: `nil` policy means "create a new rule".
private struct MacDeliveryRuleEditorState: Identifiable {
    let policy: MacDeliveryPolicy?

    var id: String { policy?.bundleIdentifier ?? "new-rule" }
}

private struct MacDeliveryRuleEditor: View {
    let existing: MacDeliveryPolicy?
    /// Returns nil only after the rule has been committed to disk. Returning a
    /// message leaves the sheet open with every edited value intact.
    let onSave: (MacDeliveryPolicy) -> String?
    let onCancel: () -> Void

    @State private var bundleIdentifier: String
    @State private var applicationName: String
    @State private var deliveryMethod: MacDeliveryMethod
    @State private var typeOutFallback: Bool
    @State private var autoSend: Bool
    @State private var contextKeyterms: Bool
    /// Consent is bound to the final bundle identifier, not merely to this
    /// editor session. Editing the target app invalidates it immediately.
    @State private var confirmedAutoSendBundleIdentifier: String?
    @State private var confirmingAutoSend = false
    @State private var validationMessage: String?
    @State private var runningApps: [MacRunningAppChoice] = []

    init(
        existing: MacDeliveryPolicy?,
        onSave: @escaping (MacDeliveryPolicy) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.existing = existing
        self.onSave = onSave
        self.onCancel = onCancel
        _bundleIdentifier = State(initialValue: existing?.bundleIdentifier ?? "")
        _applicationName = State(initialValue: existing?.applicationName ?? "")
        _deliveryMethod = State(initialValue: existing?.deliveryMethod ?? .automatic)
        _typeOutFallback = State(initialValue: existing?.typeOutFallback ?? false)
        _autoSend = State(initialValue: existing?.autoSend ?? false)
        _contextKeyterms = State(initialValue: existing?.contextKeyterms ?? false)
        _confirmedAutoSendBundleIdentifier = State(
            initialValue: existing?.autoSend == true
                ? Self.normalizedBundleIdentifier(existing?.bundleIdentifier ?? "")
                : nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "New App Rule" : "Edit App Rule")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider()

            Form {
                Section("Application") {
                    if existing == nil {
                        Picker("Running app", selection: pickerSelection) {
                            Text("Choose…").tag("")
                            ForEach(runningApps) { app in
                                Text(app.name).tag(app.bundleIdentifier)
                            }
                        }
                        .accessibilityHint("Fills in the bundle identifier from an app that is open right now.")
                        TextField("Bundle identifier", text: $bundleIdentifier, prompt: Text("com.example.app"))
                            .autocorrectionDisabled()
                        TextField("Display name (optional)", text: $applicationName)
                    } else {
                        LabeledContent("App", value: applicationName.isEmpty ? bundleIdentifier : applicationName)
                        LabeledContent("Bundle identifier", value: bundleIdentifier)
                    }
                }

                Section("Delivery") {
                    Picker("Method", selection: $deliveryMethod) {
                        ForEach(MacDeliveryMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    Text(deliveryMethod.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Fall back to typing the text out", isOn: $typeOutFallback)
                        .disabled(deliveryMethod == .clipboardOnly || deliveryMethod == .typeOut)

                    Toggle("Press Return after inserting (auto-send)", isOn: $autoSend)
                        .disabled(deliveryMethod == .clipboardOnly || normalizedBundleIdentifier.isEmpty)
                        .onChange(of: autoSend) { _, enabled in
                            guard enabled else { return }
                            guard confirmedAutoSendBundleIdentifier != normalizedBundleIdentifier else {
                                return
                            }
                            autoSend = false
                            confirmingAutoSend = true
                        }
                    if deliveryMethod == .clipboardOnly {
                        Text("Clipboard Only never inserts text, so there is nothing to type out or send.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if autoSend {
                        Label(
                            "SpeakPaste will press Return in this app after every dictation. In chat apps that sends the message immediately.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }

                Section("Context") {
                    Toggle("Send context terms as spelling hints", isOn: $contextKeyterms)
                    Text("Extracts candidate names and code identifiers from a small caret-local text window, the selection, window title, and app name. When hints are found, they are sent as ElevenLabs keyterms and use keyterm pricing. This app rule overrides the global setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Rule") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 560)
        .onAppear { loadRunningApps() }
        .onChange(of: bundleIdentifier) { _, _ in
            guard confirmedAutoSendBundleIdentifier != normalizedBundleIdentifier else { return }
            confirmedAutoSendBundleIdentifier = nil
            autoSend = false
        }
        .onChange(of: deliveryMethod) { _, method in
            switch method {
            case .clipboardOnly:
                typeOutFallback = false
                autoSend = false
                confirmedAutoSendBundleIdentifier = nil
            case .typeOut:
                typeOutFallback = false
            case .automatic, .menuPaste:
                break
            }
        }
        .alert("Press Return automatically?", isPresented: $confirmingAutoSend) {
            Button("Enable Auto-Send", role: .destructive) {
                guard !normalizedBundleIdentifier.isEmpty,
                      deliveryMethod != .clipboardOnly else { return }
                confirmedAutoSendBundleIdentifier = normalizedBundleIdentifier
                autoSend = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("After inserting a dictation into \(displayNameForWarning), SpeakPaste will press the Return key there. In most chat apps that sends the message immediately — before you can review it — and SpeakPaste cannot un-send it. Enable only if that is exactly what you want.")
        }
    }

    private var displayNameForWarning: String {
        let name = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let bundle = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return bundle.isEmpty ? "this app" : bundle
    }

    private var normalizedBundleIdentifier: String {
        Self.normalizedBundleIdentifier(bundleIdentifier)
    }

    private static func normalizedBundleIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The picker mirrors the bundle-identifier field: choosing a running app
    /// fills the field, and hand-editing the field simply deselects the picker.
    private var pickerSelection: Binding<String> {
        Binding(
            get: {
                runningApps.contains { $0.bundleIdentifier == bundleIdentifier } ? bundleIdentifier : ""
            },
            set: { chosen in
                guard !chosen.isEmpty,
                      let app = runningApps.first(where: { $0.bundleIdentifier == chosen }) else { return }
                bundleIdentifier = app.bundleIdentifier
                applicationName = app.name
            }
        )
    }

    private func loadRunningApps() {
        let choices = NSWorkspace.shared.runningApplications
            .compactMap { app -> MacRunningAppChoice? in
                guard
                    app.activationPolicy == .regular,
                    let bundleIdentifier = app.bundleIdentifier,
                    bundleIdentifier != Bundle.main.bundleIdentifier
                else {
                    return nil
                }
                return MacRunningAppChoice(
                    bundleIdentifier: bundleIdentifier,
                    name: app.localizedName ?? bundleIdentifier
                )
            }
        let uniqueChoices = Dictionary(
            choices.map { ($0.bundleIdentifier.lowercased(), $0) },
            uniquingKeysWith: { current, candidate in
                current.name.localizedStandardCompare(candidate.name) == .orderedAscending
                    ? current
                    : candidate
            }
        )
        runningApps = uniqueChoices.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func save() {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            validationMessage = "A bundle identifier is required."
            return
        }
        if autoSend, confirmedAutoSendBundleIdentifier != normalizedBundleIdentifier {
            validationMessage = "Confirm auto-send for this exact application before saving."
            return
        }
        let savedTypeOutFallback = deliveryMethod == .automatic || deliveryMethod == .menuPaste
            ? typeOutFallback
            : false
        let savedAutoSend = deliveryMethod == .clipboardOnly ? false : autoSend
        let policy = MacDeliveryPolicy(
            bundleIdentifier: trimmed,
            applicationName: applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : applicationName.trimmingCharacters(in: .whitespacesAndNewlines),
            deliveryMethod: deliveryMethod,
            typeOutFallback: savedTypeOutFallback,
            autoSend: savedAutoSend,
            contextKeyterms: contextKeyterms
        )
        if let persistenceFailure = onSave(policy) {
            validationMessage = "The rule was not saved: \(persistenceFailure)"
            return
        }
        validationMessage = nil
    }
}

private struct MacRunningAppChoice: Identifiable {
    let bundleIdentifier: String
    let name: String

    var id: String { bundleIdentifier }
}

// MARK: - History

private struct MacHistorySettings: View {
    @EnvironmentObject private var model: MacAppModel
    @State private var query = ""
    @State private var confirmingPurge = false
    @State private var recordPendingDeletion: MacTranscriptRecord?
    @State private var recordPendingEdit: MacTranscriptRecord?

    private var records: [MacTranscriptRecord] {
        query.isEmpty ? model.history.records : model.history.search(query)
    }

    private var audioRetentionCaption: String {
        if model.history.retentionDays == -1 {
            return "Never store keeps no completed History transcripts or successful recordings. A temporary private text-delivery escrow remains only while output is unresolved, then is removed."
        }
        return "Keeps private local recordings for playback and Process Again, up to 1 GiB total while reserving at least 2 GiB of free disk space. When either limit is reached, the transcript is still saved without its audio. Turning this off deletes retained copies. Under every History setting, unresolved output also stays in a temporary private text-delivery escrow until copied, pasted, or discarded."
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
                        set: { model.setHistoryRetentionDays($0) }
                    )
                ) {
                    Text("Never store").tag(-1)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                .frame(width: 190)
                .accessibilityLabel("How long transcripts are kept")
                .disabled(!model.reprocessingHistoryRecordIDs.isEmpty)
            }

            Toggle(
                "Keep original audio for playback and reprocessing",
                isOn: Binding(
                    get: { model.keepsSuccessfulHistoryAudio },
                    set: { model.retainSuccessfulAudio = $0 }
                )
            )
            .disabled(
                model.history.retentionDays == -1
                    || !model.reprocessingHistoryRecordIDs.isEmpty
            )
            Text(audioRetentionCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
                            model.copyText(
                                record.text,
                                resolvingPendingID: record.id
                            )
                        }
                        .buttonStyle(.borderless)
                        if model.hasRetainedAudio(for: record) {
                            Button(model.playingHistoryRecordID == record.id ? "Stop" : "Play") {
                                model.toggleHistoryAudioPlayback(record)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(
                                model.playingHistoryRecordID == record.id
                                    ? "Stop playing the original recording"
                                    : "Play the original recording of this transcript"
                            )
                            if model.reprocessingHistoryRecordIDs.contains(record.id) {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .controlSize(.mini)
                                    Text("Processing…")
                                    Button("Cancel") {
                                        model.cancelHistoryReprocessing(record.id)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("Processing this recording again. Cancel available.")
                            } else {
                                Button("Process Again") {
                                    model.reprocessHistoryRecord(record)
                                }
                                .buttonStyle(.borderless)
                                .disabled(!model.historyRecordCanBeModified(record))
                                .help("Transcribes the saved recording again with the current language, vocabulary, and replacement settings, then updates this transcript. Nothing is pasted anywhere.")
                                .accessibilityLabel("Process the original recording again. Updates this saved transcript only; nothing is pasted.")
                            }
                        }
                        Button("Edit") {
                            if model.historyRecordCanBeModified(record) {
                                recordPendingEdit = record
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(
                            model.reprocessingHistoryRecordIDs.contains(record.id)
                                || !model.historyRecordCanBeModified(record)
                        )
                        Button {
                            recordPendingDeletion = record
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete this transcript")
                        .disabled(model.reprocessingHistoryRecordIDs.contains(record.id))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: "Copy transcript") {
                    model.copyText(
                        record.text,
                        resolvingPendingID: record.id
                    )
                }
                .accessibilityAction(named: "Edit transcript") {
                    if model.historyRecordCanBeModified(record) {
                        recordPendingEdit = record
                    }
                }
                .accessibilityAction(named: "Delete transcript") {
                    recordPendingDeletion = record
                }
            }
            .listStyle(.bordered)
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No Transcripts Yet" : "No Matching Transcripts",
                        systemImage: query.isEmpty ? "text.bubble" : "magnifyingglass",
                        description: Text(
                            query.isEmpty
                                ? "Finished dictations appear here according to your retention setting."
                                : "Try a different search."
                        )
                    )
                }
            }
            .confirmationDialog(
                "Delete this saved transcript?",
                isPresented: Binding(
                    get: { recordPendingDeletion != nil },
                    set: { if !$0 { recordPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let record = recordPendingDeletion {
                    Button("Delete Transcript", role: .destructive) {
                        if model.deleteHistoryRecord(record.id) {
                            recordPendingDeletion = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) { recordPendingDeletion = nil }
            } message: {
                Text("This removes the transcript from local history and cannot be undone.")
            }

            if let error = model.historyActionError ?? model.history.lastPersistenceError {
                Label("History storage error: \(error)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("History storage error: \(error)")
            }

            HStack {
                Text("\(model.history.records.count) transcript\(model.history.records.count == 1 ? "" : "s") on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete All…", role: .destructive) { confirmingPurge = true }
                    .disabled(
                        model.history.records.isEmpty
                            || !model.reprocessingHistoryRecordIDs.isEmpty
                    )
            }
        }
        .padding(20)
        .sheet(item: $recordPendingEdit) { record in
            MacHistoryRecordEditor(
                record: record,
                onSave: { editedText in
                    if model.updateHistoryRecordText(record.id, to: editedText) {
                        recordPendingEdit = nil
                        return nil
                    }
                    return model.historyActionError
                        ?? model.history.lastPersistenceError
                        ?? "The edited transcript could not be written to disk."
                },
                onCancel: { recordPendingEdit = nil }
            )
        }
        .confirmationDialog(
            "Delete every saved transcript?",
            isPresented: $confirmingPurge,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                if model.deleteAllHistory() {
                    confirmingPurge = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This erases every saved transcript from local history on disk. It cannot be undone.")
        }
    }
}

private struct MacHistoryRecordEditor: View {
    let record: MacTranscriptRecord
    let onSave: (String) -> String?
    let onCancel: () -> Void

    @State private var draft: String
    @State private var validationMessage: String?

    init(
        record: MacTranscriptRecord,
        onSave: @escaping (String) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.record = record
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: record.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Transcript")
                .font(.headline)

            TextEditor(text: $draft)
                .font(.body)
                .frame(minWidth: 460, minHeight: 180)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                )
                .accessibilityLabel("Transcript text")

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        validationMessage = "A saved transcript cannot be empty. Delete it from History instead."
                        return
                    }
                    validationMessage = onSave(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

// MARK: - Permissions & privacy

private struct MacPermissionSettings: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("SpeakPaste checks these live. macOS can revoke any of them at any time, and a revoked grant is otherwise invisible — the shortcut simply stops working.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(MacPermission.allCases) { permission in
                    permissionRow(permission)
                }

                if model.permissions.isSecureInputEnabled {
                    Label(
                        "A secure input field (usually a password box) is active somewhere. macOS blocks synthetic paste while it is; dictations are held safely until it goes away.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if !model.isShortcutGlobal {
                    Text("The \(model.hotKeyLabel) shortcut currently works only while SpeakPaste is the frontmost app. Grant Accessibility to use it from anywhere.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Local History data")
                        .fontWeight(.medium)
                    Text("By default, successful transcripts and their original recordings stay private in this Mac's Application Support so History can play or process them again. History controls the retention window, offers Never store, and can disable or purge retained audio at any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Diagnostics")
                                .fontWeight(.medium)
                            Text("A privacy-safe snapshot for bug reports: app and macOS versions, permission status, microphone transport category and gain, attempt timings, and queue counts. It never includes device names, transcripts, audio, clipboard contents, on-screen text, or credentials.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button("Save Diagnostics…") { saveDiagnostics() }
                    }
                    if let notice = model.diagnosticsExportNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .onAppear { model.permissions.refresh() }
    }

    private func permissionRow(_ permission: MacPermission) -> some View {
        let isGranted = model.permissions.granted[permission] ?? false
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .orange)
                .accessibilityHidden(true)
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
        .accessibilityElement(children: .contain)
    }

    private func saveDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "SpeakPaste-Diagnostics.json"
        panel.message = "Transcripts, audio, clipboard contents, and credentials are never included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportDiagnostics(to: url)
    }
}
