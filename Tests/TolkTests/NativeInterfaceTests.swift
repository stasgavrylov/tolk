import AppKit
import ApplicationServices
import SwiftUI
import Testing
import TolkCore
import TolkTestSupport
@testable import Tolk

@MainActor @Suite(.serialized) struct NativeInterfaceTests {
    private static let application: NSApplication = {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        return application
    }()

    private func makeApp(provider: any LLMProvider = MockProvider { _ in .init(chunks: [], error: LLMError.notSignedIn) },
                         usage: UsageStore? = nil) async throws -> AppState {
        _ = Self.application
        // A real AX client request initializes SwiftUI's otherwise-lazy accessibility tree.
        // Query our own test process only, without changing system accessibility preferences.
        let accessibility = await Task.detached {
            var role: CFTypeRef?
            return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role).rawValue
        }.value
        #expect(accessibility == AXError.success.rawValue, "The native accessibility provider must be available")
        let settings = AppSettings(defaults: UserDefaults(suiteName: "tolk-ui-tests-\(UUID().uuidString)")!)
        settings.liveTranslation = false
        return AppState(settings: settings,
                        auth: AuthController(manager: AuthManager(store: InMemoryCredentialStore())),
                        provider: provider, history: try HistoryStore(inMemory: true), usage: usage)
    }

    @Test func textEditorsUseTheSameUndoHistoryAsHistoryRestoreAndPhraseReplacement() async throws {
        let app = try await makeApp()
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.window.undoManager === app.translator.undoManager)
        let source = try #require(controller.registry.source)
        let translation = try #require(controller.registry.translation)
        #expect(source.undoManager === app.translator.undoManager)
        #expect(translation.undoManager === app.translator.undoManager)
    }

    @Test func pairsAreAnAccessibleMenuInTheTitlebarRatherThanAPermanentShortcutStrip() async throws {
        let app = try await makeApp()
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        controller.window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        let elements = descendants(controller.window)
        #expect(controller.window.frame.width == 960, "The content host must not shrink the default window to its minimum")
        try capture(controller.window, named: "translation-initial-toolbar")
        let pairs = try #require(elements.first { attribute("accessibilityIdentifier", of: $0) as? String == "pairsMenu" },
                                 "Frame: \(controller.window.frame); AX identifiers: \(elements.compactMap { attribute("accessibilityIdentifier", of: $0) as? String })")
        #expect((attribute("accessibilityLabel", of: pairs) as? String)?.isEmpty == false)
        #expect(!elements.contains { attribute("accessibilityIdentifier", of: $0) as? String == "pair-0" })
    }

    @Test(arguments: ["light", "dark"])
    func screenSwitcherGivesBothDestinationsEqualHitRegions(appearance: String) async throws {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let app = try await makeApp()
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        controller.window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        try capture(controller.window, named: "switcher-\(appearance)-initial")
        let picker = try element("screenPicker", in: controller.window)
        let segments = descendants(picker).filter { attribute("accessibilityRole", of: $0) as? String == "AXRadioButton" }
        let frames = segments.compactMap { (attribute("accessibilityFrame", of: $0) as? NSValue)?.rectValue }
        #expect(frames.count == 2, "Switcher roles: \(descendants(picker).compactMap { attribute("accessibilityRole", of: $0) })")
        if frames.count == 2 {
            #expect(abs(frames[0].width - frames[1].width) <= 1, "Both destinations need equal clickable widths, allowing pixel rounding: \(frames)")
            #expect(abs(frames[0].height - frames[1].height) < 1)
        }
        #expect(!controller.window.isKeyWindow)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
    }

    @Test func screenSwitcherRoutesAccessibleSelectionAndKeepsItInSync() async throws {
        let app = try await makeApp()
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        let window = controller.window
        defer { window.close() }
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(100))
        func selectedScreens() throws -> [Bool?] {
            descendants(try element("screenPicker", in: window))
                .filter { attribute("accessibilityRole", of: $0) as? String == "AXRadioButton" }
                .map { (attribute("isAccessibilitySelected", of: $0) as? NSNumber)?.boolValue }
        }
        #expect(try selectedScreens() == [true, false])
        let picker = try element("screenPicker", in: window)
        let segments = descendants(picker).filter { attribute("accessibilityRole", of: $0) as? String == "AXRadioButton" }
        #expect(segments.count == 2)
        let find = try #require(segments.last)
        #expect(try press(find))
        #expect(app.screen == .phraseFinder)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try selectedScreens() == [false, true])
        app.screen = .translation
        try await Task.sleep(for: .milliseconds(50))
        #expect(try selectedScreens() == [true, false])
        #expect(!window.isKeyWindow)
    }

    @Test func typingAndHistoryRestoreRemainSeparateNativeUndoSteps() async throws {
        let app = try await makeApp()
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let source = try #require(controller.registry.source)
        controller.window.makeFirstResponder(source)
        source.insertText("An unfinished draft", replacementRange: NSRange(location: 0, length: 0))
        source.breakUndoCoalescing()
        try await Task.sleep(for: .milliseconds(50))
        #expect(app.translator.sourceText == "An unfinished draft")
        app.translator.load(text: "Привет", source: .language("ru"), target: "nl", translation: "Hallo")
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.tryToPerform(Selector(("undo:")), with: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.string == "An unfinished draft")
        #expect(app.translator.sourceText == "An unfinished draft")
        #expect(app.translator.translation.isEmpty)
        #expect(source.tryToPerform(Selector(("undo:")), with: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.string.isEmpty)
        #expect(app.translator.sourceText.isEmpty)
    }

    @Test func restoringHistoryDismissesThePanelAndReturnsFocusWithoutLosingTheDraft() async throws {
        let app = try await makeApp()
        app.translator.sourceText = "unfinished draft"
        app.showHistory = true
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        app.restore(HistoryEntry(sourceText: "Привет", translation: "Goedendag", sourceLanguage: "ru",
                                 targetLanguage: "nl", tone: .formal))
        #expect(!app.showHistory)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.window.firstResponder === controller.registry.source)
        #expect(app.translator.tone == .formal)
        app.translator.undoManager.undo()
        #expect(app.translator.sourceText == "unfinished draft")
        #expect(app.translator.translation.isEmpty)
    }

    @Test(arguments: ["light", "dark"])
    func layoutsKeepEditorSpaceAndRestoreFocusAfterHistory(appearance: String) async throws {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let app = try await makeApp()
        app.settings.liveTranslation = true
        app.translator.load(text: "Не сумуй,\nусе буде добре.", source: .language("uk"), target: "nl",
                            translation: "Kop op,\nalles komt goed.")
        app.translator.undoManager.removeAllActions()
        try app.history?.record(HistoryCandidate(sourceText: "Дякую за допомогу.", translation: "Bedankt voor je hulp.",
                                                sourceLanguage: "uk", targetLanguage: "nl", tone: .auto))
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        controller.window.orderBack(nil)
        for width in [960, 720] {
            controller.window.setContentSize(NSSize(width: width, height: width == 720 ? 380 : 520))
            controller.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            #expect(controller.window.frame.height <= CGFloat(width == 720 ? 380 : 520))
            #expect(controller.window.frame.width <= CGFloat(width + 2))
            _ = try element("pairsMenu", in: controller.window)
            _ = try element("historyToggle", in: controller.window)
            let source = try #require(controller.registry.source)
            let readyWidth = source.frame.width
            #expect(readyWidth > 280)
            try capture(controller.window, named: "\(appearance)-\(width)-ready")
            app.showHistory = true
            try await Task.sleep(for: .milliseconds(150))
            if width == 720 {
                #expect(abs(source.frame.width - readyWidth) < 1)
                #expect(!source.acceptsFirstResponder)
            } else {
                #expect(source.frame.width < readyWidth)
                #expect(source.frame.width > 260)
            }
            let historyElements = descendants(controller.window)
            #expect(historyElements.contains { attribute("accessibilityIdentifier", of: $0) as? String == "historySearch" },
                    "AX identifiers: \(historyElements.compactMap { attribute("accessibilityIdentifier", of: $0) as? String })")
            try capture(controller.window, named: "\(appearance)-\(width)-history")
            app.showHistory = false
            try await Task.sleep(for: .milliseconds(150))
            #expect(controller.window.firstResponder === source)
        }
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
    }

    @Test func manualStreamingAndFailureStatesKeepTheirNativeActionsAndDrafts() async throws {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let provider = MockProvider { _ in .init(chunks: ["Kop op,", " alles komt goed."], chunkDelay: .milliseconds(500)) }
        let app = try await makeApp(provider: provider)
        app.translator.targetLanguage = "nl"
        app.translator.sourceText = "Не вешай нос, всё будет хорошо."
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.setContentSize(NSSize(width: 720, height: 380))
        controller.window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(100))
        _ = try element("translate", in: controller.window)
        try capture(controller.window, named: "light-720-manual")
        app.translator.translateNow()
        #expect(await eventually { app.translator.translation == "Kop op," })
        try await Task.sleep(for: .milliseconds(50))
        _ = try element("stop", in: controller.window)
        let copy = try element("copy", in: controller.window)
        #expect(attribute("isAccessibilityEnabled", of: copy) as? Bool == false)
        try capture(controller.window, named: "light-720-streaming")
        app.translator.stop()
        app.translator.provider = MockProvider { _ in .init(chunks: [], error: LLMError.http(status: 503, message: "offline")) }
        app.translator.translateNow()
        #expect(await eventually { app.translator.failure != nil })
        try await Task.sleep(for: .milliseconds(50))
        _ = try element("recover", in: controller.window)
        _ = try element("resultStatus", in: controller.window)
        #expect(app.translator.translation == "Kop op,")
        #expect(app.translator.sourceText == "Не вешай нос, всё будет хорошо.")
        try capture(controller.window, named: "light-720-connection-error")
        app.translator.provider = MockProvider { _ in .init(chunks: [], error: LLMError.unauthorized) }
        app.translator.retryLastFailure()
        #expect(await eventually { app.translator.failure?.requiresSignIn == true })
        try await Task.sleep(for: .milliseconds(50))
        let signIn = try element("recover", in: controller.window)
        #expect(attribute("accessibilityLabel", of: signIn) as? String == "Sign in")
        try capture(controller.window, named: "light-720-session-expired")
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
    }

    @Test func failedAdjustmentKeepsReplacementAndOffersBothRetryAndUndo() async throws {
        let app = try await makeApp(provider: MockProvider { _ in .init(chunks: [], error: LLMError.http(status: 503, message: "offline")) })
        app.translator.load(text: "Привет, мир!", source: .language("ru"), target: "nl", translation: "Hallo wereld!")
        app.translator.undoManager.removeAllActions()
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.setContentSize(NSSize(width: 720, height: 380))
        controller.window.orderBack(nil)
        app.translator.applySuggestion(.init(text: "Hoi", note: "", back: ""), range: NSRange(location: 0, length: 5))
        #expect(await eventually { app.translator.failure?.operation == .smoothing })
        try await Task.sleep(for: .milliseconds(100))
        let retry = try element("recover", in: controller.window)
        #expect(attribute("accessibilityLabel", of: retry) as? String == "Retry adjustment")
        _ = try element("undoEdit", in: controller.window)
        #expect(app.translator.translation == "Hoi wereld!")
        let status = try element("resultStatus", in: controller.window)
        #expect((attribute("accessibilityValue", of: status) as? String)?.contains("Replacement kept") == true)
        try capture(controller.window, named: "light-720-adjustment-error")
        let target = try #require(controller.registry.translation)
        #expect(target.tryToPerform(Selector(("undo:")), with: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(app.translator.translation == "Hallo wereld!")
        #expect(target.string == "Hallo wereld!")
    }

    @Test(arguments: ["light", "dark"])
    func phraseFinderHasItsOwnScreenAndScrollableNativeResults(appearance: String) async throws {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let provider = ControlledProvider()
        let app = try await makeApp(provider: provider)
        app.finder.query = "How do I say I’m very happy for someone?"
        app.finder.targetLanguage = "nl"
        app.screen = .phraseFinder
        app.finder.find()
        #expect(await eventually { provider.requests.count == 1 })
        provider.finish(0, text: #"{"suggestions":[{"text":"Wat fijn voor je!","note":"Warm and natural when something good happens to someone.","back":"How nice for you!"},{"text":"Ik ben zo blij voor je!","note":"Direct and heartfelt.","back":"I’m so happy for you!"},{"text":"Wat geweldig nieuws!","note":"Focuses on their good news.","back":"What wonderful news!"},{"text":"Ik ben heel blij voor u.","note":"A polite, more formal option.","back":"I’m very happy for you."}]}"#)
        #expect(await eventually { app.finder.result != nil })
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        controller.window.orderBack(nil)
        for width in [960, 720] {
            controller.window.setContentSize(NSSize(width: width, height: width == 720 ? 380 : 520))
            controller.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            _ = try element("screenPicker", in: controller.window)
            _ = try element("phraseDescription", in: controller.window)
            _ = try element("phraseTarget", in: controller.window)
            _ = try element("phraseTone", in: controller.window)
            _ = try element("phraseSearch", in: controller.window)
            _ = try element("phraseOption-0", in: controller.window)
            _ = try element("phraseCopy-0", in: controller.window)
            let identifiers = descendants(controller.window).compactMap { attribute("accessibilityIdentifier", of: $0) as? String }
            #expect(!identifiers.contains("pairsMenu"))
            #expect(!identifiers.contains("historyToggle"))
            #expect(!identifiers.contains("sourcePane"))
            #expect(controller.registry.source?.acceptsFirstResponder == false)
            #expect(controller.window.frame.width <= CGFloat(width + 2))
            #expect(controller.window.frame.height <= CGFloat(width == 720 ? 380 : 520))
            try capture(controller.window, named: "finder-\(appearance)-\(width)-results")
        }
        #expect(!controller.window.isKeyWindow)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
    }

    @Test func switchingScreensKeepsNativeTextSelectionAndIndependentUndoHistories() async throws {
        let app = try await makeApp()
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        let source = try #require(controller.registry.source)
        controller.window.makeFirstResponder(source)
        source.insertText("Translation draft", replacementRange: NSRange(location: 0, length: 0))
        source.breakUndoCoalescing()
        let selected = NSRange(location: 2, length: 5)
        source.setSelectedRange(selected)
        app.screen = .phraseFinder
        try await Task.sleep(for: .milliseconds(100))
        let description = try #require(descendants(controller.window).first { attribute("accessibilityIdentifier", of: $0) as? String == "phraseDescription" } as? PaneTextView)
        controller.window.makeFirstResponder(description)
        description.insertText("Finder draft", replacementRange: NSRange(location: 0, length: 0))
        description.breakUndoCoalescing()
        #expect(description.undoManager === app.finder.undoManager)
        #expect(controller.window.undoManager === app.finder.undoManager)
        app.screen = .translation
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.registry.source === source)
        #expect(source.selectedRange() == selected)
        #expect(controller.window.undoManager === app.translator.undoManager)
        app.screen = .phraseFinder
        try await Task.sleep(for: .milliseconds(100))
        #expect(description.string == "Finder draft")
        #expect(description.tryToPerform(Selector(("undo:")), with: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(app.finder.query.isEmpty)
        #expect(app.translator.sourceText == "Translation draft")
        app.screen = .translation
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.tryToPerform(Selector(("undo:")), with: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(app.translator.sourceText.isEmpty)
    }

    @Test func theReboundPrimaryShortcutSearchesFromTheNativeDescriptionEditor() async throws {
        let provider = ControlledProvider()
        let app = try await makeApp(provider: provider)
        app.settings.bindings[.translate] = KeyCombo("k", [.command, .option])
        app.screen = .phraseFinder
        app.finder.query = "How do I wish someone well?"
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        let delegate = AppDelegate(app: app)
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        delegate.buildMainMenu()
        let description = try #require(controller.finderRegistry.source)
        controller.window.makeFirstResponder(description)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: controller.window.windowNumber, context: nil,
                                                characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        #expect(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
        #expect(await eventually { provider.requests.count == 1 })
        #expect(app.finder.isSearching)
        #expect(app.translator.sourceText.isEmpty)
        app.finder.stop()
        #expect(!controller.window.isKeyWindow)
    }

    @Test func phraseFinderEmptySearchAndRecoveryStatesStayNativeAndPreserveTheDescription() async throws {
        let provider = ControlledProvider()
        let app = try await makeApp(provider: provider)
        app.screen = .phraseFinder
        let controller = MainWindowController(app: app, autosaveName: nil, openSettings: {})
        defer { controller.window.close() }
        controller.window.setContentSize(NSSize(width: 720, height: 380))
        controller.window.appearance = NSAppearance(named: .aqua)
        controller.window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = try element("phraseExample-happy", in: controller.window)
        let search = try element("phraseSearch", in: controller.window)
        #expect(attribute("isAccessibilityEnabled", of: search) as? Bool == false)
        try capture(controller.window, named: "finder-light-720-empty")
        app.finder.query = "How do I wish someone a good meal?"
        app.performPrimaryAction()
        #expect(await eventually { provider.requests.count == 1 })
        try await Task.sleep(for: .milliseconds(50))
        let stop = try element("phraseSearch", in: controller.window)
        #expect(attribute("accessibilityLabel", of: stop) as? String == "Stop")
        try capture(controller.window, named: "finder-light-720-searching")
        provider.finish(0, error: LLMError.http(status: 503, message: "offline"))
        #expect(await eventually { app.finder.failure != nil })
        try await Task.sleep(for: .milliseconds(50))
        let retry = try element("phraseSearch", in: controller.window)
        #expect(attribute("accessibilityLabel", of: retry) as? String == "Retry")
        #expect(app.finder.query == "How do I wish someone a good meal?")
        try capture(controller.window, named: "finder-light-720-connection-error")
        app.performPrimaryAction()
        #expect(await eventually { provider.requests.count == 2 })
        provider.finish(1, error: LLMError.unauthorized)
        #expect(await eventually { app.finder.failure?.requiresSignIn == true })
        try await Task.sleep(for: .milliseconds(50))
        let signIn = try element("phraseSearch", in: controller.window)
        #expect(attribute("accessibilityLabel", of: signIn) as? String == "Sign in")
        try capture(controller.window, named: "finder-light-720-session-expired")
    }

    @Test(arguments: ["light", "dark"])
    func aiSettingsRouteToAccountModelsAndLiveUsageWithoutInventingMissingCounts(appearance: String) async throws {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let usage = try UsageStore(inMemory: true)
        let app = try await makeApp(usage: usage)
        await app.auth.refreshStatus()
        let previousTab = SettingsTab.requested
        SettingsTab.requested = .general
        defer { SettingsTab.requested = previousTab }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Tolk Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView(app: app))
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        defer { window.close() }
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        let picker = try element("settingsTabs", in: window)
        let tabs = descendants(picker).filter { attribute("accessibilityRole", of: $0) as? String == "AXRadioButton" }
        #expect(tabs.count == 4)
        let frames = tabs.compactMap { (attribute("accessibilityFrame", of: $0) as? NSValue)?.rectValue }
        #expect(frames.count == 4)
        #expect(frames.allSatisfy { $0.width > 60 && $0.height >= 24 })
        #expect(try press(#require(tabs.last)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(try press(#require(tabs.first)))
        try await Task.sleep(for: .milliseconds(50))
        NotificationCenter.default.post(name: .selectSettingsTab, object: SettingsTab.ai)
        try await Task.sleep(for: .milliseconds(150))
        let labels = descendants(window).compactMap { attribute("accessibilityLabel", of: $0) as? String }
        #expect(labels.contains("Sign in with ChatGPT…"))
        #expect(labels.contains("Live translation"))
        #expect(labels.contains("Phrase suggestions"))
        try capture(window, named: "ai-\(appearance)-account-models")
        try scrollToBottom(window)
        try await Task.sleep(for: .milliseconds(100))
        _ = try element("usage-empty", in: window)
        #expect(!descendants(window).contains { attribute("accessibilityIdentifier", of: $0) as? String == "usage-total" })
        usage.record(UsageObservation(model: "gpt-5.6-luna", report: .notReported))
        try await Task.sleep(for: .milliseconds(100))
        try scrollToBottom(window)
        try await Task.sleep(for: .milliseconds(100))
        _ = try element("usage-empty", in: window)
        let missing = try element("usage-unreported", in: window)
        #expect((attribute("accessibilityValue", of: missing) as? String)?.contains("1") == true)
        usage.record(UsageObservation(model: "gpt-5.6-luna", report: .reported(try TokenUsage(inputTokens: 100, outputTokens: 25, cachedInputTokens: 40, reasoningOutputTokens: 10))))
        usage.record(UsageObservation(model: "gpt-5.4-mini", report: .reported(try TokenUsage(inputTokens: 10, outputTokens: 5))))
        try await Task.sleep(for: .milliseconds(150))
        try scrollToBottom(window)
        try await Task.sleep(for: .milliseconds(100))
        let total = try element("usage-total", in: window)
        #expect(attribute("accessibilityValue", of: total) as? String == "140")
        let input = try element("usage-input", in: window)
        #expect(attribute("accessibilityValue", of: input) as? String == "110")
        let output = try element("usage-output", in: window)
        #expect(attribute("accessibilityValue", of: output) as? String == "30")
        let cached = try element("usage-cached", in: window)
        #expect((attribute("accessibilityValue", of: cached) as? String)?.contains("partial") == true)
        let modelCached = try element("usage-model-gpt-5.6-luna-cached", in: window)
        #expect((attribute("accessibilityValue", of: modelCached) as? String)?.contains("40") == true)
        let modelReasoning = try element("usage-model-gpt-5.6-luna-reasoning", in: window)
        #expect((attribute("accessibilityValue", of: modelReasoning) as? String)?.contains("10") == true)
        try capture(window, named: "ai-\(appearance)-usage")
        #expect(!window.isKeyWindow)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
    }

    private func makeAlternativesApp() async throws -> (AppState, ControlledProvider) {
        let provider = ControlledProvider()
        let app = try await makeApp(provider: provider)
        app.translator.load(text: "Усе заспокоїлося.", source: .language("uk"), target: "en",
                            translation: "Everything has calmed down.")
        app.translator.requestSuggestions(pane: .translation, selection: "Everything has calmed down.")
        try #require(await eventually { provider.requests.count == 1 })
        provider.finish(0, text: #"{"suggestions":[{"text":"Things have settled down.","note":"Нейтрально.","back":"Усе вляглося."},{"text":"Everything is back to normal.","note":"Розмовний вислів про повернення до звичного стану.","back":"Усе повернулося до норми."}]}"#)
        try #require(await eventually { if case .loaded = app.translator.suggestions { true } else { false } })
        return (app, provider)
    }

    @Test(arguments: ["light", "dark"])
    func refreshingOneAlternativeDoesNotPickItAndKeepsAnAccessibleRetry(appearance: String) async throws {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let (app, provider) = try await makeAlternativesApp()
        var picked: PhraseSuggestion?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 350),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Alternatives"
        window.contentViewController = NSHostingController(rootView: SuggestionsView(
            translator: app.translator, onPick: { picked = $0 }, onClose: {}))
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        defer { app.translator.dismissSuggestions(); window.close() }
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(150))
        let refresh = try element("suggestion-refresh-1", in: window)
        #expect(attribute("accessibilityLabel", of: refresh) as? String == "Another like this")
        let frame = try #require(attribute("accessibilityFrame", of: refresh) as? NSValue).rectValue
        #expect(frame.width >= 24 && frame.height >= 24, "Small glyphs must retain a usable target")
        #expect(try press(refresh))
        try #require(await eventually { provider.requests.count == 2 })
        #expect(app.translator.suggestionRefreshStates[1] == .loading)
        #expect(picked == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(attribute("isAccessibilityEnabled", of: try element("suggestion-refresh-1", in: window)) as? Bool == false)
        try capture(window, named: "alternatives-\(appearance)-refreshing")
        provider.finish(1, error: LLMError.http(status: 503, message: "Temporarily unavailable"))
        try #require(await eventually { if case .failed = app.translator.suggestionRefreshStates[1] { true } else { false } })
        try await Task.sleep(for: .milliseconds(100))
        try capture(window, named: "alternatives-\(appearance)-retry")
        #expect(try press(element("suggestion-refresh-1", in: window)))
        try #require(await eventually { provider.requests.count == 3 })
        provider.finish(2, text: #"{"suggestions":[{"text":"Things are normal again.","note":"Розмовний, нейтральний вислів.","back":"Усе знову нормально."}]}"#)
        try #require(await eventually { app.translator.suggestionRefreshStates.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(picked == nil)
        #expect(app.translator.translation == "Everything has calmed down.")
        #expect(try press(element("suggestion-1", in: window)))
        #expect(picked?.text == "Things are normal again.")
        app.translator.requestSuggestions(pane: .source, selection: "Усе заспокоїлося.")
        try #require(await eventually { provider.requests.count == 4 })
        provider.finish(3, text: #"{"suggestions":[{"text":"Things have settled down.","note":"Нейтрально.","back":"Усе вляглося."}]}"#)
        try #require(await eventually { if case .loaded = app.translator.suggestions { true } else { false } })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!descendants(window).contains { (attribute("accessibilityIdentifier", of: $0) as? String)?.hasPrefix("suggestion-refresh-") == true })
        #expect(!window.isKeyWindow)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
    }

    @Test func closingALoadedPopoverCancelsItsPendingRowRefresh() async throws {
        let (app, provider) = try await makeAlternativesApp()
        let presenter = SuggestionPresenter(translator: app.translator)
        app.translator.refreshSuggestion(at: 1)
        try #require(await eventually { provider.requests.count == 2 })
        presenter.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        #expect(app.translator.suggestions == .idle)
        #expect(app.translator.suggestionRefreshStates.isEmpty)
        provider.finish(1, text: #"{"suggestions":[]}"#)
    }

    private func press(_ element: NSObject) throws -> Bool {
        let action = NSSelectorFromString("accessibilityPerformPress")
        try #require(element.responds(to: action))
        // SwiftUI exposes this BOOL action without declaring the accessibility protocol.
        // NSObject.perform expects an object return and would use the wrong signature.
        typealias Press = @convention(c) (NSObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: action), to: Press.self)(element, action)
    }

    private func scrollToBottom(_ window: NSWindow) throws {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let root = try #require(window.contentView)
        let scroll = try #require(views(root).compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height
        })
        let document = try #require(scroll.documentView)
        let y = document.isFlipped ? max(0, document.frame.height - scroll.contentView.bounds.height) : 0
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func element(_ identifier: String, in window: NSWindow) throws -> NSObject {
        try #require(descendants(window).first { attribute("accessibilityIdentifier", of: $0) as? String == identifier },
                     "Missing accessible control: \(identifier)")
    }

    private func capture(_ window: NSWindow, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TOLK_UI_EVIDENCE_DIR"] else { return }
        _ = try #require(CGPreflightScreenCaptureAccess(), "Screen recording is unavailable; never prompt during background checks")
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.appendingPathComponent("\(name).png").path]
        try capture.run()
        capture.waitUntilExit()
        #expect(capture.terminationStatus == 0)
        #expect(!window.isKeyWindow)
    }

    private func descendants(_ root: NSObject) -> [NSObject] {
        [root] + ((attribute("accessibilityChildren", of: root) as? [NSObject]) ?? []).flatMap(descendants)
    }

    // AppKit's private SwiftUI accessibility elements implement the getters without declaring the full protocol.
    private func attribute(_ name: String, of element: NSObject) -> Any? {
        guard element.responds(to: NSSelectorFromString(name)) else { return nil }
        return element.value(forKey: name)
    }
}
