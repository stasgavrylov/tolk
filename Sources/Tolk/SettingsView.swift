import AppKit
import KeyboardShortcuts
import SwiftUI
import TolkCore

enum SettingsTab: String, CaseIterable, Hashable {
    case general, languages, shortcuts, ai
    @MainActor static var requested: SettingsTab = .general
    var title: String { self == .ai ? "AI" : rawValue.capitalized }
}

extension Notification.Name {
    static let selectSettingsTab = Notification.Name("tolk.selectSettingsTab")
}

struct SettingsView: View {
    let app: AppState
    @State private var tab = SettingsTab.requested

    var body: some View {
        VStack(spacing: 12) {
            RoundedTabPicker(title: "Settings", choices: SettingsTab.allCases, selection: $tab) { $0.title }
                .frame(width: 440, height: 30)
                .accessibilityIdentifier("settingsTabs")
            SettingsPages(app: app, selection: tab)
        }
        .padding(16)
        .frame(width: 640, height: 560)
        .onReceive(NotificationCenter.default.publisher(for: .selectSettingsTab)) { note in
            if let t = note.object as? SettingsTab { tab = t }
        }
    }
}

/// Native tab pages retain each form's local state, without the system's pill-shaped tab strip.
private struct SettingsPages: NSViewRepresentable {
    let app: AppState
    let selection: SettingsTab

    func makeNSView(context: Context) -> NSTabView {
        let tabs = NSTabView()
        tabs.tabViewType = .noTabsNoBorder
        tabs.drawsBackground = false
        tabs.setAccessibilityRole(.group)
        for tab in SettingsTab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.title
            item.view = NSHostingView(rootView: SettingsPage(app: app, tab: tab))
            tabs.addTabViewItem(item)
        }
        return tabs
    }

    func updateNSView(_ tabs: NSTabView, context: Context) {
        for item in tabs.tabViewItems {
            if let host = item.view as? NSHostingView<SettingsPage>, host.rootView.app !== app {
                host.rootView = SettingsPage(app: app, tab: host.rootView.tab)
            }
        }
        if tabs.selectedTabViewItem?.identifier as? String != selection.rawValue {
            tabs.selectTabViewItem(withIdentifier: selection.rawValue)
        }
        // The visible picker owns navigation; don't expose a second, invisible tab strip.
        if let page = tabs.selectedTabViewItem?.view { tabs.setAccessibilityChildren([page]) }
    }
}

private struct SettingsPage: View {
    let app: AppState
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(settings: app.settings)
            case .languages: LanguageSettings(settings: app.settings)
            case .shortcuts: ShortcutSettings(settings: app.settings)
            case .ai: AISettings(app: app)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Translation") {
                Toggle("Translate as you type", isOn: $settings.liveTranslation)
                if settings.liveTranslation {
                    Stepper("Delay after typing: \(settings.debounceMilliseconds) ms",
                            value: $settings.debounceMilliseconds, in: 200...2000, step: 100)
                } else {
                    Text("Press \(settings.bindings[.translate]?.displayString ?? "⌘↩") to translate.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("App") {
                Toggle("Hide Dock icon (use the menu bar icon)", isOn: $settings.hideDockIcon)
            }
            Section("History") {
                Toggle("Pause history", isOn: $settings.historyPaused)
                Text("Settled translations are stored locally on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Languages

private struct LanguageSettings: View {
    @Bindable var settings: AppSettings
    @State private var toAdd = ""

    private var addable: [Language] {
        LanguageCatalog.all.filter { lang in !settings.enabledLanguages.contains { $0.code == lang.code } }
    }

    var body: some View {
        Form {
            Section("Languages") {
                List {
                    ForEach(settings.enabledLanguages) { lang in
                        HStack {
                            Text(lang.name)
                            Text(lang.shortLabel).foregroundStyle(.secondary)
                            Spacer()
                            Button { settings.enabledLanguages.removeAll { $0.code == lang.code } } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(settings.enabledLanguages.count <= 2)
                        }
                    }
                    .onMove { settings.enabledLanguages.move(fromOffsets: $0, toOffset: $1) }
                }
                .frame(minHeight: 120)
                HStack {
                    Picker("Add language", selection: $toAdd) {
                        Text("Choose…").tag("")
                        ForEach(addable) { Text($0.name).tag($0.code) }
                    }
                    Button("Add") {
                        if let lang = LanguageCatalog.language(for: toAdd) { settings.enabledLanguages.append(lang) }
                        toAdd = ""
                    }
                    .disabled(toAdd.isEmpty)
                }
            }
            Section("Quick pairs (⌘1…⌘9 by default)") {
                ForEach(Array(settings.quickPairs.enumerated()), id: \.offset) { index, _ in
                    HStack {
                        Text("\(index + 1).").monospacedDigit().frame(width: 20)
                        Picker("From", selection: pairBinding(index, \.source)) {
                            Text("Detect").tag(String?.none)
                            ForEach(settings.enabledLanguages) { Text($0.name).tag(Optional($0.code)) }
                        }
                        Image(systemName: "arrow.right")
                        Picker("To", selection: pairBinding(index, \.target)) {
                            ForEach(settings.enabledLanguages) { Text($0.name).tag($0.code) }
                        }
                        Button { settings.quickPairs.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    .labelsHidden()
                }
                HStack {
                    Button("Add pair") {
                        let codes = settings.enabledLanguages.map(\.code)
                        settings.quickPairs.append(LanguagePair(source: codes.first, target: codes.dropFirst().first ?? "en"))
                    }
                    .disabled(settings.quickPairs.count >= 9)
                    Spacer()
                    Button("Reset to defaults") { settings.quickPairs = LanguagePair.defaultQuickPairs }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pairBinding<T>(_ index: Int, _ key: WritableKeyPath<LanguagePair, T>) -> Binding<T> {
        Binding(
            get: { settings.quickPairs.indices.contains(index) ? settings.quickPairs[index][keyPath: key] : LanguagePair.defaultQuickPairs[0][keyPath: key] },
            set: { if settings.quickPairs.indices.contains(index) { settings.quickPairs[index][keyPath: key] = $0 } })
    }
}

// MARK: Shortcuts

private struct ShortcutSettings: View {
    @Bindable var settings: AppSettings
    @State private var trusted = SelectionService.isTrusted
    @State private var conflict: String?
    @State private var pairConflict: String?

    var body: some View {
        Form {
            Section("In the Tolk window") {
                ForEach([InAppAction.translate, .swap, .suggestions, .copyTranslation, .history], id: \.self) { action in
                    InAppShortcutRow(action: action, settings: settings, conflict: $conflict)
                }
                if let conflict { Text(conflict).foregroundStyle(.red).font(.caption) }
                Button("Reset window shortcuts") { settings.resetBindings(); conflict = nil; pairConflict = nil }
            }
            // One row per pair with both scopes side by side, so it is clear which one works where.
            Section {
                HStack {
                    Text("Pair")
                    Spacer()
                    Text("In Tolk").frame(width: 146, alignment: .leading)
                    Text("Everywhere").frame(width: 150, alignment: .leading)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(InAppAction.pairs.enumerated()), id: \.offset) { index, action in
                    HStack {
                        Text(pairTitle(index))
                        Spacer()
                        InAppShortcutField(action: action, settings: settings, conflict: $pairConflict)
                        KeyboardShortcuts.Recorder(for: KeyboardShortcuts.Name.globalPairs[index], onChange: needsTrust)
                            .frame(width: 150)
                    }
                }
                if let pairConflict { Text(pairConflict).foregroundStyle(.red).font(.caption) }
            } header: {
                Text("Quick pairs")
            } footer: {
                Text("In Tolk shortcuts work while the Tolk window is focused. Everywhere shortcuts translate the selected text in any app with that pair; they are off until set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Off by default. Set a shortcut to enable it. These work in every app, so pick combinations other apps don't use.")
                    .font(.caption).foregroundStyle(.secondary)
                KeyboardShortcuts.Recorder("Show / hide Tolk", name: .toggleWindow)
                KeyboardShortcuts.Recorder("Translate selection", name: .translateSelection, onChange: needsTrust)
                KeyboardShortcuts.Recorder("Translate selection in place", name: .replaceSelection, onChange: needsTrust)
                Toggle("Press ⌘C twice to translate the copied text", isOn: $settings.doubleCopyTrigger)
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Accessibility access granted" : "Selection shortcuts need Accessibility access")
                    Spacer()
                    if !trusted { Button("Open Settings") { SelectionService.openAccessibilitySettings() } }
                }
                .font(.caption)
            } header: {
                Text("Global (system-wide)")
            }
        }
        .formStyle(.grouped)
        .onAppear { trusted = SelectionService.isTrusted }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in trusted = SelectionService.isTrusted }
    }

    private func pairTitle(_ index: Int) -> String {
        guard settings.quickPairs.indices.contains(index) else { return "Quick pair \(index + 1) (unset)" }
        let p = settings.quickPairs[index]
        return "\(index + 1). \(p.source.map { settings.language($0).name } ?? "Detect") → \(settings.language(p.target).name)"
    }

    private func needsTrust(_ shortcut: KeyboardShortcuts.Shortcut?) {
        if shortcut != nil { trusted = SelectionService.requestTrust() }
    }
}

private struct InAppShortcutRow: View {
    let action: InAppAction
    @Bindable var settings: AppSettings
    @Binding var conflict: String?

    var body: some View {
        LabeledContent(action.title) {
            InAppShortcutField(action: action, settings: settings, conflict: $conflict)
        }
    }
}

/// Recorder plus reset button for one in-window action.
private struct InAppShortcutField: View {
    let action: InAppAction
    @Bindable var settings: AppSettings
    @Binding var conflict: String?

    var body: some View {
        HStack(spacing: 6) {
            ShortcutRecorderField(combo: settings.bindings[action]) { combo in
                if let combo, let problem = ShortcutConflicts.conflict(for: combo, action: action, bindings: settings.bindings) {
                    conflict = problem
                    return false
                }
                conflict = nil
                settings.bindings[action] = combo
                return true
            }
            .frame(width: 120, height: 22)
            Button { settings.bindings[action] = action.defaultCombo; conflict = nil } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to \(action.defaultCombo.displayString)")
        }
    }
}

/// Click, then press a key combination. Delete clears; Escape cancels.
struct ShortcutRecorderField: NSViewRepresentable {
    let combo: KeyCombo?
    /// Returns false to reject (e.g. conflict).
    let onRecord: (KeyCombo?) -> Bool

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.onRecord = onRecord
        b.combo = combo
        return b
    }

    func updateNSView(_ b: RecorderButton, context: Context) {
        b.onRecord = onRecord
        if !b.recording { b.combo = combo }
    }

    final class RecorderButton: NSButton {
        var onRecord: ((KeyCombo?) -> Bool)?
        var combo: KeyCombo? { didSet { refresh() } }
        private(set) var recording = false { didSet { refresh() } }
        private var monitor: Any?

        init() {
            super.init(frame: .zero)
            bezelStyle = .push
            controlSize = .small
            target = self
            action = #selector(toggle)
            refresh()
        }

        required init?(coder: NSCoder) { fatalError() }

        private func refresh() {
            title = recording ? "Press keys…" : (combo?.displayString ?? "None")
        }

        @objc private func toggle() { recording ? stop() : start() }

        private func start() {
            recording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                self.handle(event)
                return nil
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            recording = false
        }

        private func handle(_ event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53 { stop(); return } // Escape
            if event.keyCode == 51 || event.keyCode == 117, flags.isEmpty { // Delete clears
                if onRecord?(nil) == true { combo = nil }
                stop()
                return
            }
            var mods: KeyCombo.Modifiers = []
            if flags.contains(.command) { mods.insert(.command) }
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.option) { mods.insert(.option) }
            if flags.contains(.control) { mods.insert(.control) }
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { NSSound.beep(); return }
            let key = event.keyCode == 36 ? "\r" : String(chars.prefix(1))
            let new = KeyCombo(key, mods)
            if onRecord?(new) == true { combo = new; stop() } else { NSSound.beep(); stop() }
        }
    }
}
