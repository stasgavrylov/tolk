import Foundation
import Observation

/// A one-shot search, independent of the translation draft, preferences, and history.
@MainActor
@Observable
public final class PhraseFinderModel {
    public struct Result: Equatable, Sendable {
        public let query: String
        public let targetLanguage: String
        public let tone: Tone
        public let items: [PhraseSuggestion]
    }

    public struct Failure: Equatable, Sendable {
        public let message: String
        public let requiresSignIn: Bool
    }

    public var query = "" { didSet { if query != oldValue { inputsChanged() } } }
    public var targetLanguage: String { didSet { if targetLanguage != oldValue { inputsChanged() } } }
    public var tone: Tone = .auto { didSet { if tone != oldValue { inputsChanged() } } }
    public private(set) var result: Result?
    public private(set) var failure: Failure?
    public private(set) var isSearching = false
    public private(set) var isStopped = false

    @ObservationIgnored public let undoManager = UndoManager()
    private let settings: AppSettings
    private let provider: any LLMProvider
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(settings: AppSettings, provider: any LLMProvider) {
        self.settings = settings
        self.provider = provider
        targetLanguage = settings.lastTarget
    }

    public var canSearch: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var resultIsCurrent: Bool {
        guard let result else { return false }
        return !isSearching && !isStopped && failure == nil
            && result.query == query.trimmingCharacters(in: .whitespacesAndNewlines)
            && result.targetLanguage == targetLanguage && result.tone == tone
    }

    private func cancelSearch() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    private func inputsChanged() {
        cancelSearch()
        failure = nil
        isStopped = false
    }

    /// Signing in enables an explicit retry; it must never send the description automatically.
    public func clearSignInFailure() {
        if failure?.requiresSignIn == true { failure = nil }
    }

    public func stop() {
        guard isSearching else { return }
        cancelSearch()
        failure = nil
        isStopped = true
    }

    public func find() {
        guard canSearch else { return }
        cancelSearch()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetLanguage, tone = tone, gen = generation
        let request = LLMRequest(
            model: settings.suggestionsModel,
            instructions: Prompts.phraseFinder(target: settings.language(target), tone: tone),
            input: query,
            format: StructuredFormat(name: "suggestions", schema: Prompts.suggestionSchema))
        let provider = provider
        isSearching = true
        isStopped = false
        failure = nil
        searchTask = Task { [weak self] in
            do {
                let raw = try await provider.complete(request)
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                let items = try PhraseSuggestion.parse(raw)
                self.result = Result(query: query, targetLanguage: target, tone: tone, items: items)
                self.isSearching = false
                self.searchTask = nil
            } catch {
                guard let self, self.generation == gen, !Task.isCancelled else { return }
                self.isSearching = false
                self.searchTask = nil
                self.failure = Failure(message: error.localizedDescription,
                                       requiresSignIn: (error as? LLMError)?.requiresSignIn == true)
            }
        }
    }
}
