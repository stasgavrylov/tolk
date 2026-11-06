import Foundation
import SwiftData

@Model
public final class HistoryEntry {
    public var id: UUID
    public var sourceText: String
    public var translation: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var toneRaw: String
    public var createdAt: Date
    public var starred: Bool

    public init(sourceText: String, translation: String, sourceLanguage: String, targetLanguage: String,
                tone: Tone, createdAt: Date = Date(), starred: Bool = false) {
        id = UUID()
        self.sourceText = sourceText
        self.translation = translation
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        toneRaw = tone.rawValue
        self.createdAt = createdAt
        self.starred = starred
    }

    public var tone: Tone { Tone(rawValue: toneRaw) ?? .auto }
}

public struct HistoryCandidate: Equatable, Sendable {
    public var sourceText: String
    public var translation: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var tone: Tone

    public init(sourceText: String, translation: String, sourceLanguage: String, targetLanguage: String, tone: Tone) {
        self.sourceText = sourceText
        self.translation = translation
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.tone = tone
    }
}

public enum HistoryDecision: Equatable {
    case skip
    case insert
    /// Overwrite and bump the existing entry with the same text and target language.
    case updateMatch
    /// Overwrite the most recent entry: the user kept editing the same text.
    case updateLatest
}

public enum HistoryPolicy {
    /// Window in which a continued edit of the same text replaces the latest entry instead of adding one.
    public static let editWindow: TimeInterval = 120

    /// - Parameters:
    ///   - latest: the most recent entry.
    ///   - match: an entry (any age) with the same trimmed source text and target language.
    public static func decide(_ candidate: HistoryCandidate, latest: HistoryEntry?, match: HistoryEntry? = nil,
                              now: Date = Date()) -> HistoryDecision {
        let source = candidate.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = candidate.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        // An echo (text already in the target language) is not a translation worth keeping.
        guard !source.isEmpty, !translation.isEmpty, source != translation else { return .skip }
        if let match {
            let unchanged = match.translation == candidate.translation && match.toneRaw == candidate.tone.rawValue
            return unchanged && match === latest ? .skip : .updateMatch
        }
        guard let latest else { return .insert }
        let latestSource = latest.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recent = now.timeIntervalSince(latest.createdAt) < editWindow
        if latest.targetLanguage == candidate.targetLanguage, recent, !latest.starred,
           isContinuedEdit(from: latestSource, to: source) {
            return .updateLatest
        }
        return .insert
    }

    /// The new text extends, shortens, or slightly corrects the previous one.
    static func isContinuedEdit(from old: String, to new: String) -> Bool {
        if new.hasPrefix(old) || old.hasPrefix(new) { return true }
        let common = zip(old, new).prefix { $0 == $1 }.count
        let shorter = min(old.count, new.count)
        return shorter >= 8 && Double(common) / Double(shorter) >= 0.6
    }
}

@MainActor
public final class HistoryStore {
    public let container: ModelContainer
    public var context: ModelContext { container.mainContext }

    public init(inMemory: Bool = false, fileName: String = "History.store") throws {
        let config = inMemory
            ? ModelConfiguration(isStoredInMemoryOnly: true)
            : ModelConfiguration(url: Self.storeURL(fileName))
        container = try ModelContainer(for: HistoryEntry.self, configurations: config)
    }

    static func storeURL(_ fileName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tolk", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName)
    }

    public func latest() throws -> HistoryEntry? {
        var d = FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    func match(for candidate: HistoryCandidate) throws -> HistoryEntry? {
        let target = candidate.targetLanguage
        let source = candidate.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Narrow in the store by target, compare trimmed text here (predicates cannot trim).
        let sameTarget = try context.fetch(FetchDescriptor<HistoryEntry>(
            predicate: #Predicate { $0.targetLanguage == target && $0.sourceText.contains(source) },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
        return sameTarget.first { $0.sourceText.trimmingCharacters(in: .whitespacesAndNewlines) == source }
    }

    @discardableResult
    public func record(_ candidate: HistoryCandidate, now: Date = Date()) throws -> HistoryDecision {
        let latest = try latest()
        let match = try match(for: candidate)
        let decision = HistoryPolicy.decide(candidate, latest: latest, match: match, now: now)
        let existing: HistoryEntry?
        switch decision {
        case .skip: return .skip
        case .insert:
            context.insert(HistoryEntry(
                sourceText: candidate.sourceText, translation: candidate.translation,
                sourceLanguage: candidate.sourceLanguage, targetLanguage: candidate.targetLanguage,
                tone: candidate.tone, createdAt: now))
            existing = nil
        case .updateMatch: existing = match
        case .updateLatest: existing = latest
        }
        if let existing {
            existing.sourceText = candidate.sourceText
            existing.translation = candidate.translation
            existing.sourceLanguage = candidate.sourceLanguage
            existing.toneRaw = candidate.tone.rawValue
            existing.createdAt = now
        }
        try context.save()
        return decision
    }

    public func entries(matching query: String = "", starredOnly: Bool = false) throws -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let predicate: Predicate<HistoryEntry>
        switch (q.isEmpty, starredOnly) {
        case (true, false): predicate = #Predicate { _ in true }
        case (true, true): predicate = #Predicate { $0.starred }
        case (false, false):
            predicate = #Predicate { $0.sourceText.localizedStandardContains(q) || $0.translation.localizedStandardContains(q) }
        case (false, true):
            predicate = #Predicate {
                $0.starred && ($0.sourceText.localizedStandardContains(q) || $0.translation.localizedStandardContains(q))
            }
        }
        return try context.fetch(FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    public func delete(_ entry: HistoryEntry) throws {
        context.delete(entry)
        try context.save()
    }

    public func clearAll(keepStarred: Bool = false) throws {
        if keepStarred {
            try context.delete(model: HistoryEntry.self, where: #Predicate { !$0.starred })
        } else {
            try context.delete(model: HistoryEntry.self)
        }
        try context.save()
    }

    public func toggleStar(_ entry: HistoryEntry) throws {
        entry.starred.toggle()
        try context.save()
    }
}
