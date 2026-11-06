import Foundation
import NaturalLanguage

public struct Detection: Equatable, Sendable {
    public var code: String
    public var confidence: Double
}

/// Local, instant language detection constrained to the user's enabled languages.
public struct LanguageDetector: Sendable {
    public var candidates: [String]

    public init(candidates: [String]) {
        self.candidates = candidates
    }

    public func detect(_ text: String) -> Detection? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Cyrillic disambiguation between Russian and Ukrainian by letters unique to each.
        // NLLanguageRecognizer is unreliable on short Cyrillic phrases.
        if let cyrillic = cyrillicHeuristic(trimmed) { return cyrillic }

        let recognizer = NLLanguageRecognizer()
        let constraints = candidates.compactMap { LanguageCatalog.nlMap[$0] }
        if !constraints.isEmpty { recognizer.languageConstraints = constraints }
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        guard let best = hypotheses.max(by: { $0.value < $1.value }),
              let code = LanguageCatalog.nlMap.first(where: { $0.value == best.key })?.key
        else { return nil }
        return Detection(code: code, confidence: best.value)
    }

    private func cyrillicHeuristic(_ text: String) -> Detection? {
        let hasRU = candidates.contains("ru"), hasUK = candidates.contains("uk")
        guard hasRU || hasUK else { return nil }
        let lower = text.lowercased()
        var cyrillicLetters = 0, letters = 0
        var ukOnly = 0, ruOnly = 0
        for scalar in lower.unicodeScalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if (0x0400...0x04FF).contains(scalar.value) { cyrillicLetters += 1 }
            switch scalar {
            case "і", "ї", "є", "ґ": ukOnly += 1
            case "ы", "э", "ъ", "ё": ruOnly += 1
            default: break
            }
        }
        guard letters > 0, Double(cyrillicLetters) / Double(letters) > 0.5 else { return nil }
        if ukOnly > ruOnly, hasUK { return Detection(code: "uk", confidence: 0.95) }
        if ruOnly > ukOnly, hasRU { return Detection(code: "ru", confidence: 0.95) }
        if hasRU != hasUK { return Detection(code: hasRU ? "ru" : "uk", confidence: 0.8) }
        // No distinguishing letters: let the recognizer choose between the two.
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.russian, .ukrainian]
        recognizer.processString(text)
        let h = recognizer.languageHypotheses(withMaximum: 2)
        let ru = h[.russian] ?? 0, uk = h[.ukrainian] ?? 0
        return ru >= uk ? Detection(code: "ru", confidence: ru) : Detection(code: "uk", confidence: uk)
    }
}

public enum PairResolver {
    /// Resolves the effective target language. When the detected source equals the chosen target,
    /// pick the first quick pair starting from the detected language, otherwise the first other
    /// enabled language.
    public static func effectiveTarget(
        source: String,
        target: String,
        quickPairs: [LanguagePair],
        enabled: [String]
    ) -> String {
        guard source == target else { return target }
        if let pair = quickPairs.first(where: { $0.source == source && $0.target != source }) {
            return pair.target
        }
        return enabled.first { $0 != source } ?? target
    }
}
