import SwiftUI
import TolkCore

struct MainView: View {
    @Bindable var app: AppState
    let registry: PaneRegistry
    let finderRegistry: PaneRegistry
    let presenter: SuggestionPresenter
    let openSettings: () -> Void

    private var t: TranslatorModel { app.translator }
    private var settings: AppSettings { app.settings }
    private var busy: Bool { t.isTranslating || t.isSmoothing }

    var body: some View {
        // Keep both native editors mounted: recreating them would discard selection and typing undo.
        ZStack {
            translationScreen
                .disabled(app.screen != .translation)
                .opacity(app.screen == .translation ? 1 : 0)
                .allowsHitTesting(app.screen == .translation)
                .accessibilityHidden(app.screen != .translation)
            PhraseFinderView(app: app, registry: finderRegistry, openSettings: openSettings)
                .disabled(app.screen != .phraseFinder)
                .opacity(app.screen == .phraseFinder ? 1 : 0)
                .allowsHitTesting(app.screen == .phraseFinder)
                .accessibilityHidden(app.screen != .phraseFinder)
        }
        // NSWindow owns the minimum height; a content minimum would count the toolbar twice.
        .frame(minWidth: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(EditorPalette.accent)
        .onChange(of: app.showHistory) { _, visible in
            if !visible { registry.restoreEditorFocus() }
        }
        .onChange(of: app.screen) { _, screen in
            presenter.close()
            Task { @MainActor in
                await Task.yield()
                guard app.screen == screen else { return }
                (screen == .translation ? registry : finderRegistry).focusEditor()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ScreenSwitcher(selection: $app.screen).frame(width: 240, height: 28)
                    .accessibilityIdentifier("screenPicker")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                if case .signedIn = app.auth.status {} else {
                    Button("Sign in", action: openSettings)
                        .help("Sign in with ChatGPT").accessibilityLabel("Sign in with ChatGPT")
                }
            }
            if app.screen == .translation {
                ToolbarItem(placement: .primaryAction) { pairsMenu }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    Button { app.showHistory.toggle() } label: { Label("History", systemImage: "clock.arrow.circlepath") }
                        .labelStyle(.iconOnly)
                        .help("History (\(settings.bindings[.history]?.displayString ?? ""))")
                        .accessibilityIdentifier("historyToggle")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    private var translationScreen: some View {
        GeometryReader { geometry in
            let drawer = geometry.size.width < 900
            HStack(spacing: 0) {
                workspace(blocked: app.screen != .translation || (drawer && app.showHistory))
                if app.showHistory && !drawer { history }
            }
            .overlay(alignment: .trailing) {
                if app.showHistory && drawer {
                    ZStack(alignment: .trailing) {
                        Color.primary.opacity(0.06)
                            .onTapGesture { app.showHistory = false }
                            .accessibilityHidden(true)
                        history.shadow(color: .black.opacity(0.12), radius: 12, x: -4)
                    }
                }
            }
        }
    }

    private var history: some View {
        HistoryView(app: app)
            .frame(width: 278)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .leading) { Divider() }
    }

    private func workspace(blocked: Bool) -> some View {
        VStack(spacing: 0) {
            languageBar.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                sourcePane(enabled: !blocked)
                Divider()
                translationPane(enabled: !blocked)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            .padding(14)
        }
        .disabled(blocked)
        .allowsHitTesting(!blocked)
        .accessibilityHidden(blocked)
    }

    // MARK: Language controls

    private var languageBar: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Source language", selection: Binding(get: { t.sourceLanguage }, set: { t.sourceLanguage = $0 })) {
                    Text("Detect language").tag(String?.none)
                    ForEach(settings.enabledLanguages) { Text($0.name).tag(Optional($0.code)) }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 5) {
                    Text(sourceTitle).fontWeight(.semibold)
                    if t.sourceLanguage == nil, t.detected != nil { Text("detected").foregroundStyle(.secondary) }
                }
            }
            .accessibilityLabel("Source language: \(sourceTitle)")
            .accessibilityIdentifier("sourceLanguage")

            Button(action: t.swap) { Image(systemName: "arrow.left.arrow.right") }
                .buttonStyle(.borderless)
                .disabled(t.sourceText.isEmpty)
                .help("Swap languages (\(settings.bindings[.swap]?.displayString ?? ""))")
                .accessibilityLabel("Swap languages")
                .accessibilityIdentifier("swap")

            Menu {
                Picker("Target language", selection: Binding(get: { t.targetLanguage }, set: { t.targetLanguage = $0 })) {
                    ForEach(settings.enabledLanguages) { Text($0.name).tag($0.code) }
                }
                .pickerStyle(.inline)
            } label: { Text(settings.language(t.targetLanguage).name).fontWeight(.semibold) }
            .accessibilityLabel("Target language: \(settings.language(t.targetLanguage).name)")
            .accessibilityIdentifier("targetLanguage")

            Menu {
                Picker("Tone", selection: Binding(get: { t.tone }, set: { t.tone = $0 })) {
                    ForEach(Tone.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Text("\(t.tone.title) tone").foregroundStyle(.secondary) }
            .help("Formality of the translation, stored per target language")
            .accessibilityLabel("Translation tone: \(t.tone.title)")
            .accessibilityIdentifier("tone")
            Spacer(minLength: 0)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 13))
    }

    private var sourceTitle: String {
        if let code = t.sourceLanguage ?? t.detected?.code { return settings.language(code).name }
        return "Detect language"
    }

    private var pairsMenu: some View {
        Menu {
            ForEach(Array(settings.quickPairs.prefix(9).enumerated()), id: \.offset) { index, pair in
                Toggle(isOn: Binding(get: { t.sourceLanguage == pair.source && t.targetLanguage == pair.target },
                                     set: { if $0 { t.applyQuickPair(index) } })) {
                    let source = pair.source.map { settings.language($0).name } ?? "Detect language"
                    Text("\(source) → \(settings.language(pair.target).name)    \(settings.bindings[InAppAction.pairs[index]]?.displayString ?? "")")
                }
            }
        } label: { Label("Language pairs", systemImage: "arrow.triangle.branch").labelStyle(.iconOnly) }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Language pairs")
        .accessibilityLabel("Language pairs")
        .accessibilityIdentifier("pairsMenu")
    }

    // MARK: Editors

    private func sourcePane(enabled: Bool) -> some View {
        VStack(spacing: 0) {
            PaneEditor(pane: .source, text: t.sourceText, interactionEnabled: enabled, undoManager: t.undoManager,
                       placeholder: "Type or paste text to translate", registry: registry, onChange: { t.sourceText = $0 })
            HStack {
                Text("\(t.characterCount) characters").accessibilityIdentifier("charCount")
                Spacer()
                Button {
                    guard let source = registry.source else { return }
                    source.insertText("", replacementRange: NSRange(location: 0, length: (source.string as NSString).length))
                } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .disabled(t.sourceText.isEmpty)
                .help("Clear source text")
                .accessibilityLabel("Clear source text")
            }
            .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(maxWidth: .infinity)
    }

    private func translationPane(enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !t.translation.isEmpty && !busy && (!t.translationIsCurrent || t.failure != nil) {
                Text(resultStatus)
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 12)
                    .accessibilityIdentifier("resultStatus")
            }
            PaneEditor(pane: .translation, text: t.translation, interactionEnabled: enabled, undoManager: t.undoManager,
                       placeholder: outputPlaceholder, registry: registry, onChange: { t.userEditedTranslation($0) },
                       onMouseSelection: { presenter.presentForMouseSelection(from: $0) })
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                Text(status).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("translationStatus")
                if t.undoManager.canUndo, ["Restore Translation", "Replace Phrase"].contains(t.undoManager.undoActionName) {
                    Button("Undo") { t.undoManager.undo() }.accessibilityIdentifier("undoEdit")
                }
                if busy {
                    Button("Stop") { t.stop(); registry.restoreEditorFocus() }.accessibilityIdentifier("stop")
                } else if let failure = t.failure {
                    Button(failure.requiresSignIn ? "Sign in" : failure.operation == .smoothing ? "Retry adjustment" : "Retry") {
                        if failure.requiresSignIn { openSettings() }
                        else { t.retryLastFailure(); registry.restoreEditorFocus() }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityIdentifier("recover")
                } else if !t.sourceText.isEmpty && (!settings.liveTranslation || t.isStopped) {
                    Button("Translate") { t.translateNow(); registry.restoreEditorFocus() }
                        .buttonStyle(.borderedProminent).controlSize(.small).accessibilityIdentifier("translate")
                }
                Button { app.copyTranslation() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .disabled(!t.canCopyTranslation)
                    .help("Copy translation (\(settings.bindings[.copyTranslation]?.displayString ?? ""))")
                    .accessibilityLabel("Copy translation")
                    .accessibilityIdentifier("copy")
            }
            .buttonStyle(.borderless)
            .font(.caption).padding(12)
        }
        .frame(maxWidth: .infinity)
        .background(EditorPalette.result)
    }

    private var resultStatus: String {
        if t.failure?.operation == .smoothing { return "Replacement kept · sentence not adjusted" }
        if t.isStopped { return "Stopped · not finished" }
        if t.translationIsPartial { return "Partial translation · not complete" }
        return "Previous translation · not updated"
    }

    private var outputPlaceholder: String {
        if busy { return "" }
        if !settings.liveTranslation { return "Translate when you’re ready." }
        return "Your translation appears here as you type."
    }

    private var status: String {
        if t.isSmoothing { return "Adjusting sentence…" }
        if t.isTranslating { return "Translating…" }
        if let failure = t.failure {
            if failure.requiresSignIn { return "Sign in to continue. Your text is still here." }
            return failure.operation == .smoothing ? "Couldn’t adjust the sentence. Your replacement is kept."
                : "Couldn’t translate. Your text is still here."
        }
        if t.isStopped { return "Stopped" }
        if t.translation.isEmpty { return settings.liveTranslation ? "Live translation" : "Manual translation" }
        return "Select a word or phrase for alternatives"
    }
}

enum EditorPalette {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 192/255, green: 223/255, blue: 181/255, alpha: 1)
            : NSColor(red: 52/255, green: 99/255, blue: 72/255, alpha: 1)
    })
    static let result = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 41/255, green: 52/255, blue: 43/255, alpha: 1)
            : NSColor(red: 242/255, green: 246/255, blue: 239/255, alpha: 1)
    })
}
