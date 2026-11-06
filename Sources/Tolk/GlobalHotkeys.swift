import AppKit
import ApplicationServices
import KeyboardShortcuts
import TolkCore

extension KeyboardShortcuts.Name {
    // No defaults: nothing is registered system-wide until the user records a shortcut.
    static let toggleWindow = Self("toggleWindow")
    static let translateSelection = Self("translateSelection")
    static let replaceSelection = Self("replaceSelection")
    static let globalPairs: [Self] = (1...9).map { Self("globalPair\($0)") }

    static var selectionReading: [Self] { [.translateSelection, .replaceSelection] + globalPairs }
}

/// Reads and replaces the selected text in the frontmost app.
@MainActor
enum SelectionService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts for Accessibility permission if missing; returns current trust.
    @discardableResult
    static func requestTrust() -> Bool {
        // Value of kAXTrustedCheckOptionPrompt (the global is not concurrency-safe to reference).
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Where a selection was read: the app and its focused element.
    @MainActor struct Origin {
        let pid: pid_t?
        let element: AXUIElement?

        static func current() -> Origin {
            Origin(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier, element: SelectionService.focusedElement())
        }

        /// Pasting is only safe while the same app and field still have focus. Fails closed when
        /// Accessibility cannot identify the field: the caller then shows the result in the window instead.
        var isStillFocused: Bool {
            let now = Origin.current()
            guard let pid, pid == now.pid, let element, let current = now.element else { return false }
            return CFEqual(element, current)
        }
    }

    /// Selected text via Accessibility, falling back to a simulated ⌘C (clipboard restored afterwards).
    static func readSelection() async -> String? {
        if let text = focusedElement().flatMap(selectedText), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount
        sendKey(8 /* c */, flags: .maskCommand)
        var text: String?
        var copied: Int?
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(20))
            if pasteboard.changeCount != before {
                text = pasteboard.string(forType: .string)
                copied = pasteboard.changeCount
                break
            }
        }
        if let copied { restore(saved, to: pasteboard, ifStill: copied) }
        return text
    }

    /// Replaces the current selection in the frontmost app by pasting, then restores the clipboard.
    static func replaceSelection(with text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let written = pasteboard.changeCount
        sendKey(9 /* v */, flags: .maskCommand)
        // Give the target app time to read the pasteboard before restoring it.
        try? await Task.sleep(for: .milliseconds(400))
        restore(saved, to: pasteboard, ifStill: written)
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }

    private static func selectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func sendKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Ignore modifiers still physically held from the triggering hotkey.
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
    }

    /// Restores the snapshot unless something else wrote to the clipboard after Tolk's own change.
    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard, ifStill changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        })
    }
}

/// Registers the opt-in global hotkeys and the optional ⌘C⌘C trigger.
@MainActor
final class GlobalHotkeyController {
    private let app: AppState
    private let window: MainWindowController
    private let hud: HUD
    private var copyMonitor: Any?
    private var lastCopy: Date?
    private var replaceTask: Task<Void, Never>?

    init(app: AppState, window: MainWindowController) {
        self.app = app
        self.window = window
        hud = HUD()
        KeyboardShortcuts.onKeyUp(for: .toggleWindow) { [weak self] in self?.window.toggle() }
        KeyboardShortcuts.onKeyUp(for: .translateSelection) { [weak self] in self?.translateSelection(pair: nil) }
        KeyboardShortcuts.onKeyUp(for: .replaceSelection) { [weak self] in self?.replaceSelection() }
        for (index, name) in KeyboardShortcuts.Name.globalPairs.enumerated() {
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in self?.translateSelection(pair: index) }
        }
        updateDoubleCopyMonitor()
    }

    func updateDoubleCopyMonitor() {
        if let copyMonitor { NSEvent.removeMonitor(copyMonitor) }
        copyMonitor = nil
        guard app.settings.doubleCopyTrigger else { return }
        SelectionService.requestTrust()
        copyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 8, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return }
            MainActor.assumeIsolated { self?.copyPressed() }
        }
    }

    private func copyPressed() {
        let now = Date()
        defer { lastCopy = now }
        guard let last = lastCopy, now.timeIntervalSince(last) < 0.45 else { return }
        lastCopy = nil
        Task {
            // Let the source app finish writing the second copy.
            try? await Task.sleep(for: .milliseconds(120))
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
            self.window.show()
            self.app.loadTranslation(text: text)
        }
    }

    private func ensureTrusted() -> Bool {
        if SelectionService.isTrusted { return true }
        SelectionService.requestTrust()
        hud.show("Allow Tolk in System Settings → Privacy & Security → Accessibility", isError: true)
        return false
    }

    func translateSelection(pair: Int?) {
        guard ensureTrusted() else { return }
        Task {
            guard let text = await SelectionService.readSelection(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                hud.show("No text selected", isError: true)
                return
            }
            window.show()
            if let pair, app.settings.quickPairs.indices.contains(pair) {
                let p = app.settings.quickPairs[pair]
                app.loadTranslation(text: text, source: p.source.map { .language($0) } ?? .detect, target: p.target)
            } else {
                app.loadTranslation(text: text)
            }
        }
    }

    /// Translates the selection with the window's current target and pastes the result over it.
    func replaceSelection() {
        guard ensureTrusted() else { return }
        replaceTask?.cancel()
        replaceTask = Task {
            let origin = SelectionService.Origin.current()
            guard let text = await SelectionService.readSelection(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                hud.show("No text selected", isError: true)
                return
            }
            let plan = TranslationPlanner.plan(text: text, source: nil, target: app.translator.targetLanguage, settings: app.settings)
            hud.show("Translating \(plan.source?.shortLabel ?? "…") → \(plan.target.shortLabel)…", sticky: true)
            do {
                let result = try await app.translator.provider.complete(plan.request)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled, !result.isEmpty else { hud.hide(); return }
                // Keep the user's surrounding whitespace (selections often include a trailing space/newline).
                let leading = String(text.prefix { $0.isWhitespace }), trailing = String(text.reversed().prefix { $0.isWhitespace }.reversed())
                guard origin.isStillFocused else {
                    // The user moved on while we translated; pasting now would hit the wrong place.
                    app.loadTranslation(text: text, source: plan.source.map { .language($0.code) } ?? .detect,
                                        target: plan.target.code, translation: result)
                    hud.show("Not pasted: couldn't confirm the original field still has focus. The translation is in the Tolk window.", isError: true)
                    return
                }
                await SelectionService.replaceSelection(with: leading + result + trailing)
                hud.hide()
                if !app.settings.historyPaused, let history = app.history {
                    do {
                        try history.record(HistoryCandidate(sourceText: text, translation: result, sourceLanguage: plan.source?.code ?? "",
                                                            targetLanguage: plan.target.code, tone: plan.tone))
                        app.historyChanged()
                    } catch {
                        app.historyError = "Could not save history: \(error.localizedDescription)"
                    }
                }
            } catch {
                hud.show(error.localizedDescription, isError: true)
            }
        }
    }
}

/// Small non-activating status panel for background hotkey actions.
@MainActor
final class HUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, isError: Bool = false, sticky: Bool = false) {
        hideTask?.cancel()
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = isError ? .systemRed : .labelColor
        label.lineBreakMode = .byTruncatingTail
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        let width = min(max(label.intrinsicContentSize.width + 28, 160), 520)
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = effect
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: screen.midX - width / 2, y: screen.minY + 80, width: width, height: 40), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        if !sticky {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(isError ? 3 : 1.5))
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }
}
