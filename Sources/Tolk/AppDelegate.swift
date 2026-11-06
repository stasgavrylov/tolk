import AppKit
import Observation
import SwiftUI
import TolkCore

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let registry = PaneRegistry()
    let finderRegistry = PaneRegistry()
    let presenter: SuggestionPresenter
    private let app: AppState
    private var undoManager: UndoManager {
        app.screen == .translation ? app.translator.undoManager : app.finder.undoManager
    }
    private var activeRegistry: PaneRegistry { app.screen == .translation ? registry : finderRegistry }

    init(app: AppState, autosaveName: String? = "TolkMain", openSettings: @escaping () -> Void) {
        self.app = app
        presenter = SuggestionPresenter(translator: app.translator)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        // Hosting/layout can ask for Undo while being attached, before the first responder exists.
        window.delegate = self
        window.title = "Tolk"
        window.isReleasedWhenClosed = false
        if let autosaveName { window.setFrameAutosaveName(autosaveName) }
        window.toolbarStyle = .unifiedCompact
        window.contentMinSize = NSSize(width: 720, height: 380)
        let savedFrame = window.frame
        let content = NSHostingController(rootView: MainView(
            app: app, registry: registry, finderRegistry: finderRegistry, presenter: presenter, openSettings: openSettings))
        // NSWindow owns sizing and autosave; the host's ideal-size constraints would shrink it to 720×380.
        content.sizingOptions = []
        window.contentViewController = content
        window.setFrame(savedFrame, display: false)
        if window.frame.width < 720 { window.setContentSize(NSSize(width: 960, height: 520)) }
        window.center()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoManager }

    var isVisible: Bool { window.isVisible && NSApp.isActive && window.isKeyWindow }

    func show() {
        if DevAutomation.background {
            // Dev checks run while the user works: never steal focus.
            window.orderFrontRegardless()
            return
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        activeRegistry.focusEditor()
        ensureActivated()
    }

    /// macOS 14+ activation is cooperative: it is refused when the trigger was not input to Tolk
    /// (the \u{2318}C\u{2318}C monitor observes another app's keystrokes). Escalate only if that happened.
    private func ensureActivated() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard window.isVisible, !NSApp.isActive else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
            try? await Task.sleep(for: .milliseconds(150))
            guard window.isVisible, !NSApp.isActive else { return }
            // Deprecated, but the only remaining way once cooperative and LaunchServices activation were refused.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func toggle() {
        if DevAutomation.background {
            // Never hide/activate while dev checks run in the background; just flip visibility.
            if window.isVisible { window.orderOut(nil) } else { show() }
            return
        }
        if isVisible { NSApp.hide(nil) } else { show() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    let app: AppState
    private(set) var main: MainWindowController!
    private var hotkeys: GlobalHotkeyController!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var actionItems: [InAppAction: NSMenuItem] = [:]

    override convenience init() { self.init(app: AppState()) }

    init(app: AppState) {
        self.app = app
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        main = MainWindowController(app: app, openSettings: { [weak self] in self?.showSettings(tab: .ai) })
        hotkeys = GlobalHotkeyController(app: app, window: main)
        buildMainMenu()
        buildStatusItem()
        observeSettings()
        applyActivationPolicy()
        main.show()
        if AppState.usesDevCredentials { DevAutomation.install(delegate: self) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        main.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        app.translator.commitHistory()
    }

    // MARK: Settings observation

    private func observeSettings() {
        withObservationTracking {
            _ = app.settings.bindings
            _ = app.settings.hideDockIcon
            _ = app.settings.doubleCopyTrigger
            _ = app.settings.quickPairs
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.applyBindings()
                self.applyActivationPolicy()
                self.hotkeys.updateDoubleCopyMonitor()
                self.observeSettings()
            }
        }
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = app.settings.hideDockIcon ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { main.show() }
    }

    // MARK: Menus

    func buildMainMenu() {
        let menu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Tolk", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettingsAction), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Tolk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tolk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(submenu(appMenu, "Tolk"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(submenu(edit, "Edit"))

        let translate = NSMenu(title: "Translate")
        for action in [InAppAction.translate, .swap, .suggestions, .copyTranslation] {
            translate.addItem(actionItem(action))
        }
        translate.addItem(.separator())
        let pairsMenu = NSMenu(title: "Language Pairs")
        for action in InAppAction.pairs { pairsMenu.addItem(actionItem(action)) }
        pairsMenu.delegate = self
        translate.addItem(submenu(pairsMenu, "Language Pairs"))
        menu.addItem(submenu(translate, "Translate"))

        let view = NSMenu(title: "View")
        for screen in AppState.Screen.allCases {
            let screenItem = item(screen.rawValue, #selector(selectScreenAction(_:)), "")
            screenItem.representedObject = screen.rawValue
            view.addItem(screenItem)
        }
        view.addItem(.separator())
        view.addItem(actionItem(.history))
        menu.addItem(submenu(view, "View"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(item("Show Translator", #selector(showMainAction), "0"))
        menu.addItem(submenu(window, "Window"))
        NSApp.windowsMenu = window

        NSApp.mainMenu = menu
        applyBindings()
    }

    private func submenu(_ menu: NSMenu, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func actionItem(_ action: InAppAction) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: #selector(performInAppAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        actionItems[action] = item
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) { applyBindings() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let raw = item.representedObject as? String, let action = InAppAction(rawValue: raw) {
            if action == .translate { item.title = app.primaryActionTitle }
            return app.canPerform(action)
        }
        if let raw = item.representedObject as? String, let screen = AppState.Screen(rawValue: raw) {
            item.state = app.screen == screen ? .on : .off
        }
        return true
    }

    @objc private func selectScreenAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let screen = AppState.Screen(rawValue: raw) else { return }
        app.screen = screen
        main.show()
    }

    private func applyBindings() {
        for (action, item) in actionItems {
            if let index = action.pairIndex {
                let pairs = app.settings.quickPairs
                item.title = pairs.indices.contains(index)
                    ? "\(app.settings.language(pairs[index].source ?? "").name) → \(app.settings.language(pairs[index].target).name)"
                    : "Quick pair \(index + 1) (unset)"
                item.isHidden = !pairs.indices.contains(index)
            }
            let combo = app.settings.bindings[action]
            item.keyEquivalent = combo?.key ?? ""
            item.keyEquivalentModifierMask = combo.map(Self.modifierFlags) ?? []
        }
    }

    static func modifierFlags(_ combo: KeyCombo) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.command) }
        if combo.modifiers.contains(.shift) { flags.insert(.shift) }
        if combo.modifiers.contains(.option) { flags.insert(.option) }
        if combo.modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    @objc func performInAppAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = InAppAction(rawValue: raw) else { return }
        perform(action)
    }

    func perform(_ action: InAppAction) {
        guard app.canPerform(action) else { return }
        let t = app.translator
        if let index = action.pairIndex { t.applyQuickPair(index); return }
        switch action {
        case .translate:
            if app.primaryActionRequiresSignIn { showSettings(tab: .ai) }
            else { app.performPrimaryAction() }
        case .swap: t.swap()
        case .suggestions:
            if let pane = main.registry.activePaneWithSelection() { main.presenter.present(from: pane) } else { NSSound.beep() }
        case .history: app.showHistory.toggle()
        case .copyTranslation: app.copyTranslation()
        default: break
        }
    }

    // MARK: Status item

    private func buildStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Tolk")
        let menu = NSMenu()
        menu.addItem(item("Open Tolk", #selector(showMainAction), ""))
        menu.addItem(item("Translate Clipboard", #selector(translateClipboardAction), ""))
        menu.addItem(.separator())
        menu.addItem(item("History", #selector(showHistoryAction), ""))
        menu.addItem(item("Settings…", #selector(openSettingsAction), ""))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tolk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status.menu = menu
        statusItem = status
    }

    func statusMenuTitles() -> [String] {
        (statusItem?.menu?.items ?? []).map { $0.isSeparatorItem ? "—" : $0.title } + [statusItem?.isVisible == true ? "(visible)" : "(hidden)"]
    }

    @objc func showMainAction() { main.show() }

    @objc func showHistoryAction() {
        main.show()
        app.showHistory = true
    }

    @objc func translateClipboardAction() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { NSSound.beep(); return }
        main.show()
        app.loadTranslation(text: text)
    }

    @objc func openSettingsAction() { showSettings(tab: .general) }

    func showSettings(tab: SettingsTab) {
        SettingsTab.requested = tab
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Tolk Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(app: app))
            window.center()
            settingsWindow = window
        }
        NotificationCenter.default.post(name: .selectSettingsTab, object: tab)
        if DevAutomation.background { settingsWindow?.orderFrontRegardless(); return }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
