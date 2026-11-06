import AppKit
import KeyboardShortcuts
import TolkCore

/// Development-only command channel for end-to-end checks. Installed only when launched with
/// TOLK_DEV_PI_TOKEN=1 and a TOLK_DEV_SECRET. Post `dev.stas.tolk.dev` distributed notifications with
/// userInfo {"secret": ..., "cmd": ..., "arg": ...}; notifications cannot identify their sender, so
/// commands without the launch secret are ignored. State is written (mode 0600) to
/// tolk-dev-state.json in the per-user temporary directory after each command.
@MainActor
enum DevAutomation {
    static let statePath = (NSTemporaryDirectory() as NSString).appendingPathComponent("tolk-dev-state.json")
    private static let secret = ProcessInfo.processInfo.environment["TOLK_DEV_SECRET"] ?? ""
    /// TOLK_DEV_BACKGROUND=1: never activate the app (checks run while the user works).
    static let background = ProcessInfo.processInfo.environment["TOLK_DEV_BACKGROUND"] == "1"
    private static weak var delegate: AppDelegate?

    static func install(delegate: AppDelegate) {
        guard secret.count >= 16 else {
            FileHandle.standardError.write(Data("dev automation disabled: TOLK_DEV_SECRET (16+ chars) not set\n".utf8))
            return
        }
        self.delegate = delegate
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.stas.tolk.dev"), object: nil, queue: .main) { note in
            guard note.userInfo?["secret"] as? String == secret else { return }
            let cmd = note.userInfo?["cmd"] as? String ?? ""
            let arg = note.userInfo?["arg"] as? String ?? ""
            MainActor.assumeIsolated { handle(cmd, arg) }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            FileHandle.standardError.write(Data("keyDown \(event.charactersIgnoringModifiers ?? "") mods=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue) key=\(NSApp.keyWindow?.title ?? "nil") fr=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")\n".utf8))
            return event
        }
        dump()
    }

    private static func handle(_ cmd: String, _ arg: String) {
        guard let d = delegate else { return }
        let t = d.app.translator
        switch cmd {
        case "action": if let a = InAppAction(rawValue: arg) { d.perform(a) }
        case "key":
            // arg "s:cmd,shift". Dispatched like AppKit does for key equivalents: key window views, then main menu.
            let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
            let chars = parts[0] == "return" ? "\r" : parts[0]
            let mods = parts.count > 1 ? parts[1] : ""
            var flags: NSEvent.ModifierFlags = []
            if mods.contains("cmd") { flags.insert(.command) }
            if mods.contains("shift") { flags.insert(.shift) }
            if mods.contains("opt") { flags.insert(.option) }
            if mods.contains("ctrl") { flags.insert(.control) }
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: d.main.window.windowNumber, context: nil,
                                            characters: flags.contains(.shift) ? chars.uppercased() : chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0) {
                let handled = d.main.window.performKeyEquivalent(with: event) || (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
                FileHandle.standardError.write(Data("key \(arg) handled=\(handled)\n".utf8))
            }
        case "type":
            if let tv = d.main.registry.source {
                d.main.window.makeFirstResponder(tv)
                tv.insertText(arg, replacementRange: tv.selectedRange())
            }
        case "clear": t.sourceText = ""
        case "setGlobal":
            // arg "toggleWindow=111" (key code, "" clears) with \u2303\u2325\u2318
            let kv = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = KeyboardShortcuts.Name(kv[0])
            let shortcut = Int(kv[1]).map { KeyboardShortcuts.Shortcut(KeyboardShortcuts.Key(rawValue: $0), modifiers: [.control, .option, .command]) }
            KeyboardShortcuts.setShortcut(shortcut, for: name)
            FileHandle.standardError.write(Data("global \(kv[0]) = \(String(describing: KeyboardShortcuts.getShortcut(for: name)))\n".utf8))
        case "addLanguage":
            if let lang = LanguageCatalog.language(for: arg), !d.app.settings.enabledLanguages.contains(lang) {
                d.app.settings.enabledLanguages.append(lang)
            }
        case "bind":
            // arg "swap=k:cmd,opt"; validated like the recorder does
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let combo = kv[1].split(separator: ":").map(String.init)
            var mods: KeyCombo.Modifiers = []
            if combo.count > 1 {
                if combo[1].contains("cmd") { mods.insert(.command) }
                if combo[1].contains("shift") { mods.insert(.shift) }
                if combo[1].contains("opt") { mods.insert(.option) }
                if combo[1].contains("ctrl") { mods.insert(.control) }
            }
            if let action = InAppAction(rawValue: kv[0]) {
                let new = KeyCombo(combo[0], mods)
                if let problem = ShortcutConflicts.conflict(for: new, action: action, bindings: d.app.settings.bindings) {
                    FileHandle.standardError.write(Data("bind rejected: \(problem)\n".utf8))
                } else {
                    d.app.settings.bindings[action] = new
                    FileHandle.standardError.write(Data("bind ok \(action) \(new.displayString)\n".utf8))
                }
            }
        case "restoreHistory", "starHistory":
            if let entries = try? d.app.history?.entries(), let i = Int(arg), entries.indices.contains(i) {
                if cmd == "restoreHistory" { d.app.restore(entries[i]) }
                else { try? d.app.history?.toggleStar(entries[i]); d.app.historyChanged() }
            }
        case "searchHistory":
            let found = (try? d.app.history?.entries(matching: arg).map(\.sourceText)) ?? []
            FileHandle.standardError.write(Data("search \(arg) -> \(found)\n".utf8))
        case "statusMenu":
            let titles = d.statusMenuTitles()
            FileHandle.standardError.write(Data("statusMenu \(titles)\n".utf8))
        case "mouseSelectTranslation":
            if let tv = d.main.registry.translation {
                tv.setSelectedRange((tv.string as NSString).range(of: arg))
                tv.onMouseSelection?(tv)
            }
        case "pickSuggestion":
            if case .loaded(_, _, let items) = t.suggestions, let i = Int(arg), items.indices.contains(i) {
                d.main.presenter.pickForDev(items[i])
            }
        case "setTarget": t.targetLanguage = arg
        case "setSource": t.sourceLanguage = arg.isEmpty ? nil : arg
        case "setTone": if let tone = Tone(rawValue: arg) { t.tone = tone }
        case "selectTranslation":
            // arg: substring to select in the translation pane
            if let tv = d.main.registry.translation {
                let r = (tv.string as NSString).range(of: arg)
                d.main.window.makeFirstResponder(tv)
                tv.setSelectedRange(r)
            }
        case "selectSource":
            if let tv = d.main.registry.source {
                let r = (tv.string as NSString).range(of: arg)
                d.main.window.makeFirstResponder(tv)
                tv.setSelectedRange(r)
            }
        case "settings":
            // Keep existing development scripts working after the two tabs were combined.
            let tab: SettingsTab = switch arg {
            case "account", "models": .ai
            default: SettingsTab(rawValue: arg) ?? .general
            }
            d.showSettings(tab: tab)
        case "show": d.main.show()
        case "set":
            // arg: key=value for a few settings
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                switch parts[0] {
                case "hideDockIcon": d.app.settings.hideDockIcon = parts[1] == "1"
                case "historyPaused": d.app.settings.historyPaused = parts[1] == "1"
                case "liveTranslation": d.app.settings.liveTranslation = parts[1] == "1"
                case "doubleCopyTrigger": d.app.settings.doubleCopyTrigger = parts[1] == "1"
                default: break
                }
            }
        default: break
        }
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            dump()
        }
    }

    static func dump() {
        guard let d = delegate else { return }
        let t = d.app.translator
        var suggestions: [String: Any] = ["state": "idle"]
        switch t.suggestions {
        case .idle: break
        case .loading(let pane, let sel): suggestions = ["state": "loading", "pane": "\(pane)", "selection": sel]
        case .failed(let pane, let sel, let msg): suggestions = ["state": "failed", "pane": "\(pane)", "selection": sel, "error": msg]
        case .loaded(let pane, let sel, let items):
            suggestions = ["state": "loaded", "pane": "\(pane)", "selection": sel,
                           "items": items.map { ["text": $0.text, "note": $0.note, "back": $0.back] }]
        }
        let history = (try? d.app.history?.entries().prefix(5).map {
            ["source": $0.sourceText, "translation": $0.translation, "pair": "\($0.sourceLanguage)->\($0.targetLanguage)", "starred": $0.starred] as [String: Any]
        }) ?? []
        let state: [String: Any] = [
            "sourceText": t.sourceText, "translation": t.translation,
            "sourceLanguage": t.sourceLanguage ?? NSNull(), "targetLanguage": t.targetLanguage,
            "detected": t.detected?.code ?? NSNull(), "tone": t.tone.rawValue,
            "isTranslating": t.isTranslating, "isSmoothing": t.isSmoothing, "error": t.errorMessage ?? NSNull(),
            "suggestions": suggestions, "showHistory": d.app.showHistory, "history": Array(history),
            "activationPolicy": NSApp.activationPolicy() == .regular ? "regular" : "accessory",
            "windowVisible": d.main.window.isVisible, "accessibilityTrusted": SelectionService.isTrusted,
            "firstResponder": d.main.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
            "keyWindow": NSApp.keyWindow.map { "\(type(of: $0)):\($0.title)" } ?? "nil",
            "isActive": NSApp.isActive,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            FileManager.default.createFile(atPath: statePath, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }
}
