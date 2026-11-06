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
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SuggestionRow(item: item, index: index, pane: pane) { onPick(item) }
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
    let pane: Pane
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary)
                if !item.note.isEmpty { Text(item.note).font(.callout).foregroundStyle(.secondary) }
                if !item.back.isEmpty { Text("≈ \(item.back)").font(.caption).foregroundStyle(.tertiary).italic() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.accentColor.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
        .accessibilityIdentifier("suggestion-\(index)")
    }
}
