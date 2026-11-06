import Foundation
import Testing
import TolkTestSupport
@testable import TolkCore

@MainActor @Suite struct TranslatorModelTests {
    func make(_ responder: @escaping @Sendable (LLMRequest) -> MockProvider.Reply = { _ in .init(chunks: ["Hal", "lo"]) })
        -> (TranslatorModel, MockProvider)
    {
        let settings = makeSettings()
        settings.debounceMilliseconds = 30
        let provider = MockProvider(responder: responder)
        let model = TranslatorModel(settings: settings, provider: provider)
        model.historySettleDelay = .milliseconds(30)
        return (model, provider)
    }

    @Test func debouncesTypingIntoOneStreamedRequest() async {
        let (m, p) = make()
        m.targetLanguage = "nl"
        m.sourceText = "При"
        m.sourceText = "Привіт"
        #expect(await eventually { m.translation == "Hallo" && !m.isTranslating })
        #expect(p.requests.count == 1)
        #expect(p.requests[0].input == "Привіт")
        #expect(p.requests[0].instructions.contains("from Ukrainian into Dutch"))
        #expect(m.detected?.code == "uk")
    }

    @Test func manualModeWaitsForTranslateNow() async throws {
        let (m, p) = make()
        m.settings.liveTranslation = false
        m.sourceText = "Привет"
        try await Task.sleep(for: .milliseconds(100))
        #expect(p.requests.isEmpty)
        m.translateNow()
        #expect(await eventually { m.translation == "Hallo" })
    }

    @Test func detectedEnglishSourceUsesTheRemainingDefaultPair() async {
        let (m, p) = make()
        m.targetLanguage = "en"
        m.sourceText = "Where is the nearest train station?"
        #expect(await eventually { !p.requests.isEmpty })
        // The first remaining default from EN is EN→UK.
        #expect(m.targetLanguage == "uk")
        #expect(p.requests[0].instructions.contains("into Ukrainian"))
    }

    @Test func toneIsStoredPerTargetAndRetranslates() async {
        let (m, p) = make()
        m.targetLanguage = "nl"
        m.sourceText = "Как дела?"
        #expect(await eventually { p.requests.count == 1 && !m.isTranslating })
        m.tone = .formal
        #expect(await eventually { p.requests.count == 2 })
        #expect(p.requests[1].instructions.contains("formal, polite"))
        m.targetLanguage = "en"
        #expect(m.tone == .auto)
        #expect(m.settings.tone(for: "nl") == .formal)
    }

    @Test func swapMovesFinishedTranslationIntoSourceAndRetranslates() async {
        let (m, p) = make { r in .init(chunks: [r.input == "Hallo" ? "\u{417}\u{434}\u{440}\u{430}\u{432}\u{441}\u{442}\u{432}\u{443}\u{439}" : "Hallo"]) }
        m.sourceLanguage = "ru"
        m.targetLanguage = "nl"
        m.sourceText = "Привет"
        #expect(await eventually { m.translation == "Hallo" && !m.isTranslating })
        m.swap()
        #expect(m.sourceText == "Hallo")
        #expect(m.sourceLanguage == "nl")
        #expect(m.targetLanguage == "ru")
        #expect(await eventually { m.translation == "\u{417}\u{434}\u{440}\u{430}\u{432}\u{441}\u{442}\u{432}\u{443}\u{439}" && !m.isTranslating })
        #expect(p.requests.count == 2)
        var recorded: [HistoryCandidate] = []
        m.recordHistory = { recorded.append($0) }
        m.commitHistory()
        #expect(recorded.map(\.sourceText) == ["Hallo"])
    }

    @Test func swapWithDetectPinsOldTargetWhenTranslationUnfinished() async {
        let (m, p) = make { _ in .init(chunks: ["slow"], delay: .seconds(5)) }
        m.settings.enabledLanguages.append(LanguageCatalog.russian)
        m.targetLanguage = "nl"
        m.sourceText = "Привет"
        #expect(await eventually { m.isTranslating })
        m.userEditedTranslation("Hoi")
        m.swap()
        #expect(m.sourceLanguage == "nl")
        #expect(m.targetLanguage == "ru")
        #expect(m.sourceText == "Hoi")
        #expect(await eventually { p.requests.count == 2 })
        #expect(p.requests[1].input == "Hoi")
    }

    @Test func swapBeforeAnyTranslationKeepsSourceTextAndSwapsLanguages() async {
        let (m, p) = make { _ in .init(chunks: ["slow"], delay: .seconds(5)) }
        m.sourceLanguage = "ru"
        m.targetLanguage = "nl"
        m.sourceText = "Привет"
        #expect(await eventually { m.isTranslating })
        m.swap()
        #expect(m.sourceText == "Привет")
        #expect(m.sourceLanguage == "nl")
        #expect(m.targetLanguage == "ru")
        #expect(await eventually { p.requests.count == 2 })
        #expect(p.requests[1].input == "Привет")
    }

    @Test func quickPairSetsLanguagesAndRetranslates() async {
        let (m, p) = make()
        m.settings.quickPairs = [LanguagePair(source: "en", target: "uk"), LanguagePair(source: "ru", target: "nl")]
        m.sourceText = "text"
        #expect(await eventually { p.requests.count == 1 && !m.isTranslating })
        m.applyQuickPair(1) // RU→NL in this custom list, independent of the factory ordering.
        #expect(m.sourceLanguage == "ru")
        #expect(m.targetLanguage == "nl")
        #expect(await eventually { p.requests.count == 2 })
        m.applyQuickPair(42)
        #expect(m.targetLanguage == "nl")
    }

    @Test func loadingKnownTranslationDuringStreamIsNotOverwrittenByTheCancelledStream() async {
        let (m, _) = make { _ in .init(chunks: ["late"], delay: .milliseconds(150)) }
        m.sourceLanguage = "ru"
        m.targetLanguage = "nl"
        m.sourceText = "\u{43a}\u{43e}\u{442}"
        #expect(await eventually { m.isTranslating })
        m.load(text: "\u{43f}\u{435}\u{441}", source: .language("ru"), target: "nl", translation: "hond")
        var recorded: [HistoryCandidate] = []
        m.recordHistory = { recorded.append($0) }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(m.translation == "hond")
        m.commitHistory()
        #expect(recorded.map(\.translation) == ["hond"])
    }

    @Test func editingTranslationStopsTheStreamFromOverwritingIt() async {
        let (m, _) = make { _ in .init(chunks: ["late"], delay: .milliseconds(150)) }
        m.sourceLanguage = "ru"
        m.targetLanguage = "nl"
        m.sourceText = "\u{43a}\u{43e}\u{442}"
        #expect(await eventually { m.isTranslating })
        m.userEditedTranslation("mijn tekst")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(m.translation == "mijn tekst")
        #expect(!m.isTranslating)
    }

    @Test func externalTextWithDetectIgnoresPinnedSource() async {
        let (m, p) = make()
        m.sourceLanguage = "ru"
        m.targetLanguage = "nl"
        m.load(text: "Where is the nearest train station?", source: .detect)
        #expect(m.sourceLanguage == nil)
        #expect(await eventually { !p.requests.isEmpty })
        #expect(m.detected?.code == "en")
        #expect(p.requests[0].instructions.contains("from English into Dutch"))
    }

    @Test func staleStreamDoesNotOverwriteNewerTranslation() async {
        let (m, _) = make { req in
            req.input == "first" ? .init(chunks: ["OLD"], delay: .milliseconds(300)) : .init(chunks: ["NEW"])
        }
        m.targetLanguage = "nl"
        m.sourceText = "first"
        #expect(await eventually { m.isTranslating })
        m.sourceText = "second"
        #expect(await eventually { m.translation == "NEW" })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(m.translation == "NEW")
    }

    @Test func cancelledStaleRequestDoesNotEndNewerInFlightRequest() async throws {
        let (m, p) = make { req in
            .init(chunks: [req.input == "first" ? "OLD" : "NEW"], delay: .milliseconds(req.input == "first" ? 300 : 250))
        }
        m.targetLanguage = "nl"
        m.sourceText = "first"
        #expect(await eventually { p.requests.count == 1 })
        m.sourceText = "second"
        #expect(await eventually { p.requests.count == 2 })
        try await Task.sleep(for: .milliseconds(80))
        // The cancelled first stream has ended by now; the second is still running.
        #expect(m.isTranslating)
        #expect(await eventually { m.translation == "NEW" && !m.isTranslating })
    }

    @Test func errorsAreShownAndClearingTextResets() async {
        let (m, _) = make { _ in .init(chunks: [], error: LLMError.notSignedIn) }
        m.sourceText = "hello there"
        #expect(await eventually { m.errorMessage != nil })
        #expect(m.errorMessage?.contains("Not signed in") == true)
        m.sourceText = ""
        #expect(m.errorMessage == nil)
        #expect(m.translation == "")
    }

    @Test func historyRecordsOnlySettledTranslationsAndRespectsPause() async throws {
        let (m, _) = make()
        m.settings.enabledLanguages.append(LanguageCatalog.russian)
        var recorded: [HistoryCandidate] = []
        m.recordHistory = { recorded.append($0) }
        m.targetLanguage = "nl"
        m.sourceText = "Привет"
        #expect(await eventually { recorded.count == 1 })
        #expect(recorded[0] == HistoryCandidate(sourceText: "Привет", translation: "Hallo", sourceLanguage: "ru", targetLanguage: "nl", tone: .auto))
        m.settings.historyPaused = true
        m.sourceText = "Привет, мир"
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorded.count == 1)
    }

    @Test func translationSuggestionsUseStructuredRequestAndExcludeSelection() async {
        let json = #"{"suggestions":[{"text":"Hallo","note":"n","back":"b"},{"text":"Hoi","note":"неформально","back":"привет"}]}"#
        let (m, p) = make { req in req.format == nil ? .init(chunks: ["Hallo wereld"]) : .init(chunks: [json]) }
        m.sourceLanguage = "ru"
        m.targetLanguage = "nl"
        m.sourceText = "Привет, мир"
        #expect(await eventually { m.translation == "Hallo wereld" && !m.isTranslating })
        m.requestSuggestions(pane: .translation, selection: " Hallo ")
        #expect(await eventually {
            if case .loaded = m.suggestions { true } else { false }
        })
        #expect(m.suggestions == .loaded(pane: .translation, selection: "Hallo",
                                         items: [PhraseSuggestion(text: "Hoi", note: "неформально", back: "привет")]))
        let req = p.requests[1]
        #expect(req.format?.name == "suggestions")
        #expect(req.input.contains("Selected phrase in the translation:\nHallo"))
        #expect(req.instructions.contains("usage note in Russian"))
    }

    @Test func sourceSuggestionsAskForIdioms() async {
        let (m, p) = make { req in req.format == nil ? .init(chunks: ["x"]) : .init(chunks: [#"{"suggestions":[]}"#]) }
        m.sourceLanguage = "ru"
        m.targetLanguage = "nl"
        m.sourceText = "Не вешай нос"
        #expect(await eventually { !m.isTranslating && !p.requests.isEmpty })
        m.requestSuggestions(pane: .source, selection: "вешай нос")
        #expect(await eventually { m.suggestions == .loaded(pane: .source, selection: "вешай нос", items: []) })
        #expect(p.requests.last?.instructions.contains("native Dutch speaker") == true)
    }

    @Test func restoringHistoryCanUndoBothPanesAndLanguagesWithoutRetranslating() {
        let (m, p) = make()
        m.settings.liveTranslation = false
        m.sourceLanguage = "en"
        m.targetLanguage = "nl"
        m.sourceText = "An unfinished draft"
        m.userEditedTranslation("Mijn eigen tekst")

        m.load(text: "Привет", source: .language("ru"), target: "en", translation: "Hello")
        #expect(m.sourceText == "Привет")
        #expect(m.translation == "Hello")
        #expect(m.undoManager.canUndo)
        m.undoManager.undo()

        #expect(m.sourceText == "An unfinished draft")
        #expect(m.translation == "Mijn eigen tekst")
        #expect(m.sourceLanguage == "en")
        #expect(m.targetLanguage == "nl")
        #expect(p.requests.isEmpty)
        m.undoManager.redo()
        #expect(m.sourceText == "Привет")
        #expect(m.translation == "Hello")
        #expect(p.requests.isEmpty)
    }

    @Test func replacementAndSmoothingAreOneUndoableEdit() async {
        let (m, p) = make { _ in .init(chunks: ["Hoi, wereld!"]) }
        m.load(text: "Привет, мир", source: .language("ru"), target: "nl", translation: "Hallo wereld")
        m.undoManager.removeAllActions()
        m.applySuggestion(.init(text: "Hoi", note: "", back: ""), range: NSRange(location: 0, length: 5))
        #expect(await eventually { !m.isSmoothing })
        #expect(m.translation == "Hoi, wereld!")
        #expect(m.undoManager.canUndo)
        m.undoManager.undo()
        #expect(m.translation == "Hallo wereld")
        #expect(!m.undoManager.canUndo)
        m.undoManager.redo()
        #expect(m.translation == "Hoi, wereld!")
        #expect(p.requests.count == 1)
    }

    @Test func undoWhileSmoothingPreventsLateCompletionFromChangingTheRestoredText() async {
        let (m, _) = make { _ in .init(chunks: ["late result"], delay: .milliseconds(150)) }
        m.load(text: "Привет", source: .language("ru"), target: "nl", translation: "Hallo")
        m.undoManager.removeAllActions()
        m.applySuggestion(.init(text: "Hoi", note: "", back: ""), range: NSRange(location: 0, length: 5))
        m.undoManager.undo()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(m.translation == "Hallo")
        #expect(!m.isSmoothing)
    }

    @Test func restoringHistoryClearsTheFailureFromThePreviousRequest() async {
        let (m, _) = make { _ in .init(chunks: [], error: LLMError.unauthorized) }
        m.sourceText = "hello there"
        #expect(await eventually { m.errorMessage != nil })
        m.load(text: "Привет", source: .language("ru"), target: "nl", translation: "Hallo")
        #expect(m.errorMessage == nil)
    }

    @Test func editingSourceInManualModeCancelsAnOlderInFlightTranslation() async {
        let (m, _) = make { _ in .init(chunks: ["old result"], delay: .milliseconds(150)) }
        m.settings.liveTranslation = false
        m.sourceText = "first draft"
        m.translateNow()
        #expect(await eventually { m.isTranslating })
        m.sourceText = "new draft"
        try? await Task.sleep(for: .milliseconds(250))
        #expect(m.sourceText == "new draft")
        #expect(m.translation.isEmpty)
        #expect(!m.isTranslating)
    }

    @Test func expiredSessionOffersSignInInsteadOfRepeatingTheFailedRequest() async {
        let (m, p) = make { _ in .init(chunks: [], error: LLMError.unauthorized) }
        m.sourceText = "hello there"
        #expect(await eventually { m.errorMessage != nil })
        #expect(m.failure?.requiresSignIn == true)
        m.retryLastFailure()
        #expect(p.requests.count == 1)
        #expect(m.sourceText == "hello there")
    }

    @Test func failedSmoothingRetriesAdjustmentWithoutTranslatingTheSourceAgain() async {
        let (m, first) = make { _ in .init(chunks: [], error: LLMError.http(status: 503, message: "offline")) }
        m.load(text: "Привет, мир", source: .language("ru"), target: "nl", translation: "Hallo wereld")
        m.undoManager.removeAllActions()
        m.applySuggestion(.init(text: "Hoi", note: "", back: ""), range: NSRange(location: 0, length: 5))
        #expect(await eventually { m.errorMessage != nil })
        #expect(m.translation == "Hoi wereld")
        #expect(m.failure?.operation == .smoothing)
        let retry = MockProvider { _ in .init(chunks: ["Hoi, wereld!"]) }
        m.provider = retry
        m.retryLastFailure()
        #expect(await eventually { m.translation == "Hoi, wereld!" && !m.isSmoothing })
        #expect(m.failure == nil)
        #expect(first.requests.count == 1)
        #expect(retry.requests.count == 1)
        #expect(retry.requests.first?.input.contains("⟦Hoi⟧ wereld") == true)
        m.undoManager.undo()
        #expect(m.translation == "Hallo wereld")
        #expect(!m.undoManager.canUndo)
    }

    @Test func stopPreservesPartialOutputWithoutRecordingItAsACompletedTranslation() async {
        let (m, _) = make { _ in .init(chunks: ["partial", " complete"], chunkDelay: .milliseconds(150)) }
        var recorded: [HistoryCandidate] = []
        m.recordHistory = { recorded.append($0) }
        m.sourceText = "hello there"
        #expect(await eventually { m.translation == "partial" })
        m.stop()
        try? await Task.sleep(for: .milliseconds(250))
        #expect(m.translation == "partial")
        #expect(!m.isTranslating)
        #expect(m.isStopped)
        m.commitHistory()
        #expect(recorded.isEmpty)
    }

    @Test func restoringHistoryRestoresItsToneAndUndoRecoversTheDraftTone() {
        let (m, p) = make()
        m.settings.liveTranslation = false
        m.targetLanguage = "nl"
        m.tone = .informal
        m.sourceText = "unfinished draft"
        m.load(text: "Привет", source: .language("ru"), target: "nl", translation: "Goedendag", tone: .formal)
        #expect(m.tone == .formal)
        m.undoManager.undo()
        #expect(m.tone == .informal)
        #expect(p.requests.isEmpty)
    }

    @Test func undoHistoryRestoresOnlyTheTonePreferencesThatTheRestoreChanged() {
        let (m, _) = make()
        m.settings.liveTranslation = false
        m.targetLanguage = "nl"
        m.settings.setTone(.informal, for: "nl")
        #expect(m.settings.tonePerTarget["en"] == nil)
        m.load(text: "Привет", source: .language("ru"), target: "en", translation: "Hello", tone: .formal)
        m.settings.setTone(.formal, for: "ru") // An unrelated settings change is not part of this undo.
        m.undoManager.undo()
        #expect(m.settings.tonePerTarget["en"] == nil)
        #expect(m.settings.tone(for: "en") == .auto)
        #expect(m.tone == .informal)
        #expect(m.settings.tone(for: "ru") == .formal)
        m.undoManager.redo()
        #expect(m.tone == .formal)
        #expect(m.settings.tone(for: "ru") == .formal)
    }

    @Test func copyIsUnavailableWhileTranslationOrSentenceAdjustmentIsRunning() async {
        let (m, _) = make { _ in .init(chunks: ["Hallo"], delay: .milliseconds(100)) }
        m.load(text: "Привет", source: .language("ru"), target: "nl", translation: "Hoi")
        #expect(m.canCopyTranslation)
        m.translateNow()
        #expect(!m.canCopyTranslation)
        #expect(await eventually { !m.isTranslating })
        #expect(m.canCopyTranslation)
        m.applySuggestion(.init(text: "Hoi", note: "", back: ""), range: NSRange(location: 0, length: 5))
        #expect(!m.canCopyTranslation)
        #expect(await eventually { !m.isSmoothing })
        #expect(m.canCopyTranslation)
    }

    @Test func directTranslationEditsAreCurrentAndAreSavedWithTheCurrentSource() {
        let (m, _) = make()
        var recorded: [HistoryCandidate] = []
        m.recordHistory = { recorded.append($0) }
        m.load(text: "Привет", source: .language("ru"), target: "nl", translation: "Hallo")
        m.userEditedTranslation("Hoi daar")
        #expect(m.translationIsCurrent)
        m.commitHistory()
        #expect(recorded.last?.sourceText == "Привет")
        #expect(recorded.last?.translation == "Hoi daar")
    }

    @Test func applyingSuggestionReplacesThenSmooths() async {
        let (m, p) = make { req in
            if req.instructions.contains("replaced one phrase") { return .init(chunks: ["Hoi, wereld!"]) }
            return .init(chunks: ["Hallo wereld"])
        }
        m.sourceLanguage = "ru"
        m.targetLanguage = "nl"
        m.sourceText = "Привет, мир"
        #expect(await eventually { m.translation == "Hallo wereld" && !m.isTranslating })
        m.applySuggestion(PhraseSuggestion(text: "Hoi", note: "", back: ""), range: NSRange(location: 0, length: 5))
        #expect(m.translation == "Hoi wereld")
        #expect(m.isSmoothing)
        #expect(await eventually { m.translation == "Hoi, wereld!" && !m.isSmoothing })
        #expect(p.requests.last?.input.contains("⟦Hoi⟧ wereld") == true)
    }
}
