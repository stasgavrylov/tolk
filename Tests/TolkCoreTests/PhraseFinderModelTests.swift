import Foundation
import Testing
import TolkTestSupport
@testable import TolkCore

@MainActor @Suite struct PhraseFinderModelTests {
    private let response = #"{"suggestions":[{"text":"Eet smakelijk!","note":"The usual wish before a meal.","back":"Enjoy your meal!"},{"text":"eet smakelijk!","note":"duplicate","back":"duplicate"},{"text":"Geniet van je maaltijd!","note":"More personal.","back":"Enjoy your meal!"}]}"#

    @Test func descriptionAndPreferencesNeverSearchUntilRequested() async throws {
        let provider = MockProvider { _ in .init(chunks: []) }
        let model = PhraseFinderModel(settings: makeSettings(), provider: provider)
        model.query = "How do I wish someone a good meal?"
        model.targetLanguage = "nl"
        model.tone = .formal
        try await Task.sleep(for: .milliseconds(80))
        #expect(provider.requests.isEmpty)
        #expect(!model.isSearching)
        #expect(model.result == nil)
        #expect(model.canSearch)
    }

    @Test func explicitSearchUsesSuggestionsSettingsAndKeepsTheChosenTarget() async throws {
        let provider = ControlledProvider()
        let settings = makeSettings()
        settings.suggestionsModel = ModelChoice(model: "test-suggestions", effort: "medium")
        let model = PhraseFinderModel(settings: settings, provider: provider)
        model.query = "  How do I wish someone a good meal?  "
        model.targetLanguage = "en" // Same language as the description: never use translation pair resolution.
        model.tone = .formal
        model.find()
        #expect(model.isSearching)
        #expect(await eventually { provider.requests.count == 1 })
        let request = try #require(provider.requests.first)
        #expect(request.input == "How do I wish someone a good meal?")
        #expect(request.model == ModelChoice(model: "test-suggestions", effort: "medium"))
        #expect(request.format?.name == "suggestions")
        #expect(request.instructions.contains("English"))
        #expect(request.instructions.contains("formal, polite"))
        provider.finish(0, text: #"{"suggestions":[{"text":"Enjoy your meal!","note":"The usual wish before a meal.","back":"Enjoy your meal!"}]}"#)
        #expect(await eventually { !model.isSearching })
        #expect(model.targetLanguage == "en")
        #expect(model.result?.items.map(\.text) == ["Enjoy your meal!"])
        #expect(model.resultIsCurrent)
    }

    @Test func completedSearchParsesOptionsAndKeepsTheirRequestContext() async {
        let response = response
        let provider = MockProvider { _ in .init(chunks: [response]) }
        let model = PhraseFinderModel(settings: makeSettings(), provider: provider)
        model.query = "How do I wish someone a good meal?"
        model.targetLanguage = "nl"
        model.find()
        #expect(await eventually { model.result != nil })
        #expect(model.result?.items.map(\.text) == ["Eet smakelijk!", "Geniet van je maaltijd!"])
        #expect(model.result?.query == "How do I wish someone a good meal?")
        #expect(model.result?.targetLanguage == "nl")
        #expect(model.result?.tone == .auto)
        model.query = "How do I wish someone well?"
        model.targetLanguage = "en"
        model.tone = .formal
        #expect(!model.resultIsCurrent)
        #expect(model.result?.targetLanguage == "nl")
        #expect(model.result?.items.first?.text == "Eet smakelijk!")
        #expect(provider.requests.count == 1)
    }

    @Test(arguments: ["", " \n\t "])
    func blankDescriptionsCannotStartARequest(query: String) {
        let provider = MockProvider()
        let model = PhraseFinderModel(settings: makeSettings(), provider: provider)
        model.query = query
        model.find()
        #expect(!model.canSearch)
        #expect(!model.isSearching)
        #expect(model.result == nil)
        #expect(provider.requests.isEmpty)
    }

    @Test func aNewerSearchCannotBeOverwrittenByACancelledSearchEpilogue() async {
        let provider = ControlledProvider()
        let model = PhraseFinderModel(settings: makeSettings(), provider: provider)
        model.query = "First description"
        model.find()
        #expect(await eventually { provider.requests.count == 1 })
        model.query = "Second description"
        model.find()
        #expect(await eventually { provider.requests.count == 2 })
        provider.finish(0, text: #"{"suggestions":[]}"#)
        #expect(model.isSearching)
        provider.finish(1, text: response)
        #expect(await eventually { !model.isSearching })
        #expect(model.result?.query == "Second description")
        #expect(model.result?.items.first?.text == "Eet smakelijk!")
    }

    @Test func stopKeepsPreviousOptionsAndPreventsLateCompletion() async {
        let provider = ControlledProvider()
        let model = PhraseFinderModel(settings: makeSettings(), provider: provider)
        model.query = "First description"
        model.find()
        #expect(await eventually { provider.requests.count == 1 })
        provider.finish(0, text: response)
        #expect(await eventually { model.result != nil })
        model.query = "Second description"
        model.find()
        #expect(await eventually { provider.requests.count == 2 })
        model.stop()
        provider.finish(1, text: #"{"suggestions":[]}"#)
        await Task.yield()
        #expect(!model.isSearching)
        #expect(model.isStopped)
        #expect(model.result?.query == "First description")
        #expect(!model.resultIsCurrent)
        #expect(model.failure == nil)
    }

    @Test func changingAnyInputCancelsAnInFlightSearchWithoutStartingAnother() async {
        for field in ["description", "target", "tone"] {
            let provider = ControlledProvider()
            let model = PhraseFinderModel(settings: makeSettings(), provider: provider)
            model.query = "How do I wish someone a good meal?"
            model.targetLanguage = "nl"
            model.find()
            #expect(await eventually { provider.requests.count == 1 })
            switch field {
            case "description": model.query = "A different situation"
            case "target": model.targetLanguage = "en"
            default: model.tone = .formal
            }
            provider.finish(0, text: response)
            await Task.yield()
            #expect(!model.isSearching)
            #expect(model.result == nil)
            #expect(provider.requests.count == 1)
        }
    }

    @Test func failuresKeepOptionsAndAllowAnExplicitRetry() async {
        let provider = ControlledProvider()
        let model = PhraseFinderModel(settings: makeSettings(), provider: provider)
        model.query = "How do I wish someone a good meal?"
        model.find()
        #expect(await eventually { provider.requests.count == 1 })
        provider.finish(0, text: response)
        #expect(await eventually { model.result != nil })
        model.find()
        #expect(await eventually { provider.requests.count == 2 })
        provider.finish(1, error: LLMError.http(status: 503, message: "offline"))
        #expect(await eventually { model.failure != nil })
        #expect(model.result?.items.first?.text == "Eet smakelijk!")
        #expect(model.failure?.requiresSignIn == false)
        #expect(!model.resultIsCurrent)
        model.find()
        #expect(await eventually { provider.requests.count == 3 })
        provider.finish(2, text: response)
        #expect(await eventually { model.resultIsCurrent })
        #expect(model.failure == nil)
    }

    @Test(arguments: [LLMError.notSignedIn, .unauthorized])
    func authenticationFailuresNeedSignIn(error: LLMError) async {
        let provider = MockProvider { _ in .init(chunks: [], error: error) }
        let model = PhraseFinderModel(settings: makeSettings(), provider: provider)
        model.query = "How do I wish someone a good meal?"
        model.find()
        #expect(await eventually { model.failure != nil })
        #expect(model.failure?.requiresSignIn == true)
        #expect(model.query == "How do I wish someone a good meal?")
    }

    @Test func malformedOutputIsAnErrorButAnEmptyListIsAValidResult() async {
        let provider = ControlledProvider()
        let model = PhraseFinderModel(settings: makeSettings(), provider: provider)
        model.query = "An unusual situation"
        model.find()
        #expect(await eventually { provider.requests.count == 1 })
        provider.finish(0, text: #"{"suggestions":[{"text":"Missing required fields"}]}"#)
        #expect(await eventually { model.failure != nil })
        #expect(model.result == nil)
        model.find()
        #expect(await eventually { provider.requests.count == 2 })
        provider.finish(1, text: #"{"suggestions":[]}"#)
        #expect(await eventually { model.result != nil })
        #expect(model.result?.items.isEmpty == true)
        #expect(model.failure == nil)
        #expect(model.resultIsCurrent)
    }

    @Test func finderPreferencesDoNotMutateTranslationSettings() {
        let settings = makeSettings()
        settings.lastTarget = "nl"
        settings.setTone(.formal, for: "nl")
        let model = PhraseFinderModel(settings: settings, provider: MockProvider())
        model.targetLanguage = "en"
        model.tone = .informal
        #expect(settings.lastTarget == "nl")
        #expect(settings.tone(for: "nl") == .formal)
        #expect(settings.tone(for: "en") == .auto)
    }
}
