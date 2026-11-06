import Foundation

/// A resolved translation job: languages after detection/fallback plus the request to send.
public struct TranslationPlan: Sendable {
    public var text: String
    public var detected: Detection?
    public var source: Language?
    public var target: Language
    public var tone: Tone
    public var request: LLMRequest
}

/// Single owner of "what do we send for this text": used by the main window and the global hotkeys.
@MainActor
public enum TranslationPlanner {
    /// - Parameters:
    ///   - source: explicit source language code, or nil to auto-detect.
    ///   - target: preferred target; replaced when it equals the (detected) source.
    public static func plan(text: String, source: String?, target: String, settings: AppSettings) -> TranslationPlan {
        let enabled = settings.enabledLanguages.map(\.code)
        let detected = source == nil ? LanguageDetector(candidates: enabled).detect(text) : nil
        let sourceCode = source ?? detected?.code
        let targetCode = sourceCode.map {
            PairResolver.effectiveTarget(source: $0, target: target, quickPairs: settings.quickPairs, enabled: enabled)
        } ?? target
        let sourceLanguage = sourceCode.map(settings.language)
        let targetLanguage = settings.language(targetCode)
        let tone = settings.tone(for: targetCode)
        return TranslationPlan(
            text: text, detected: detected, source: sourceLanguage, target: targetLanguage, tone: tone,
            request: LLMRequest(
                model: settings.liveModel,
                instructions: Prompts.translation(source: sourceLanguage, target: targetLanguage, tone: tone),
                input: text))
    }
}
