import Foundation

/// An in-app keyboard shortcut bound to a menu item (not a global hotkey).
public struct KeyCombo: Codable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// Lowercased NSMenuItem key equivalent ("e", "1", "\r", ...).
    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(key)
    }

    static func keyName(_ key: String) -> String {
        switch key {
        case "\r": "↩"
        case "\t": "⇥"
        case " ": "Space"
        case "\u{1b}": "⎋"
        case "\u{8}", "\u{7f}": "⌫"
        default: key.uppercased()
        }
    }

    /// Shortcuts the standard menus already use; binding an action to one would shadow it.
    public static let reserved: [KeyCombo: String] = [
        KeyCombo("c", .command): "Copy", KeyCombo("v", .command): "Paste", KeyCombo("x", .command): "Cut",
        KeyCombo("a", .command): "Select All", KeyCombo("z", .command): "Undo",
        KeyCombo("z", [.command, .shift]): "Redo", KeyCombo("q", .command): "Quit",
        KeyCombo("w", .command): "Close Window", KeyCombo(",", .command): "Settings…",
        KeyCombo("h", .command): "Hide Tolk", KeyCombo("m", .command): "Minimize",
        KeyCombo("f", .command): "Find", KeyCombo("h", [.command, .option]): "Hide Others",
    ]
}

public enum InAppAction: String, Codable, CaseIterable, Hashable, Sendable {
    case translate, swap, suggestions, history, copyTranslation
    case pair1, pair2, pair3, pair4, pair5, pair6, pair7, pair8, pair9

    public var pairIndex: Int? {
        guard let i = Self.pairs.firstIndex(of: self) else { return nil }
        return i
    }

    public static let pairs: [InAppAction] = [.pair1, .pair2, .pair3, .pair4, .pair5, .pair6, .pair7, .pair8, .pair9]

    public var title: String {
        switch self {
        case .translate: "Translate / Find phrases"
        case .swap: "Swap languages"
        case .suggestions: "Suggest alternatives for selection"
        case .history: "Show history"
        case .copyTranslation: "Copy translation"
        default: "Quick pair \((pairIndex ?? 0) + 1)"
        }
    }

    public var defaultCombo: KeyCombo {
        switch self {
        case .translate: KeyCombo("\r", .command)
        case .swap: KeyCombo("s", [.command, .shift])
        case .suggestions: KeyCombo("e", .command)
        case .history: KeyCombo("y", .command)
        case .copyTranslation: KeyCombo("c", [.command, .shift])
        default: KeyCombo(String((pairIndex ?? 0) + 1), .command)
        }
    }

    public static var defaultBindings: [InAppAction: KeyCombo] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultCombo) })
    }
}

public enum ShortcutConflicts {
    /// Describes why `combo` cannot be bound to `action`, or nil when it is free.
    public static func conflict(for combo: KeyCombo, action: InAppAction, bindings: [InAppAction: KeyCombo]) -> String? {
        if let name = KeyCombo.reserved[combo] { return "\(combo.displayString) is used by \(name)." }
        if let other = bindings.first(where: { $0.key != action && $0.value == combo })?.key {
            return "\(combo.displayString) is already used by “\(other.title)”."
        }
        if combo.modifiers.subtracting(.shift).isEmpty {
            return "Shortcuts need ⌘, ⌥ or ⌃ so they don't interfere with typing."
        }
        return nil
    }
}
