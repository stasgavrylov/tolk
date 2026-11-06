import Foundation
import Observation

/// User preferences, persisted in UserDefaults as JSON per key.
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public var enabledLanguages: [Language] { didSet { save(enabledLanguages, "enabledLanguages") } }
    public var quickPairs: [LanguagePair] { didSet { save(quickPairs, "quickPairs") } }
    public var liveModel: ModelChoice { didSet { save(liveModel, "liveModel") } }
    public var suggestionsModel: ModelChoice { didSet { save(suggestionsModel, "suggestionsModel") } }
    public var liveTranslation: Bool { didSet { save(liveTranslation, "liveTranslation") } }
    public var debounceMilliseconds: Int { didSet { save(debounceMilliseconds, "debounceMilliseconds") } }
    public var tonePerTarget: [String: Tone] { didSet { save(tonePerTarget, "tonePerTarget") } }
    public var historyPaused: Bool { didSet { save(historyPaused, "historyPaused") } }
    public var hideDockIcon: Bool { didSet { save(hideDockIcon, "hideDockIcon") } }
    public var bindings: [InAppAction: KeyCombo] {
        didSet {
            save(bindings, "bindings")
            // Remember deliberately cleared actions, so defaults only fill in actions that were never saved.
            save(InAppAction.allCases.filter { bindings[$0] == nil }.map(\.rawValue), "unboundActions")
        }
    }
    public var doubleCopyTrigger: Bool { didSet { save(doubleCopyTrigger, "doubleCopyTrigger") } }
    public var lastSource: String? { didSet { save(lastSource, "lastSource") } }
    public var lastTarget: String { didSet { save(lastTarget, "lastTarget") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func load<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: "tolk." + key),
                  let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
            return value
        }
        enabledLanguages = load("enabledLanguages", LanguageCatalog.defaults)
        quickPairs = load("quickPairs", LanguagePair.defaultQuickPairs)
        liveModel = load("liveModel", .liveDefault)
        suggestionsModel = load("suggestionsModel", .suggestionsDefault)
        liveTranslation = load("liveTranslation", true)
        debounceMilliseconds = load("debounceMilliseconds", 500)
        tonePerTarget = load("tonePerTarget", [:])
        historyPaused = load("historyPaused", false)
        hideDockIcon = load("hideDockIcon", false)
        let unbound = Set(load("unboundActions", [String]()))
        bindings = InAppAction.defaultBindings.filter { !unbound.contains($0.key.rawValue) }
            .merging(load("bindings", [:])) { _, stored in stored }
        doubleCopyTrigger = load("doubleCopyTrigger", false)
        lastSource = load("lastSource", nil)
        lastTarget = load("lastTarget", "en")
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "tolk." + key) }
    }

    public func language(_ code: String) -> Language {
        enabledLanguages.first { $0.code == code } ?? LanguageCatalog.language(for: code)
            ?? Language(code: code, name: code)
    }

    public func tone(for target: String) -> Tone { tonePerTarget[target] ?? .auto }

    public func setTone(_ tone: Tone, for target: String) { tonePerTarget[target] = tone }

    /// Pairs whose languages are all still enabled; the ⌘1…⌘9 slots map onto this list.
    public var activeQuickPairs: [LanguagePair] {
        let codes = Set(enabledLanguages.map(\.code))
        return quickPairs.filter { ($0.source.map(codes.contains) ?? true) && codes.contains($0.target) }
    }

    public func resetBindings() { bindings = InAppAction.defaultBindings }
}
