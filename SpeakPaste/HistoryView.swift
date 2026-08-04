import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HistoryList(model: model, history: model.history)
    }
}

private struct HistoryList: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: HistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirmation = false
    @State private var searchText = ""
    @State private var path: [UUID] = []

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredItems: [TranscriptItem] {
        guard !trimmedQuery.isEmpty else { return history.items }
        return history.items.filter { item in
            item.text.localizedCaseInsensitiveContains(trimmedQuery)
                || (item.languageCode?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
                || item.languageCode.flatMap(TranscriptionLanguage.title(forAPICode:))?
                    .localizedCaseInsensitiveContains(trimmedQuery) == true
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if history.items.isEmpty {
                    ContentUnavailableView {
                        Label("No Transcripts Yet", systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(Theme.ink)
                    } description: {
                        Text("Finished dictations are saved here, on this device only.")
                            .foregroundStyle(Theme.inkMuted)
                    }
                } else {
                    List {
                        ForEach(filteredItems) { item in
                            row(item)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .overlay {
                        if filteredItems.isEmpty {
                            ContentUnavailableView.search(text: trimmedQuery)
                        }
                    }
                    .searchable(
                        text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search transcripts"
                    )
                }
            }
            .background(Theme.background)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { itemID in
                if let item = history.items.first(where: { $0.id == itemID }) {
                    TranscriptEditorView(model: model, history: history, item: item)
                } else {
                    ContentUnavailableView(
                        "Transcript Unavailable",
                        systemImage: "doc.badge.ellipsis",
                        description: Text("This transcript is no longer in history.")
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !history.items.isEmpty {
                        Button("Clear All", role: .destructive) {
                            showClearConfirmation = true
                        }
                        .foregroundStyle(Theme.danger)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Delete all transcripts?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) {
                    model.clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every saved transcript from this device.")
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .onAppear { history.reload() }
    }

    private func row(_ item: TranscriptItem) -> some View {
        NavigationLink(value: item.id) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(item.createdAt, format: .relative(presentation: .named))
                    Text("·")
                    Text(Theme.timeString(item.duration))
                    if let code = item.languageCode, !code.isEmpty {
                        Text("·")
                        Text(code.uppercased())
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.inkMuted)
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Theme.surface)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                model.deleteHistoryItem(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                copy(item)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(Theme.accentDeep)
        }
        .contextMenu {
            Button {
                path.append(item.id)
            } label: {
                Label("Edit Transcript", systemImage: "square.and.pencil")
            }
            Button {
                copy(item)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                model.useHistoryItem(item)
            } label: {
                Label("Insert on Main Screen", systemImage: "text.insert")
            }
            Button(role: .destructive) {
                model.deleteHistoryItem(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityHint("Opens this transcript in the editor. Swipe for copy and delete.")
    }

    private func copy(_ item: TranscriptItem) {
        model.copyHistoryItem(item)
    }
}

/// Full-screen editor for a saved transcript. Edits only persist through Save;
/// leaving with unsaved changes always asks first, so nothing is lost silently.
private struct TranscriptEditorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: HistoryStore
    let item: TranscriptItem

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditing: Bool
    @State private var editedText: String
    @State private var showDeleteConfirmation = false
    @State private var showUnsavedChangesDialog = false
    @State private var showSaveFailedAlert = false

    init(model: AppModel, history: HistoryStore, item: TranscriptItem) {
        self.model = model
        self.history = history
        self.item = item
        _editedText = State(initialValue: item.text)
    }

    private var savedItem: TranscriptItem {
        history.items.first { $0.id == item.id } ?? item
    }

    private var hasUnsavedChanges: Bool {
        editedText != savedItem.text
    }

    private var trimmedText: String {
        editedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        hasUnsavedChanges && !trimmedText.isEmpty
    }

    private var languageName: String? {
        guard let code = savedItem.languageCode, !code.isEmpty else { return nil }
        return TranscriptionLanguage.title(forAPICode: code) ?? code.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(1)
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                Text("\(editedText.count) characters")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Theme.inkMuted)
                    .accessibilityHidden(true)
            }

            TextEditor(text: $editedText)
                .focused($isEditing)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 20).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.stroke))
                .accessibilityLabel("Transcript text, editable")

            HStack(spacing: 6) {
                Text(savedItem.createdAt, format: .dateTime.month().day().hour().minute())
                Text("·")
                Text(Theme.timeString(savedItem.duration))
                if let languageName {
                    Text("·")
                    Text(languageName)
                }
            }
            .font(.footnote)
            .foregroundStyle(Theme.inkMuted)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Recorded \(savedItem.createdAt.formatted(date: .abbreviated, time: .shortened)), \(Theme.timeString(savedItem.duration)) long\(languageName.map { ", in \($0)" } ?? "")"
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Edit Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar {
            if hasUnsavedChanges {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showUnsavedChangesDialog = true
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveAndDismiss()
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    copyCurrentText()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(trimmedText.isEmpty)
                .accessibilityHint("Puts the transcript on the clipboard.")
                Spacer()
                ShareLink(item: editedText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(trimmedText.isEmpty)
                .accessibilityLabel("Share transcript")
                Spacer()
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                        .foregroundStyle(Theme.danger)
                }
                .accessibilityHint("Deletes this transcript after confirmation.")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditing = false }
                    .fontWeight(.semibold)
            }
        }
        .confirmationDialog(
            "Save changes to this transcript?",
            isPresented: $showUnsavedChangesDialog,
            titleVisibility: .visible
        ) {
            if canSave {
                Button("Save Changes") {
                    saveAndDismiss()
                }
            }
            Button("Discard Changes", role: .destructive) {
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your edits haven't been saved yet.")
        }
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Transcript", role: .destructive) {
                model.deleteHistoryItem(savedItem)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the transcript from this device.")
        }
        .alert("Couldn't Save Changes", isPresented: $showSaveFailedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This transcript is no longer in history, so the edit couldn't be saved.")
        }
        .interactiveDismissDisabled(hasUnsavedChanges)
    }

    private func saveAndDismiss() {
        isEditing = false
        if history.updateText(id: item.id, text: editedText) != nil {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } else {
            showSaveFailedAlert = true
        }
    }

    private func copyCurrentText() {
        if hasUnsavedChanges {
            UIPasteboard.general.string = editedText
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            // The model path also acknowledges pending keyboard deliveries.
            model.copyHistoryItem(savedItem)
        }
    }
}
