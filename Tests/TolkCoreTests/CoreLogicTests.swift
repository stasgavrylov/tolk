import Foundation
import Testing
@testable import TolkCore

@Suite struct SSEParserTests {
    @Test func splitsEventsAcrossChunkBoundaries() {
        var p = SSEParser()
        #expect(p.feed(Data("data: {\"a\"".utf8)) == [])
        #expect(p.feed(Data(":1}\n\ndata: x\r\n".utf8)) == ["{\"a\":1}"])
        #expect(p.feed(Data("\r\n".utf8)) == ["x"])
    }

    @Test func joinsMultilineDataAndIgnoresComments() {
        var p = SSEParser()
        #expect(p.feed(Data(": ping\nevent: e\ndata: a\ndata: b\n\n".utf8)) == ["a\nb"])
    }

    @Test func finishFlushesUnterminatedEvent() {
        var p = SSEParser()
        #expect(p.feed(Data("data: tail".utf8)) == [])
        #expect(p.finish() == ["tail"])
    }
}

@Suite struct LanguageDetectorTests {
    let detector = LanguageDetector(candidates: ["ru", "uk", "en", "nl"])

    @Test(arguments: [
        ("Привіт, як справи? Їжак їсть яблуко.", "uk"),
        ("Это был очень длинный и тяжёлый день.", "ru"),
        ("Where is the nearest train station?", "en"),
        ("Ik heb vandaag geen tijd om boodschappen te doen.", "nl"),
    ])
    func detectsEnabledLanguages(text: String, expected: String) {
        #expect(detector.detect(text)?.code == expected)
    }

    @Test func emptyTextIsNotDetected() {
        #expect(detector.detect("   \n") == nil)
    }

    @Test func cyrillicWithOnlyRussianEnabledIsRussian() {
        let d = LanguageDetector(candidates: ["ru", "en"])
        #expect(d.detect("Привіт")?.code == "ru")
    }
}

@Suite struct PairResolverTests {
    @Test func differentTargetIsKept() {
        #expect(PairResolver.effectiveTarget(source: "ru", target: "nl", quickPairs: LanguagePair.defaultQuickPairs, enabled: ["ru", "nl"]) == "nl")
    }

    @Test func sameAsTargetUsesFirstQuickPairFromSource() {
        let pairs = [LanguagePair(source: "nl", target: "en"), LanguagePair(source: "nl", target: "ru")]
        #expect(PairResolver.effectiveTarget(source: "nl", target: "nl", quickPairs: pairs, enabled: ["ru", "uk", "en", "nl"]) == "en")
    }

    @Test(arguments: [("ru", "uk"), ("en", "uk")])
    func sameAsTargetUsesRemainingPairsOrEnabledLanguageFallback(source: String, expected: String) {
        #expect(PairResolver.effectiveTarget(source: source, target: source,
                                            quickPairs: LanguagePair.defaultQuickPairs,
                                            enabled: ["ru", "uk", "en", "nl"]) == expected)
    }

    @Test func fallsBackToFirstOtherEnabledLanguage() {
        #expect(PairResolver.effectiveTarget(source: "de", target: "de", quickPairs: [], enabled: ["de", "uk"]) == "uk")
    }
}

@Suite struct ShortcutConflictTests {
    let bindings = InAppAction.defaultBindings

    @Test func defaultBindingsAreConflictFree() {
        for (action, combo) in bindings {
            #expect(ShortcutConflicts.conflict(for: combo, action: action, bindings: bindings) == nil, "\(action)")
        }
    }

    @Test func duplicateBindingIsReported() {
        let msg = ShortcutConflicts.conflict(for: KeyCombo("e", .command), action: .swap, bindings: bindings)
        #expect(msg?.contains("Suggest alternatives") == true)
    }

    @Test func reservedAndModifierlessCombosAreRejected() {
        #expect(ShortcutConflicts.conflict(for: KeyCombo("c", .command), action: .swap, bindings: bindings) != nil)
        #expect(ShortcutConflicts.conflict(for: KeyCombo("k", .shift), action: .swap, bindings: bindings) != nil)
        #expect(ShortcutConflicts.conflict(for: KeyCombo("k", [.command, .option]), action: .swap, bindings: bindings) == nil)
    }

    @Test func displayString() {
        #expect(KeyCombo("s", [.command, .shift]).displayString == "⇧⌘S")
        #expect(KeyCombo("\r", .command).displayString == "⌘↩")
    }
}

@Suite struct PhraseSuggestionParseTests {
    @Test func selectingAWordOrPhraseOpensSuggestionsButLongOrBlankSelectionsDoNot() {
        #expect(PhraseSuggestion.opensOnSelection("Goed"))
        #expect(PhraseSuggestion.opensOnSelection("Goed voor je "))
        #expect(PhraseSuggestion.opensOnSelection("een twee drie vier vijf zes zeven acht negen tien elf twaalf"))
        #expect(!PhraseSuggestion.opensOnSelection("een twee drie vier vijf zes zeven acht negen tien elf twaalf dertien"))
        #expect(!PhraseSuggestion.opensOnSelection(" \n"))
    }

    @Test func dropsEchoesDuplicatesAndEmptyItems() throws {
        let raw = """
        ```json
        {"suggestions":[{"text":"Kop op","note":"n","back":"b"},{"text":"Hou moed","note":"n1","back":"b1"},{"text":"hou moed ","note":"n2","back":"b2"},{"text":" ","note":"","back":""},{"text":"Niet getreurd","note":"n3","back":"b3"}]}
        ```
        """
        let items = try PhraseSuggestion.parse(raw, excluding: "kop op")
        #expect(items.map(\.text) == ["Hou moed", "Niet getreurd"])
        #expect(items[0].note == "n1")
    }

    @Test func malformedJSONThrows() {
        #expect(throws: (any Error).self) { try PhraseSuggestion.parse("not json") }
    }

    @Test func replacementMarksPhraseForSmoothing() {
        let r = TextReplacement.replace(in: "Kop op, alles komt goed.", range: NSRange(location: 0, length: 6), with: "Hou moed")
        #expect(r?.plain == "Hou moed, alles komt goed.")
        #expect(r?.marked == "⟦Hou moed⟧, alles komt goed.")
        #expect(TextReplacement.replace(in: "abc", range: NSRange(location: 2, length: 5), with: "x") == nil)
    }
}

@Suite struct HistoryPolicyTests {
    func entry(_ src: String, _ tr: String, target: String = "nl", age: TimeInterval = 10, starred: Bool = false) -> HistoryEntry {
        HistoryEntry(sourceText: src, translation: tr, sourceLanguage: "ru", targetLanguage: target, tone: .auto,
                     createdAt: Date(timeIntervalSince1970: 1000 - age), starred: starred)
    }
    func cand(_ src: String, _ tr: String, target: String = "nl") -> HistoryCandidate {
        HistoryCandidate(sourceText: src, translation: tr, sourceLanguage: "ru", targetLanguage: target, tone: .auto)
    }
    let now = Date(timeIntervalSince1970: 1000)

    @Test func emptyIsSkipped() {
        #expect(HistoryPolicy.decide(cand(" ", "x"), latest: nil, now: now) == .skip)
        #expect(HistoryPolicy.decide(cand("x", ""), latest: nil, now: now) == .skip)
    }

    @Test func untranslatedEchoIsSkipped() {
        #expect(HistoryPolicy.decide(cand("Kop op.", " Kop op."), latest: nil, now: now) == .skip)
    }

    @Test func identicalToLatestIsSkipped() {
        let e = entry("привет", "hoi")
        #expect(HistoryPolicy.decide(cand("привет", "hoi"), latest: e, match: e, now: now) == .skip)
    }

    @Test func identicalOlderMatchIsBumped() {
        #expect(HistoryPolicy.decide(cand("привет", "hoi"), latest: entry("пока", "doei"), match: entry("привет", "hoi"), now: now) == .updateMatch)
    }

    @Test func retranslationOfSameTextUpdatesMatch() {
        let e = entry("привет", "hoi")
        #expect(HistoryPolicy.decide(cand("привет", "hallo"), latest: e, match: e, now: now) == .updateMatch)
    }

    @Test func continuedTypingUpdatesRecentEntry() {
        #expect(HistoryPolicy.decide(cand("привет, как дела", "x"), latest: entry("привет", "hoi"), now: now) == .updateLatest)
    }

    @Test func continuedTypingAfterWindowInserts() {
        #expect(HistoryPolicy.decide(cand("привет, как дела", "x"), latest: entry("привет", "hoi", age: 500), now: now) == .insert)
    }

    @Test func starredEntryIsNotOverwrittenByContinuedEdit() {
        #expect(HistoryPolicy.decide(cand("привет, как дела", "x"), latest: entry("привет", "hoi", starred: true), now: now) == .insert)
    }

    @Test func otherTargetOrUnrelatedTextInserts() {
        #expect(HistoryPolicy.decide(cand("привет", "hi", target: "en"), latest: entry("привет", "hoi"), now: now) == .insert)
        #expect(HistoryPolicy.decide(cand("до свидания", "doei"), latest: entry("привет", "hoi"), now: now) == .insert)
    }
}

@MainActor @Suite struct HistoryStoreTests {
    @Test func recordsSearchesStarsAndClears() throws {
        let store = try HistoryStore(inMemory: true)
        let t0 = Date(timeIntervalSince1970: 0)
        try store.record(HistoryCandidate(sourceText: "кошка", translation: "kat", sourceLanguage: "ru", targetLanguage: "nl", tone: .auto), now: t0)
        try store.record(HistoryCandidate(sourceText: "собака", translation: "hond", sourceLanguage: "ru", targetLanguage: "nl", tone: .auto), now: t0.addingTimeInterval(1000))
        #expect(try store.entries().map(\.sourceText) == ["собака", "кошка"])
        #expect(try store.entries(matching: "KAT").map(\.translation) == ["kat"])
        let cat = try #require(try store.entries(matching: "кошка").first)
        try store.toggleStar(cat)
        #expect(try store.entries(starredOnly: true).map(\.sourceText) == ["кошка"])
        try store.clearAll(keepStarred: true)
        #expect(try store.entries().map(\.sourceText) == ["кошка"])
        try store.clearAll()
        #expect(try store.entries().isEmpty)
    }

    @Test func retranslatingEarlierTextUpdatesAndBumpsItInsteadOfDuplicating() throws {
        let store = try HistoryStore(inMemory: true)
        let t0 = Date(timeIntervalSince1970: 0)
        func c(_ src: String, _ tr: String, _ target: String) -> HistoryCandidate {
            HistoryCandidate(sourceText: src, translation: tr, sourceLanguage: "ru", targetLanguage: target, tone: .auto)
        }
        try store.record(c("\u{43a}\u{43e}\u{442}", "kat", "nl"), now: t0)
        try store.record(c("\u{43a}\u{43e}\u{442}", "cat", "en"), now: t0.addingTimeInterval(1000))
        try store.record(c("\u{43a}\u{43e}\u{442}", "poes", "nl"), now: t0.addingTimeInterval(2000))
        #expect(try store.entries().map(\.translation) == ["poes", "cat"])
    }
}

@MainActor @Suite struct AppSettingsPersistenceTests {
    @Test func freshSettingsEnableUkrainianEnglishAndDutch() {
        let settings = makeSettings()
        #expect(settings.enabledLanguages.map(\.code) == ["uk", "en", "nl"])
    }

    @Test(arguments: [[Language](), [Language(code: "ru", name: "Russian"), Language(code: "en", name: "English")]])
    func savedLanguageChoicesArePreservedIncludingRussian(languages: [Language]) {
        let suite = "tolk-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.enabledLanguages = languages
        #expect(AppSettings(defaults: defaults).enabledLanguages == languages)
    }

    @Test func freshSettingsOnlyDefaultToUkrainianEnglishAndEnglishDutchPairs() {
        let settings = makeSettings()
        #expect(settings.quickPairs == [
            LanguagePair(source: "uk", target: "en"), LanguagePair(source: "en", target: "uk"),
            LanguagePair(source: "en", target: "nl"), LanguagePair(source: "nl", target: "en"),
        ])
    }

    @Test(arguments: [[LanguagePair](), [LanguagePair(source: "ru", target: "en"),
                                        LanguagePair(source: "en", target: "ru"),
                                        LanguagePair(source: "ru", target: "nl"),
                                        LanguagePair(source: "nl", target: "ru"),
                                        LanguagePair(source: nil, target: "nl")]])
    func savedQuickPairsArePreservedIncludingEmptyAndRussianPairs(pairs: [LanguagePair]) {
        let suite = "tolk-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.quickPairs = pairs
        #expect(AppSettings(defaults: defaults).quickPairs == pairs)
    }

    @Test func clearedBindingStaysClearedAfterRelaunch() {
        let defaults = UserDefaults(suiteName: "tolk-tests-\(UUID().uuidString)")!
        let first = AppSettings(defaults: defaults)
        first.bindings[.swap] = nil
        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.bindings[.swap] == nil)
        #expect(relaunched.bindings[.translate] == InAppAction.translate.defaultCombo)
    }
}

@MainActor @Suite struct SerialQueueTests {
    /// Models the sign-in commit racing a sign-out: the later write must land last, even if the earlier one is slower.
    @Test func laterWriteLandsAfterSlowerEarlierWrite() async throws {
        let queue = SerialQueue()
        var stored: String? = nil
        let signIn = Task { try await queue.run { try await Task.sleep(for: .milliseconds(80)); stored = "token" } }
        try? await Task.sleep(for: .milliseconds(10))
        let signOut = Task { try await queue.run { stored = nil } }
        try await signIn.value
        try await signOut.value
        #expect(stored == nil)
    }

    @Test func operationEnqueuedLaterSeesStateChangedBeforeItRuns() async throws {
        let queue = SerialQueue()
        var attemptActive = true
        var saved = false
        let first = Task { try await queue.run { try await Task.sleep(for: .milliseconds(50)) } }
        let commit = Task { try await queue.run { () -> Bool in
            guard attemptActive else { return false }
            saved = true
            return true
        } }
        attemptActive = false // cancelled while the commit was still queued
        try await first.value
        #expect(try await commit.value == false)
        #expect(!saved)
    }

    @Test func failureDoesNotBlockLaterOperationsAndDrainWaits() async throws {
        struct Boom: Error {}
        let queue = SerialQueue()
        var ran = false
        await #expect(throws: Boom.self) { try await queue.run { throw Boom() } }
        let later = Task { try await queue.run { try await Task.sleep(for: .milliseconds(30)); ran = true } }
        try? await Task.sleep(for: .milliseconds(5))
        await queue.drain()
        #expect(ran)
        try await later.value
    }
}
