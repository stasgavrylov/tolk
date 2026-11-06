import Foundation
import NaturalLanguage

/// A translation language identified by a BCP-47-ish code (e.g. "ru", "pt-BR").
public struct Language: Codable, Hashable, Identifiable, Sendable {
    public var code: String
    /// English name, used in prompts and the UI.
    public var name: String
    public var shortLabel: String { code.uppercased() }
    public var id: String { code }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    public var nlLanguage: NLLanguage? {
        LanguageCatalog.nlMap[code]
    }
}

public enum LanguageCatalog {
    public static let russian = Language(code: "ru", name: "Russian")
    public static let ukrainian = Language(code: "uk", name: "Ukrainian")
    public static let english = Language(code: "en", name: "English")
    public static let dutch = Language(code: "nl", name: "Dutch")

    public static let defaults: [Language] = [ukrainian, english, dutch]

    /// Languages a user can add in Settings.
    public static let all: [Language] = [
        russian, ukrainian, english, dutch,
        Language(code: "de", name: "German"),
        Language(code: "fr", name: "French"),
        Language(code: "es", name: "Spanish"),
        Language(code: "it", name: "Italian"),
        Language(code: "pt", name: "Portuguese"),
        Language(code: "pl", name: "Polish"),
        Language(code: "cs", name: "Czech"),
        Language(code: "sk", name: "Slovak"),
        Language(code: "be", name: "Belarusian"),
        Language(code: "bg", name: "Bulgarian"),
        Language(code: "ro", name: "Romanian"),
        Language(code: "hu", name: "Hungarian"),
        Language(code: "el", name: "Greek"),
        Language(code: "tr", name: "Turkish"),
        Language(code: "sv", name: "Swedish"),
        Language(code: "da", name: "Danish"),
        Language(code: "nb", name: "Norwegian"),
        Language(code: "fi", name: "Finnish"),
        Language(code: "et", name: "Estonian"),
        Language(code: "lv", name: "Latvian"),
        Language(code: "lt", name: "Lithuanian"),
        Language(code: "ka", name: "Georgian"),
        Language(code: "hy", name: "Armenian"),
        Language(code: "he", name: "Hebrew"),
        Language(code: "ar", name: "Arabic"),
        Language(code: "zh", name: "Chinese (Simplified)"),
        Language(code: "ja", name: "Japanese"),
        Language(code: "ko", name: "Korean"),
        Language(code: "id", name: "Indonesian"),
    ]

    public static func language(for code: String) -> Language? {
        all.first { $0.code == code }
    }

    static let nlMap: [String: NLLanguage] = [
        "ru": .russian, "uk": .ukrainian, "en": .english, "nl": .dutch,
        "de": .german, "fr": .french, "es": .spanish, "it": .italian,
        "pt": .portuguese, "pl": .polish, "cs": .czech, "sk": .slovak,
        "bg": .bulgarian, "ro": .romanian, "hu": .hungarian, "el": .greek,
        "tr": .turkish, "sv": .swedish, "da": .danish, "nb": .norwegian,
        "fi": .finnish, "ka": .georgian, "hy": .armenian, "he": .hebrew,
        "ar": .arabic, "zh": .simplifiedChinese, "ja": .japanese, "ko": .korean,
        "id": .indonesian,
        // Not in NLLanguage's predefined list; Apple supports them by raw value.
        "be": NLLanguage("be"), "et": NLLanguage("et"), "lv": NLLanguage("lv"), "lt": NLLanguage("lt"),
    ]
}

/// A directed language pair. `source == nil` means auto-detect.
public struct LanguagePair: Codable, Hashable, Sendable {
    public var source: String?
    public var target: String

    public init(source: String?, target: String) {
        self.source = source
        self.target = target
    }

    public var label: String {
        "\(source?.uppercased() ?? "AUTO") → \(target.uppercased())"
    }

    public static let defaultQuickPairs: [LanguagePair] = [
        .init(source: "uk", target: "en"), .init(source: "en", target: "uk"),
        .init(source: "en", target: "nl"), .init(source: "nl", target: "en"),
    ]
}

public enum Tone: String, Codable, CaseIterable, Sendable {
    case auto, formal, informal

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .formal: "Formal"
        case .informal: "Informal"
        }
    }
}
