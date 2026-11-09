import Foundation
import Testing
import TolkTestSupport
@testable import TolkCore

@MainActor @Suite struct SuggestionRefreshTests {
    private let initial = #"{"suggestions":[{"text":"Things have settled down.","note":"Нейтрально.","back":"Усе вляглося."},{"text":"Everything is back to normal.","note":"Розмовний вислів про повернення до звичного стану.","back":"Усе повернулося до норми."},{"text":"The dust has settled.","note":"Ідіома після суперечки або змін.","back":"Пил осів."}]}"#
    private let replacement = #"{"suggestions":[{"text":"Things are normal again.","note":"Розмовний, нейтральний вислів.","back":"Усе знову нормально."}]}"#

    private func loaded() async throws -> (TranslatorModel, ControlledProvider) {
        let provider = ControlledProvider()
        let model = TranslatorModel(settings: makeSettings(), provider: provider)
        model.settings.liveTranslation = false
        model.load(text: "Усе заспокоїлося.", source: .language("uk"), target: "en",
                   translation: "Everything has calmed down.")
        model.requestSuggestions(pane: .translation, selection: "Everything has calmed down.")
        try #require(await eventually { provider.requests.count == 1 })
        provider.finish(0, text: initial)
        try #require(await eventually { if case .loaded = model.suggestions { true } else { false } })
        return (model, provider)
    }

    private func items(_ model: TranslatorModel) throws -> [PhraseSuggestion] {
        guard case .loaded(_, _, let items) = model.suggestions else {
            throw LLMError.invalidResponse("Expected the existing suggestions to stay loaded")
        }
        return items
    }

    @Test func refreshChangesOnlyOneSuggestionWithoutApplyingIt() async throws {
        let (model, provider) = try await loaded()
        let before = try items(model)
        model.refreshSuggestion(at: 1)
        #expect(model.suggestionRefreshStates == [1: .loading])
        #expect(try items(model) == before)
        try #require(await eventually { provider.requests.count == 2 })
        let request = provider.requests[1]
        #expect(request.model == model.settings.suggestionsModel)
        #expect(request.format?.name == "similar_alternative")
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(request.input.utf8))
        #expect(input["original"]?["text"]?.stringValue == "Everything is back to normal.")
        #expect(input["original"]?["note"]?.stringValue == "Розмовний вислів про повернення до звичного стану.")
        #expect(input["selection"]?.stringValue == "Everything has calmed down.")
        #expect(request.instructions.contains("idiomatic"))
        #expect(request.instructions.contains("Ukrainian"))
        provider.finish(1, text: replacement)
        try #require(await eventually { model.suggestionRefreshStates.isEmpty })
        let after = try items(model)
        #expect(after.count == 3)
        #expect(after[0] == before[0])
        #expect(after[2] == before[2])
        #expect(after[1] == PhraseSuggestion(text: "Things are normal again.", note: "Розмовний, нейтральний вислів.", back: "Усе знову нормально."))
        #expect(model.translation == "Everything has calmed down.")
        #expect(model.sourceText == "Усе заспокоїлося.")
        #expect(!model.isSmoothing)
    }

    @Test func repeatedRefreshKeepsTheOriginalStyleAnchorAndRejectsPreviousWording() async throws {
        let (model, provider) = try await loaded()
        model.refreshSuggestion(at: 1)
        try #require(await eventually { provider.requests.count == 2 })
        provider.finish(1, text: replacement)
        try #require(await eventually { model.suggestionRefreshStates.isEmpty })
        model.refreshSuggestion(at: 1)
        try #require(await eventually { provider.requests.count == 3 })
        let input = try JSONDecoder().decode(JSONValue.self, from: Data(provider.requests[2].input.utf8))
        #expect(input["original"]?["text"]?.stringValue == "Everything is back to normal.")
        guard case .array(let excluded) = input["excluded"] else {
            Issue.record("The request must exclude previously shown alternatives")
            return
        }
        #expect(excluded.contains(.string("Things are normal again.")))
        #expect(excluded.contains(.string("Everything is back to normal.")))
        provider.finish(2, text: #"{"suggestions":[{"text":" EVERYTHING IS BACK TO NORMAL. ","note":"new note","back":"new back"}]}"#)
        try #require(await eventually { if case .failed = model.suggestionRefreshStates[1] { true } else { false } })
        #expect(try items(model)[1].text == "Things are normal again.")
    }

    @Test func simultaneousRowsCannotIntroduceTheSameAlternative() async throws {
        let (model, provider) = try await loaded()
        model.refreshSuggestion(at: 0)
        try #require(await eventually { provider.requests.count == 2 })
        model.refreshSuggestion(at: 1)
        model.refreshSuggestion(at: 1) // Double clicks must not create another request.
        try #require(await eventually { provider.requests.count == 3 })
        provider.finish(1, text: replacement)
        try #require(await eventually { model.suggestionRefreshStates[0] == nil })
        provider.finish(2, text: replacement)
        try #require(await eventually { if case .failed = model.suggestionRefreshStates[1] { true } else { false } })
        #expect(try items(model).map(\.text) == ["Things are normal again.", "Everything is back to normal.", "The dust has settled."])
        #expect(provider.requests.count == 3)
    }

    @Test(arguments: [#"{"suggestions":[]}"#, #"{"suggestions":[{"text":"The dust has settled.","note":"n","back":"b"}]}"#, #"{"suggestions":[{"text":" The dust has settled! ","note":"n","back":"b"}]}"#, #"{"suggestions":[{"text":"The dust has set-tled.","note":"n","back":"b"}]}"#, #"{"suggestions":[{"text":"Things are normal again.","note":"n","back":"b"},{"text":"It is peaceful again.","note":"n","back":"b"}]}"#, "not JSON"])
    func failedOrUnusableRepliesKeepTheOldOptionAndAllowRetry(reply: String) async throws {
        let (model, provider) = try await loaded()
        let before = try items(model)
        model.refreshSuggestion(at: 1)
        try #require(await eventually { provider.requests.count == 2 })
        provider.finish(1, text: reply)
        try #require(await eventually { if case .failed = model.suggestionRefreshStates[1] { true } else { false } })
        #expect(try items(model) == before)
        model.refreshSuggestion(at: 1)
        try #require(await eventually { provider.requests.count == 3 })
        provider.finish(2, text: replacement)
        try #require(await eventually { model.suggestionRefreshStates.isEmpty })
        #expect(try items(model)[1].text == "Things are normal again.")
    }

    @Test(arguments: [
        ("Don't worry.", "Dont worry."),
        ("Things feel worry-free again.", "Things feel worryfree again."),
        ("Things feel worryfree again.", "Things feel worry-free again."),
        ("It is calm again.", "ITISCALMAGAIN!"),
        ("I'm at ease.", " I’m \tAT EASE!!! "),
        ("Draußen ist es ruhig.", "DRAUSSEN IST ES RUHIG.")
    ], ["previous", "concurrent"])
    func surfaceOnlyVariantsAreRejectedAgainstHistoryAndConcurrentRows(wording: (String, String), scenario: String) async throws {
        let (model, provider) = try await loaded()
        let before = try items(model)
        let row = scenario == "previous" ? 0 : 1
        model.refreshSuggestion(at: 0)
        try #require(await eventually { provider.requests.count == 2 })
        if scenario == "concurrent" {
            model.refreshSuggestion(at: row)
            try #require(await eventually { provider.requests.count == 3 })
        }
        let first: JSONValue = ["suggestions": [["text": .string(wording.0), "note": "Usage note", "back": "Back-translation"]]]
        provider.finish(1, text: String(decoding: try JSONEncoder().encode(first), as: UTF8.self))
        try #require(await eventually { model.suggestionRefreshStates[0] == nil })
        #expect(try items(model)[0].text == wording.0)
        if scenario == "previous" {
            model.refreshSuggestion(at: row)
            try #require(await eventually { provider.requests.count == 3 })
            let input = try JSONDecoder().decode(JSONValue.self, from: Data(provider.requests[2].input.utf8))
            guard case .array(let excluded) = input["excluded"] else {
                Issue.record("History must reach the prompt as readable, original wording")
                return
            }
            #expect(excluded.contains(.string(wording.0)))
        }
        let duplicate: JSONValue = ["suggestions": [["text": .string(wording.1), "note": "Usage note", "back": "Back-translation"]]]
        provider.finish(2, text: String(decoding: try JSONEncoder().encode(duplicate), as: UTF8.self))
        try #require(await eventually { if case .failed = model.suggestionRefreshStates[row] { true } else { false } })
        #expect(try items(model)[0].text == wording.0)
        #expect(try items(model)[1] == before[1])
        #expect(try items(model)[2] == before[2])
        #expect(model.translation == "Everything has calmed down.")
        model.refreshSuggestion(at: row)
        try #require(await eventually { provider.requests.count == 4 })
        provider.finish(3, text: replacement)
        try #require(await eventually { model.suggestionRefreshStates.isEmpty })
        #expect(try items(model)[row].text == "Things are normal again.")
    }

    @Test(arguments: [("", "back"), (" \t\n", "back"), ("note", ""), ("note", " \t\n"), ("", "")])
    func blankMetadataPreservesTheOldOptionAndDoesNotReserveTheCandidate(metadata: (String, String)) async throws {
        let (model, provider) = try await loaded()
        let before = try items(model)
        model.refreshSuggestion(at: 1)
        try #require(await eventually { provider.requests.count == 2 })
        let reply: JSONValue = ["suggestions": [["text": "Things are normal again.",
                                               "note": .string(metadata.0), "back": .string(metadata.1)]]]
        provider.finish(1, text: String(decoding: try JSONEncoder().encode(reply), as: UTF8.self))
        try #require(await eventually { if case .failed = model.suggestionRefreshStates[1] { true } else { false } })
        #expect(try items(model) == before)
        #expect(model.translation == "Everything has calmed down.")
        model.refreshSuggestion(at: 1)
        try #require(await eventually { provider.requests.count == 3 })
        provider.finish(2, text: replacement)
        try #require(await eventually { model.suggestionRefreshStates.isEmpty })
        #expect(try items(model)[1].text == "Things are normal again.")
    }

    @Test func authenticationFailureStaysLocalAndExplainsSignIn() async throws {
        let (model, provider) = try await loaded()
        let before = try items(model)
        model.refreshSuggestion(at: 1)
        try #require(await eventually { provider.requests.count == 2 })
        provider.finish(1, error: LLMError.unauthorized)
        try #require(await eventually { if case .failed = model.suggestionRefreshStates[1] { true } else { false } })
        if case .failed(let message) = model.suggestionRefreshStates[1] { #expect(message.contains("Sign in")) }
        #expect(try items(model) == before)
        #expect(model.failure == nil)
    }

    @Test(arguments: ["dismiss", "source", "translation", "language", "tone", "translate"])
    func contextChangesDiscardPendingRefreshes(change: String) async throws {
        let (model, provider) = try await loaded()
        model.refreshSuggestion(at: 1)
        try #require(await eventually { provider.requests.count == 2 })
        switch change {
        case "source": model.sourceText = "Інший текст."
        case "translation": model.userEditedTranslation("My own edit.")
        case "language": model.targetLanguage = "nl"
        case "tone": model.tone = .formal
        case "translate": model.translateNow()
        default: model.dismissSuggestions()
        }
        #expect(model.suggestions == .idle)
        #expect(model.suggestionRefreshStates.isEmpty)
        provider.finish(1, text: replacement)
        model.requestSuggestions(pane: .translation, selection: "Everything has calmed down.")
        try #require(await eventually { provider.requests.last?.format?.name == "suggestions" })
        provider.finish(provider.requests.count - 1, text: initial)
        try #require(await eventually { if case .loaded = model.suggestions { true } else { false } })
        #expect(try items(model)[1].text == "Everything is back to normal.")
        #expect(model.suggestionRefreshStates.isEmpty)
        model.dismissSuggestions()
        model.stop()
    }

    @Test func invalidRowsAndSourcePaneDoNotStartRefreshRequests() async throws {
        let (model, provider) = try await loaded()
        model.refreshSuggestion(at: -1)
        model.refreshSuggestion(at: 3)
        #expect(model.suggestionRefreshStates.isEmpty)
        #expect(provider.requests.count == 1)
        model.requestSuggestions(pane: .source, selection: "Усе заспокоїлося.")
        try #require(await eventually { provider.requests.count == 2 })
        provider.finish(1, text: initial)
        try #require(await eventually { if case .loaded = model.suggestions { true } else { false } })
        model.refreshSuggestion(at: 0)
        #expect(model.suggestionRefreshStates.isEmpty)
        #expect(provider.requests.count == 2)
    }
}
