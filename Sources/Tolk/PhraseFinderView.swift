import SwiftUI
import TolkCore

struct PhraseFinderView: View {
    @Bindable var app: AppState
    let registry: PaneRegistry
    let openSettings: () -> Void
    @State private var copiedText: String?
    @State private var copyFeedback: String?

    private var finder: PhraseFinderModel { app.finder }
    private var enabled: Bool { app.screen == .phraseFinder }

    var body: some View {
        VStack(spacing: 0) {
            composer
            Divider()
            results.frame(maxWidth: .infinity, maxHeight: .infinity).background(EditorPalette.result)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: copyFeedback) {
            guard copyFeedback != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copyFeedback = nil
            copiedText = nil
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What would you like to say?").font(.system(size: 13, weight: .semibold))
            PaneEditor(pane: .source, text: finder.query, interactionEnabled: enabled, undoManager: finder.undoManager,
                       placeholder: "Describe a word, a feeling, or a situation…", fontSize: 17,
                       textInset: NSSize(width: 8, height: 9), accessibilityLabel: "What would you like to say?",
                       accessibilityIdentifier: "phraseDescription", registry: registry, onChange: { finder.query = $0 })
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
            HStack(spacing: 10) {
                Text("Find phrases in").font(.system(size: 12)).foregroundStyle(.secondary)
                Menu {
                    Picker("Phrase language", selection: Binding(get: { finder.targetLanguage }, set: { finder.targetLanguage = $0 })) {
                        ForEach(app.settings.enabledLanguages) { Text($0.name).tag($0.code) }
                    }.pickerStyle(.inline)
                } label: { Text(app.settings.language(finder.targetLanguage).name) }
                .accessibilityLabel("Phrase language: \(app.settings.language(finder.targetLanguage).name)")
                .accessibilityIdentifier("phraseTarget")
                Menu {
                    Picker("Phrase tone", selection: Binding(get: { finder.tone }, set: { finder.tone = $0 })) {
                        ForEach(Tone.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.inline)
                } label: { Text("\(finder.tone.title) tone").foregroundStyle(.secondary) }
                .accessibilityLabel("Phrase tone: \(finder.tone.title)")
                .accessibilityIdentifier("phraseTone")
                Spacer(minLength: 0)
                if let shortcut = app.settings.bindings[.translate] {
                    Text(shortcut.displayString).font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                Button(searchTitle) {
                    if app.primaryActionRequiresSignIn { openSettings() }
                    else { app.performPrimaryAction() }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!finder.canSearch && !finder.isSearching)
                .accessibilityIdentifier("phraseSearch")
            }
            .menuStyle(.borderlessButton).font(.system(size: 13))
            HStack(spacing: 7) {
                if finder.isSearching { ProgressView().controlSize(.small) }
                Text(copyFeedback ?? status)
                    .font(.system(size: 12)).foregroundStyle(finder.failure == nil ? Color.secondary : Color.red)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .help(finder.failure?.message ?? "")
                    .accessibilityIdentifier("phraseStatus")
            }
            .frame(minHeight: 17, alignment: .leading)
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
    }

    private var results: some View {
        VStack(spacing: 0) {
            if let result = finder.result {
                HStack {
                    Text(finder.resultIsCurrent ? "Suggestions" : "Previous suggestions").fontWeight(.semibold)
                    Spacer()
                    Text("\(result.items.count) expressions · \(app.settings.language(result.targetLanguage).name)")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12)).padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 6)
                if result.items.isEmpty {
                    emptyMessage("No fitting expressions", detail: "Try adding what you mean or who you’re speaking to.")
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(result.items.enumerated()), id: \.element.id) { index, phrase in
                                if index > 0 { Divider() }
                                phraseRow(phrase, index: index)
                            }
                        }.padding(.horizontal, 22)
                    }
                    .accessibilityIdentifier("phraseResults")
                }
            } else if finder.isSearching {
                emptyMessage("Finding expressions…", detail: "Your options will appear here.")
            } else if finder.failure != nil {
                emptyMessage("Your description is still here", detail: "Use the action above to continue.")
            } else if finder.isStopped {
                emptyMessage("Search stopped", detail: "Edit your description or find again when you’re ready.")
            } else {
                VStack(spacing: 8) {
                    Text("What are you trying to express?").font(.system(size: 16, weight: .medium))
                    Text("Describe it in your own words, in any language. You don’t need to know the phrase already.")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                    HStack(spacing: 16) {
                        example("Happy for someone", query: "How do I say I’m very happy for someone?", id: "happy")
                        example("Wish someone a good meal", query: "How do I wish someone a good meal?", id: "meal")
                        example("Wish someone well", query: "How do I wish someone to get well?", id: "well")
                    }
                    .padding(.top, 7).font(.system(size: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(18)
            }
        }
    }

    private func phraseRow(_ phrase: PhraseSuggestion, index: Int) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(phrase.text).font(.system(size: 20, weight: .medium)).textSelection(.enabled)
                    .accessibilityIdentifier("phraseOption-\(index)")
                Text(phrase.note).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                let copied = app.copyPhrase(phrase)
                copiedText = copied ? phrase.text : nil
                copyFeedback = copied ? "Phrase copied" : "Clipboard unavailable. Select the phrase and use Copy."
            } label: {
                Label(copiedText == phrase.text ? "Copied" : "Copy", systemImage: copiedText == phrase.text ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless).font(.system(size: 12)).frame(minWidth: 68)
            .accessibilityLabel("Copy \(phrase.text)")
            .accessibilityIdentifier("phraseCopy-\(index)")
        }
        .padding(.vertical, 11)
    }

    private func emptyMessage(_ title: String, detail: String) -> some View {
        VStack(spacing: 7) {
            Text(title).font(.system(size: 16, weight: .medium))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func example(_ title: String, query: String, id: String) -> some View {
        Button(title) {
            guard let editor = registry.source else { return }
            editor.breakUndoCoalescing()
            editor.insertText(query, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            editor.breakUndoCoalescing()
            registry.focusEditor()
        }
        .buttonStyle(.borderless).accessibilityIdentifier("phraseExample-\(id)")
    }

    private var searchTitle: String {
        if finder.isSearching { return "Stop" }
        if let failure = finder.failure { return failure.requiresSignIn ? "Sign in" : "Retry" }
        return "Find phrases"
    }

    private var status: String {
        if finder.isSearching { return "Finding expressions…" }
        if let failure = finder.failure {
            return failure.requiresSignIn ? "Sign in to continue. Your description is still here."
                : "Couldn’t find expressions. Your description and previous suggestions are kept."
        }
        if finder.isStopped { return "Search stopped. Find again when you’re ready." }
        if finder.result != nil && !finder.resultIsCurrent { return "Description or preferences changed. Find again to update the suggestions." }
        return "Describe it in any language. The options will be in \(app.settings.language(finder.targetLanguage).name)."
    }
}
