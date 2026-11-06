import Foundation
import Observation

public enum Pane: Sendable { case source, translation }

public enum SuggestionState: Equatable {
    case idle
    case loading(pane: Pane, selection: String)
    case loaded(pane: Pane, selection: String, items: [PhraseSuggestion])
    case failed(pane: Pane, selection: String, message: String)
}

public struct TranslationFailure: Equatable, Sendable {
    public enum Operation: Sendable { case translation, smoothing }
    public let operation: Operation
    public let message: String
    public let requiresSignIn: Bool
}

/// Owns the main window's translation state: live debounced translation, swap, quick pairs,
/// tone and phrase suggestions. UI-agnostic so it can be tested with a mock provider.
@MainActor
@Observable
public final class TranslatorModel {
    public var sourceText = "" { didSet { if sourceText != oldValue { sourceEdited() } } }
    public private(set) var translation = ""
    /// nil means detect.
    public var sourceLanguage: String? { didSet { if sourceLanguage != oldValue { settings.lastSource = sourceLanguage; languagesChanged() } } }
    public var targetLanguage: String { didSet { if targetLanguage != oldValue { settings.lastTarget = targetLanguage; languagesChanged() } } }
    public private(set) var detected: Detection?
    public private(set) var isTranslating = false
    public private(set) var isSmoothing = false
    public var errorMessage: String? { failure?.message }
    public private(set) var failure: TranslationFailure?
    public private(set) var translationIsPartial = false
    public private(set) var isStopped = false
    public private(set) var suggestions: SuggestionState = .idle
    /// Incremented when the translation text is replaced wholesale (so views can reset selection).
    public private(set) var translationRevision = 0

    public let settings: AppSettings
    @ObservationIgnored public let undoManager = UndoManager()
    @ObservationIgnored public var provider: LLMProvider
    @ObservationIgnored public var recordHistory: (HistoryCandidate) -> Void = { _ in }
    @ObservationIgnored public var historySettleDelay: Duration = .seconds(2)

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var translateTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var suggestionTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastRequestKey: String?
    @ObservationIgnored private var adjustingLanguages = false
    /// Inputs that produced the current `translation` (for history and swap).
    @ObservationIgnored private var completed: HistoryCandidate?
    @ObservationIgnored private var smoothingRetry: SmoothingContext?

    public init(settings: AppSettings, provider: LLMProvider) {
        self.settings = settings
        self.provider = provider
        sourceLanguage = settings.lastSource
        targetLanguage = settings.lastTarget
    }

    // MARK: Derived

    public var tone: Tone {
        get { settings.tone(for: targetLanguage) }
        set {
            guard newValue != tone else { return }
            settings.setTone(newValue, for: targetLanguage)
            translateNow()
        }
    }

    /// The source language actually used: explicit choice, else detection.
    public var effectiveSource: String? { sourceLanguage ?? detected?.code }

    public var characterCount: Int { sourceText.count }
    public var canCopyTranslation: Bool { !translation.isEmpty && !isTranslating && !isSmoothing }

    public var translationIsCurrent: Bool {
        guard let completed else { return false }
        return !isStopped && !translationIsPartial && !isTranslating && !isSmoothing
            && completed.sourceText == sourceText && (sourceLanguage == nil || sourceLanguage == completed.sourceLanguage)
            && completed.translation == translation && completed.targetLanguage == targetLanguage
            && completed.tone == tone
    }

    // MARK: Translation

    private func sourceEdited() {
        guard !adjustingLanguages else { return }
        cancelInFlight()
        suggestions = .idle
        failure = nil
        if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translation = ""
            translationIsPartial = false
            detected = nil
            failure = nil
            completed = nil
            lastRequestKey = nil
            translationRevision += 1
            return
        }
        guard settings.liveTranslation else { return }
        let delay = settings.debounceMilliseconds
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.translate(force: false)
        }
    }

    private func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func languagesChanged() {
        guard !adjustingLanguages else { return }
        suggestions = .idle
        if !sourceText.isEmpty { translateNow() }
    }

    /// ⌘↩: translate immediately, even if the input was already translated.
    public func translateNow() {
        translate(force: true)
    }

    public func stop() {
        guard isTranslating || isSmoothing else { return }
        cancelInFlight()
        failure = nil
        isStopped = true
        lastRequestKey = nil
    }

    public func clearSignInFailure() {
        if failure?.requiresSignIn == true { failure = nil }
    }

    public func retryLastFailure() {
        guard let failure, !failure.requiresSignIn else { return }
        switch failure.operation {
        case .translation: translateNow()
        case .smoothing:
            guard let context = smoothingRetry else { return }
            runSmoothing(context)
        }
    }

    private func recordFailure(_ error: Error, operation: TranslationFailure.Operation) {
        failure = TranslationFailure(operation: operation, message: error.localizedDescription,
                                     requiresSignIn: (error as? LLMError)?.requiresSignIn == true)
    }

    private func cancelInFlight() {
        cancelDebounce()
        // A cancelled stream ends like a finished one; the generation bump keeps its epilogue out.
        generation += 1
        translateTask?.cancel()
        historyTask?.cancel()
        isTranslating = false
        isSmoothing = false
        isStopped = false
        smoothingRetry = nil
    }

    private func translate(force: Bool) {
        cancelDebounce()
        let text = sourceText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let plan = TranslationPlanner.plan(text: text, source: sourceLanguage, target: targetLanguage, settings: settings)
        detected = plan.detected
        if plan.target.code != targetLanguage {
            adjustingLanguages = true
            targetLanguage = plan.target.code
            adjustingLanguages = false
        }
        let target = plan.target, source = plan.source, tone = plan.tone
        let request = plan.request
        let key = [text, source?.code ?? "?", target.code, tone.rawValue, request.model.model, request.model.effort ?? ""]
            .joined(separator: "\u{1}")
        if !force, key == lastRequestKey { return }
        lastRequestKey = key

        translateTask?.cancel()
        historyTask?.cancel()
        generation += 1
        let gen = generation
        isTranslating = true
        isSmoothing = false
        isStopped = false
        smoothingRetry = nil
        failure = nil
        let provider = self.provider
        translateTask = Task { [weak self] in
            var output = ""
            var started = false
            do {
                for try await delta in provider.stream(request) {
                    guard let self, self.generation == gen else { return }
                    output += delta
                    if !started {
                        started = true
                        self.translationRevision += 1
                    }
                    self.translationIsPartial = true
                    self.translation = output
                }
                guard let self, self.generation == gen else { return }
                self.isTranslating = false
                self.translationIsPartial = false
                if !started { self.translation = ""; self.translationRevision += 1 }
                let candidate = HistoryCandidate(
                    sourceText: text, translation: output, sourceLanguage: source?.code ?? "",
                    targetLanguage: target.code, tone: tone)
                self.completed = candidate
                self.scheduleHistory(candidate)
            } catch {
                guard let self, self.generation == gen else { return }
                self.isTranslating = false
                if error is CancellationError { return }
                self.lastRequestKey = nil
                self.recordFailure(error, operation: .translation)
            }
        }
    }

    // MARK: History

    private func scheduleHistory(_ candidate: HistoryCandidate) {
        historyTask?.cancel()
        let delay = historySettleDelay
        historyTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.commitHistory()
        }
    }

    /// Records the settled translation now (after a pause, or on copy/swap).
    public func commitHistory() {
        historyTask?.cancel()
        guard !settings.historyPaused, let completed, completed.translation == translation,
              !isTranslating, !isSmoothing, !isStopped, !translationIsPartial else { return }
        recordHistory(completed)
    }

    // MARK: Commands

    /// ⇧⌘S: swap languages, move the translation into the source and re-translate it. With Detect,
    /// the old target becomes the explicit source (it is known, and short text detects poorly).
    public func swap() {
        guard let src = effectiveSource ?? settings.quickPairs.first(where: { $0.target == targetLanguage })?.source
        else { return }
        commitHistory()
        cancelInFlight()
        let oldTranslation = translation
        adjustingLanguages = true
        sourceLanguage = targetLanguage
        targetLanguage = src
        // With nothing translated yet, only the languages swap; the text stays.
        if !oldTranslation.isEmpty { sourceText = oldTranslation }
        adjustingLanguages = false
        cancelDebounce()
        suggestions = .idle
        translateNow()
    }

    public func applyQuickPair(_ index: Int) {
        guard settings.quickPairs.indices.contains(index) else { return }
        let pair = settings.quickPairs[index]
        adjustingLanguages = true
        sourceLanguage = pair.source
        targetLanguage = pair.target
        adjustingLanguages = false
        suggestions = .idle
        if !sourceText.isEmpty { translateNow() }
    }

    /// Loads text from outside (selection hotkey, history) and translates it.
    /// How `load` treats the source language.
    public enum SourceChoice: Equatable, Sendable {
        /// Auto-detect: text from outside the window (clipboard, selection) may be in any language.
        case detect
        case language(String)
    }

    public func load(text: String, source: SourceChoice = .detect, target: String? = nil,
                     translation knownTranslation: String? = nil, tone knownTone: Tone? = nil) {
        if knownTranslation != nil {
            registerUndo(snapshot(toneTargets: [targetLanguage, target ?? targetLanguage]), named: "Restore Translation")
        }
        cancelInFlight()
        failure = nil
        adjustingLanguages = true
        switch source {
        case .detect: sourceLanguage = nil
        case .language(let code): sourceLanguage = code
        }
        if let target { targetLanguage = target }
        if let knownTone { settings.setTone(knownTone, for: targetLanguage) }
        sourceText = text
        adjustingLanguages = false
        cancelDebounce()
        suggestions = .idle
        if let knownTranslation {
            detected = sourceLanguage == nil
                ? LanguageDetector(candidates: settings.enabledLanguages.map(\.code)).detect(text) : nil
            translationIsPartial = false
            translation = knownTranslation
            translationRevision += 1
            completed = HistoryCandidate(sourceText: text, translation: knownTranslation,
                                         sourceLanguage: sourceLanguage ?? "", targetLanguage: targetLanguage, tone: tone)
            lastRequestKey = nil
        } else {
            translateNow()
        }
    }

    // A history restore is one edit of the whole working state, not four unrelated field edits.
    // Smoothing shares the transaction so its asynchronous completion does not add an undo step.
    private struct EditorSnapshot {
        let sourceText: String
        let translation: String
        let sourceLanguage: String?
        let targetLanguage: String
        // Optional values preserve an absent preference, without rolling back unrelated settings.
        let tonePreferences: [String: Tone?]
        let detected: Detection?
        let completed: HistoryCandidate?
        let failure: TranslationFailure?
        let isPartial: Bool
        let isStopped: Bool
        let smoothingRetry: SmoothingContext?
    }

    private func snapshot(toneTargets: [String]? = nil) -> EditorSnapshot {
        EditorSnapshot(sourceText: sourceText, translation: translation, sourceLanguage: sourceLanguage,
                       targetLanguage: targetLanguage,
                       tonePreferences: Dictionary(uniqueKeysWithValues: Set(toneTargets ?? [targetLanguage]).map {
                           ($0, settings.tonePerTarget[$0])
                       }), detected: detected,
                       completed: completed, failure: failure, isPartial: translationIsPartial,
                       isStopped: isStopped || isTranslating || isSmoothing, smoothingRetry: smoothingRetry)
    }

    private func registerUndo(_ previous: EditorSnapshot, named name: String) {
        let ownsGroup = undoManager.groupingLevel == 0
        if ownsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreSnapshot(previous, named: name) }
        }
        undoManager.setActionName(name)
        if ownsGroup { undoManager.endUndoGrouping() }
    }

    private func restoreSnapshot(_ previous: EditorSnapshot, named name: String) {
        registerUndo(snapshot(toneTargets: Array(previous.tonePreferences.keys)), named: name)
        cancelInFlight()
        dismissSuggestions()
        adjustingLanguages = true
        sourceLanguage = previous.sourceLanguage
        targetLanguage = previous.targetLanguage
        for (target, preference) in previous.tonePreferences { settings.tonePerTarget[target] = preference }
        sourceText = previous.sourceText
        adjustingLanguages = false
        translation = previous.translation
        detected = previous.detected
        completed = previous.completed
        failure = previous.failure
        translationIsPartial = previous.isPartial
        isStopped = previous.isStopped
        smoothingRetry = previous.smoothingRetry
        lastRequestKey = nil
        translationRevision += 1
    }

    /// The user edited the translation pane directly.
    public func userEditedTranslation(_ text: String) {
        guard text != translation else { return }
        // The user's edit wins over a translation still streaming in.
        if isTranslating || isSmoothing { cancelInFlight() }
        translation = text
        translationIsPartial = false
        isStopped = false
        failure = nil
        dismissSuggestions()
        translationRevision += 1
        // A deliberate edit takes ownership of the result, including its history metadata.
        let source = sourceLanguage ?? (completed?.sourceText == sourceText ? completed?.sourceLanguage : nil) ?? ""
        let candidate = HistoryCandidate(sourceText: sourceText, translation: text, sourceLanguage: source,
                                         targetLanguage: targetLanguage, tone: tone)
        completed = candidate
        scheduleHistory(candidate)
    }

    /// Waits for the current translation (tests and the replace-in-place hotkey).
    public func waitUntilIdle() async {
        while isTranslating || isSmoothing || debounceTask != nil {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Suggestions

    public func requestSuggestions(pane: Pane, selection: String) {
        let phrase = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, let src = effectiveSource else { return }
        if pane == .translation, translation.isEmpty { return }
        suggestionTask?.cancel()
        suggestions = .loading(pane: pane, selection: phrase)
        let source = settings.language(src), target = settings.language(targetLanguage)
        let request: LLMRequest
        switch pane {
        case .translation:
            request = LLMRequest(
                model: settings.suggestionsModel,
                instructions: Prompts.alternatives(source: source, target: target, tone: tone),
                input: Prompts.alternativesInput(sourceText: sourceText, translation: translation, selection: phrase),
                format: StructuredFormat(name: "suggestions", schema: Prompts.suggestionSchema))
        case .source:
            request = LLMRequest(
                model: settings.suggestionsModel,
                instructions: Prompts.idioms(source: source, target: target, tone: tone),
                input: Prompts.idiomsInput(sourceText: sourceText, selection: phrase),
                format: StructuredFormat(name: "suggestions", schema: Prompts.suggestionSchema))
        }
        let provider = self.provider
        suggestionTask = Task { [weak self] in
            do {
                let raw = try await provider.complete(request)
                let items = try PhraseSuggestion.parse(raw, excluding: pane == .translation ? phrase : nil)
                guard !Task.isCancelled, let self, self.suggestions == .loading(pane: pane, selection: phrase) else { return }
                self.suggestions = .loaded(pane: pane, selection: phrase, items: items)
            } catch {
                guard !(error is CancellationError), let self, self.suggestions == .loading(pane: pane, selection: phrase) else { return }
                self.suggestions = .failed(pane: pane, selection: phrase, message: error.localizedDescription)
            }
        }
    }

    public func dismissSuggestions() {
        suggestionTask?.cancel()
        suggestions = .idle
    }

    /// Replaces the selected phrase in the translation, then re-smooths the sentence around it.
    public func applySuggestion(_ suggestion: PhraseSuggestion, range: NSRange) {
        guard let src = effectiveSource,
              let (plain, marked) = TextReplacement.replace(in: translation, range: range, with: suggestion.text)
        else { return }
        registerUndo(snapshot(), named: "Replace Phrase")
        dismissSuggestions()
        let source = settings.language(src), target = settings.language(targetLanguage)
        let request = LLMRequest(
            model: settings.liveModel,
            instructions: Prompts.smoothing(source: source, target: target),
            input: Prompts.smoothingInput(sourceText: sourceText, markedTranslation: marked))
        translation = plain
        translationIsPartial = false
        translationRevision += 1
        runSmoothing(SmoothingContext(request: request, sourceText: sourceText,
                                      source: source.code, target: target.code, tone: tone))
    }

    private struct SmoothingContext {
        let request: LLMRequest
        let sourceText: String
        let source: String
        let target: String
        let tone: Tone
    }

    private func runSmoothing(_ context: SmoothingContext) {
        cancelInFlight()
        smoothingRetry = context
        isSmoothing = true
        failure = nil
        let gen = generation
        let provider = self.provider
        translateTask = Task { [weak self] in
            do {
                let smoothed = try await provider.complete(context.request).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, self.generation == gen else { return }
                self.isSmoothing = false
                self.smoothingRetry = nil
                let final = smoothed.isEmpty ? self.translation
                    : smoothed.replacingOccurrences(of: "⟦", with: "").replacingOccurrences(of: "⟧", with: "")
                if final != self.translation {
                    self.translation = final
                    self.translationRevision += 1
                }
                let candidate = HistoryCandidate(sourceText: context.sourceText, translation: final,
                                                 sourceLanguage: context.source, targetLanguage: context.target,
                                                 tone: context.tone)
                self.completed = candidate
                self.scheduleHistory(candidate)
            } catch {
                guard let self, self.generation == gen else { return }
                self.isSmoothing = false
                if !(error is CancellationError) { self.recordFailure(error, operation: .smoothing) }
            }
        }
    }
}
