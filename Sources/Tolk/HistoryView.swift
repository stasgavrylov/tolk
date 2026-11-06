import SwiftUI
import TolkCore

struct HistoryView: View {
    @Bindable var app: AppState
    @State private var query = ""
    @State private var starredOnly = false
    @State private var confirmClear = false
    @State private var entries: [HistoryEntry] = []
    @State private var loadError: String?
    @State private var actionError: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Button { app.showHistory = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close history")
                    .accessibilityLabel("Close history").accessibilityIdentifier("closeHistory")
            }
            HStack {
                TextField("Search history", text: $query).textFieldStyle(.roundedBorder)
                    .focused($searchFocused).accessibilityIdentifier("historySearch")
                Toggle(isOn: $starredOnly) { Image(systemName: starredOnly ? "star.fill" : "star") }
                    .toggleStyle(.button).help("Starred only")
                    .accessibilityLabel("Show starred translations only")
            }
            if let message = app.historyError ?? loadError ?? actionError {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("historyError")
            }
            if app.settings.historyPaused {
                Label("History is paused", systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
            }
            if loadError != nil {
                Spacer()
            } else if entries.isEmpty {
                Spacer()
                Text(query.isEmpty ? (starredOnly ? "No starred translations" : "No translations yet") : "No matches")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(entries) { entry in
                    HistoryRow(entry: entry, onRestore: { app.restore(entry) },
                               onStar: { perform { try app.history?.toggleStar(entry) } },
                               onDelete: { perform { try app.history?.delete(entry) } })
                }
                .listStyle(.inset).accessibilityIdentifier("historyList")
            }
            HStack {
                Toggle("Pause history", isOn: Binding(get: { app.settings.historyPaused }, set: { app.settings.historyPaused = $0 }))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Clear…", role: .destructive) { confirmClear = true }
                    .disabled(entries.isEmpty || loadError != nil)
            }
            .font(.caption)
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Translation history")
        .accessibilityIdentifier("historyPanel")
        .onAppear { reload(); searchFocused = true }
        .onChange(of: query) { reload() }
        .onChange(of: starredOnly) { reload() }
        .onChange(of: app.historyRevision) { reload() }
        .onExitCommand { app.showHistory = false }
        .confirmationDialog("Clear history?", isPresented: $confirmClear) {
            Button("Clear all except starred", role: .destructive) { perform { try app.history?.clearAll(keepStarred: true) } }
            Button("Clear everything", role: .destructive) { perform { try app.history?.clearAll() } }
        }
    }

    private func reload() {
        guard let store = app.history else {
            entries = []
            loadError = app.historyError ?? "History isn’t available."
            return
        }
        do {
            entries = try store.entries(matching: query, starredOnly: starredOnly)
            loadError = nil
        } catch {
            entries = []
            loadError = "Couldn’t load history: \(error.localizedDescription)"
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); actionError = nil } catch { actionError = error.localizedDescription }
        app.historyChanged()
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onRestore: () -> Void
    let onStar: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onRestore) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(entry.sourceLanguage.isEmpty ? "AUTO" : entry.sourceLanguage.uppercased()) → \(entry.targetLanguage.uppercased())")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(entry.sourceText).lineLimit(2)
                    Text(entry.translation).lineLimit(2).foregroundStyle(.secondary)
                    Text(entry.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Restore translation: \(entry.sourceText)")
            Button(action: onStar) { Image(systemName: entry.starred ? "star.fill" : "star") }
                .buttonStyle(.borderless).foregroundStyle(entry.starred ? Color.accentColor : .secondary)
                .accessibilityLabel(entry.starred ? "Unstar translation" : "Star translation")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Restore", action: onRestore)
            Button(entry.starred ? "Unstar" : "Star", action: onStar)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
