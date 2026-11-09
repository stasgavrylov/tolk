import SwiftUI
import TolkCore

struct SuggestionsView: View {
    let translator: TranslatorModel
    let onPick: (PhraseSuggestion) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch translator.suggestions {
            case .idle:
                EmptyView()
            case .loading(let pane, let selection):
                header(pane: pane, selection: selection)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding alternatives…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            case .failed(let pane, let selection, let message):
                header(pane: pane, selection: selection)
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            case .loaded(let pane, let selection, let items):
                header(pane: pane, selection: selection)
                if items.isEmpty {
                    Text("No alternatives found.").foregroundStyle(.secondary)
                } else {
                    // Refresh replaces a fixed slot; wording must not be the row's identity.
                    ForEach(items.indices, id: \.self) { index in
                        SuggestionRow(item: items[index], index: index,
                                      refreshState: translator.suggestionRefreshStates[index],
                                      onRefresh: pane == .translation ? { translator.refreshSuggestion(at: index) } : nil,
                                      action: { onPick(items[index]) })
                    }
                    Text(pane == .translation ? "Click to replace · the sentence is adjusted to fit" : "Click to copy")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
    }

    private func header(pane: Pane, selection: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(pane == .translation ? "Alternatives" : "How a native speaker would say it")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            Text(selection).font(.headline).lineLimit(2)
        }
    }
}

private struct SuggestionRow: View {
    let item: PhraseSuggestion
    let index: Int
    let refreshState: SuggestionRefreshState?
    let onRefresh: (() -> Void)?
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focusedControl: Control?
    private enum Control: Hashable { case pick, refresh }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
                    if !item.note.isEmpty { Text(item.note).font(.callout).foregroundStyle(.secondary) }
                    if !item.back.isEmpty { Text("≈ \(item.back)").font(.caption).foregroundStyle(.tertiary).italic() }
                    if case .failed(let message) = refreshState {
                        Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6).padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .pick)
            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
            .accessibilityIdentifier("suggestion-\(index)")

            if let onRefresh {
                // Sibling buttons keep refreshing separate from picking. Only the visual is tiny.
                Button(action: onRefresh) {
                    Group {
                        if refreshState == .loading {
                            ProgressView().controlSize(.mini).scaleEffect(0.55)
                        } else {
                            Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .medium))
                        }
                    }
                    .frame(width: 12, height: 12)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(refreshState == .loading ? 0 : 0.10)))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedControl, equals: .refresh)
                .disabled(refreshState == .loading)
                .help("Another like this")
                .accessibilityLabel("Another like this")
                .accessibilityValue(refreshState == .loading ? "Refreshing" : "")
                .accessibilityIdentifier("suggestion-refresh-\(index)")
                .opacity(hovering || focusedControl != nil || refreshState != nil ? 1 : 0)
                .accessibilityHidden(false)
                .padding(.top, 3).padding(.trailing, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(hovering || focusedControl != nil ? Color.accentColor.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
