import AppKit
import Testing
import TolkCore
import TolkTestSupport
@testable import Tolk

@MainActor @Suite struct PhraseFinderCommandTests {
    private func makeApp(provider: any LLMProvider, pasteboard: NSPasteboard = .general) throws -> AppState {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "tolk-finder-command-tests-\(UUID().uuidString)")!)
        settings.liveTranslation = false
        return AppState(settings: settings, auth: AuthController(manager: AuthManager(store: InMemoryCredentialStore())),
                        provider: provider, history: try HistoryStore(inMemory: true), pasteboard: pasteboard)
    }

    @Test func theExistingPrimaryCommandSearchesTheActiveScreenWithoutTouchingTheTranslation() async throws {
        let provider = ControlledProvider()
        let app = try makeApp(provider: provider)
        app.translator.load(text: "Привет", source: .language("ru"), target: "nl", translation: "Hallo")
        app.finder.query = "How do I wish someone a good meal?"
        app.finder.targetLanguage = "en"
        app.screen = .phraseFinder
        let delegate = AppDelegate(app: app)
        let action = NSMenuItem()
        action.representedObject = InAppAction.translate.rawValue
        delegate.performInAppAction(action)
        #expect(await eventually { provider.requests.count == 1 })
        #expect(provider.requests.first?.input == "How do I wish someone a good meal?")
        #expect(app.finder.isSearching)
        #expect(!app.translator.isTranslating)
        #expect(app.translator.sourceText == "Привет")
        #expect(app.translator.translation == "Hallo")
        #expect(app.translator.targetLanguage == "nl")
        provider.finish(0, text: #"{"suggestions":[{"text":"Enjoy your meal!","note":"Before eating.","back":"Enjoy your meal!"}]}"#)
        #expect(await eventually { app.finder.result != nil })
        app.screen = .translation
        app.screen = .phraseFinder
        #expect(app.finder.result?.items.first?.text == "Enjoy your meal!")
        #expect(app.finder.query == "How do I wish someone a good meal?")
        #expect(try app.history?.entries().isEmpty == true)
    }

    @Test func translationOnlyCommandsAreDisabledAndCannotMutateAHiddenDraft() throws {
        let provider = MockProvider()
        let app = try makeApp(provider: provider)
        app.translator.load(text: "Привет", source: .language("ru"), target: "nl", translation: "Hallo")
        app.screen = .phraseFinder
        let delegate = AppDelegate(app: app)
        for action in [InAppAction.swap, .suggestions, .copyTranslation] + InAppAction.pairs {
            let item = NSMenuItem()
            item.representedObject = action.rawValue
            #expect(!delegate.validateMenuItem(item))
            delegate.performInAppAction(item)
        }
        #expect(provider.requests.isEmpty)
        #expect(app.translator.sourceText == "Привет")
        #expect(app.translator.translation == "Hallo")
        #expect(app.translator.sourceLanguage == "ru")
        #expect(app.translator.targetLanguage == "nl")
    }

    @Test func openingHistoryNavigatesToTranslationAndRestoringKeepsTheFinderDraft() throws {
        let app = try makeApp(provider: MockProvider())
        app.finder.query = "An unfinished description"
        app.screen = .phraseFinder
        let delegate = AppDelegate(app: app)
        delegate.perform(.history)
        #expect(app.screen == .translation)
        #expect(app.showHistory)
        app.screen = .phraseFinder
        #expect(!app.showHistory)
        app.restore(HistoryEntry(sourceText: "Привет", translation: "Hallo", sourceLanguage: "ru", targetLanguage: "nl", tone: .formal))
        #expect(app.screen == .translation)
        #expect(!app.showHistory)
        #expect(app.translator.translation == "Hallo")
        #expect(app.finder.query == "An unfinished description")
    }

    @Test func externalTranslationsNavigateToTheirScreenWithoutLosingTheFinder() throws {
        let app = try makeApp(provider: MockProvider())
        app.finder.query = "An unfinished description"
        app.screen = .phraseFinder
        app.loadTranslation(text: "Привет", source: .language("ru"), target: "nl", translation: "Hallo")
        #expect(app.screen == .translation)
        #expect(app.translator.translation == "Hallo")
        #expect(app.finder.query == "An unfinished description")
    }

    @Test func thePrimaryCommandReflectsSearchStopAndSignInStates() async throws {
        let provider = ControlledProvider()
        let app = try makeApp(provider: provider)
        app.screen = .phraseFinder
        let delegate = AppDelegate(app: app)
        let item = NSMenuItem()
        item.representedObject = InAppAction.translate.rawValue
        #expect(!delegate.validateMenuItem(item))
        app.finder.query = "How do I wish someone well?"
        #expect(delegate.validateMenuItem(item))
        #expect(item.title == "Find phrases")
        delegate.performInAppAction(item)
        #expect(await eventually { provider.requests.count == 1 })
        #expect(delegate.validateMenuItem(item))
        #expect(item.title == "Stop search")
        delegate.performInAppAction(item)
        #expect(app.finder.isStopped)
        #expect(!app.finder.isSearching)
        app.performPrimaryAction()
        #expect(await eventually { provider.requests.count == 2 })
        provider.finish(1, error: LLMError.unauthorized)
        #expect(await eventually { app.finder.failure != nil })
        #expect(delegate.validateMenuItem(item))
        #expect(item.title == "Sign in…")
        #expect(app.primaryActionRequiresSignIn)
    }

    @Test func completingSignInClearsAuthenticationFailuresWithoutAutomaticallySendingDescriptions() async throws {
        let provider = ControlledProvider()
        let app = try makeApp(provider: provider)
        app.translator.sourceText = "hello"
        app.translator.translateNow()
        app.finder.query = "How do I wish someone well?"
        app.finder.find()
        #expect(await eventually { provider.requests.count == 2 })
        provider.finish(0, error: LLMError.unauthorized)
        provider.finish(1, error: LLMError.notSignedIn)
        #expect(await eventually { app.translator.failure != nil && app.finder.failure != nil })
        app.screen = .phraseFinder
        #expect(app.primaryActionRequiresSignIn)
        app.auth.onSignedIn()
        #expect(app.finder.failure == nil)
        #expect(app.translator.failure == nil)
        #expect(!app.primaryActionRequiresSignIn)
        #expect(app.primaryActionTitle == "Find phrases")
        #expect(provider.requests.count == 2)
        #expect(app.finder.query == "How do I wish someone well?")
        app.performPrimaryAction()
        #expect(await eventually { provider.requests.count == 3 })
        app.finder.stop()
    }

    @Test func copyUsesTheChosenPhraseNotTheQuestionOrHiddenTranslation() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let provider = ControlledProvider()
        let app = try makeApp(provider: provider, pasteboard: pasteboard)
        app.translator.load(text: "Привет", translation: "Hallo")
        app.screen = .phraseFinder
        app.finder.query = "How do I wish someone a good meal?"
        app.finder.find()
        #expect(await eventually { provider.requests.count == 1 })
        provider.finish(0, text: #"{"suggestions":[{"text":"Eet smakelijk!","note":"Before eating.","back":"Enjoy your meal!"}]}"#)
        #expect(await eventually { app.finder.result != nil })
        let phrase = try #require(app.finder.result?.items.first)
        #expect(app.copyPhrase(phrase))
        #expect(pasteboard.string(forType: .string) == "Eet smakelijk!")
        app.copyTranslation()
        #expect(pasteboard.string(forType: .string) == "Eet smakelijk!")
        #expect(!app.copyPhrase(PhraseSuggestion(text: "Not a suggestion", note: "", back: "")))
        #expect(pasteboard.string(forType: .string) == "Eet smakelijk!")
    }
}
