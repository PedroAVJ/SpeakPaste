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

    var body: some View {
        NavigationStack {
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
                        ForEach(history.items) { item in
                            row(item)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
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
        Button {
            model.useHistoryItem(item)
        } label: {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                copy(item)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                model.useHistoryItem(item)
            } label: {
                Label("Open in Editor", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                model.deleteHistoryItem(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityHint("Double tap to open this transcript in the editor. Swipe for copy and delete.")
    }

    private func copy(_ item: TranscriptItem) {
        model.copyHistoryItem(item)
    }
}
