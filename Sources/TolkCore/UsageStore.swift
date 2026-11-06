import Foundation
import Observation
import SwiftData

/// One row per local calendar date and requested model, not per prompt or response.
@Model
final class UsageBucket {
    var day: String
    var model: String
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var totalTokens: Int64 = 0
    var cachedInputTokens: Int64 = 0
    var reasoningOutputTokens: Int64 = 0
    var reportedRequests: Int64 = 0
    var unreportedRequests: Int64 = 0
    var invalidUsageRequests: Int64 = 0
    var cachedReports: Int64 = 0
    var reasoningReports: Int64 = 0

    init(day: String, model: String) { self.day = day; self.model = model }

    var totals: UsageTotals {
        get {
            var value = UsageTotals()
            value.inputTokens = inputTokens
            value.outputTokens = outputTokens
            value.totalTokens = totalTokens
            value.cachedInputTokens = cachedInputTokens
            value.reasoningOutputTokens = reasoningOutputTokens
            value.reportedRequests = reportedRequests
            value.unreportedRequests = unreportedRequests
            value.invalidUsageRequests = invalidUsageRequests
            value.cachedReports = cachedReports
            value.reasoningReports = reasoningReports
            return value
        }
        set {
            inputTokens = newValue.inputTokens
            outputTokens = newValue.outputTokens
            totalTokens = newValue.totalTokens
            cachedInputTokens = newValue.cachedInputTokens
            reasoningOutputTokens = newValue.reasoningOutputTokens
            reportedRequests = newValue.reportedRequests
            unreportedRequests = newValue.unreportedRequests
            invalidUsageRequests = newValue.invalidUsageRequests
            cachedReports = newValue.cachedReports
            reasoningReports = newValue.reasoningReports
        }
    }
}

@MainActor @Observable
public final class UsageStore {
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let calendar: Calendar
    public private(set) var revision = 0
    public private(set) var error: String?

    public convenience init(inMemory: Bool = false, fileName: String = "Usage.store",
                            calendar: Calendar = .autoupdatingCurrent) throws {
        if inMemory {
            try self.init(configuration: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none), calendar: calendar)
        } else {
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Tolk", isDirectory: true).appendingPathComponent(fileName)
            try self.init(url: url, calendar: calendar)
        }
    }

    public convenience init(url: URL, calendar: Calendar = .autoupdatingCurrent) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(configuration: ModelConfiguration(url: url, cloudKitDatabase: .none), calendar: calendar)
    }

    private init(configuration: ModelConfiguration, calendar: Calendar) throws {
        self.calendar = calendar
        container = try ModelContainer(for: UsageBucket.self, configurations: configuration)
    }

    public func record(_ observation: UsageObservation) {
        let context = container.mainContext
        do {
            guard !observation.model.isEmpty else { throw UsageDataError.invalidCounts }
            let day = try dayKey(observation.finishedAt)
            let model = observation.model
            let descriptor = FetchDescriptor<UsageBucket>(predicate: #Predicate { $0.day == day && $0.model == model })
            let existing = try context.fetch(descriptor)
            guard existing.count <= 1 else { throw UsageDataError.invalidCounts }
            let bucket = existing.first ?? UsageBucket(day: day, model: model)
            var totals = bucket.totals
            try totals.add(observation.report)
            if existing.isEmpty { context.insert(bucket) }
            bucket.totals = totals
            try context.save()
            // A later successful save cannot fill a gap left by a failed observation.
            revision += 1
        } catch {
            context.rollback()
            self.error = "Could not save usage. Recent counts may be incomplete: \(error.localizedDescription)"
        }
    }

    public func summary(period: UsagePeriod, now: Date = Date()) throws -> UsageSummary {
        // Give SwiftUI observation a stable invalidation point after saves.
        _ = revision
        let predicate: Predicate<UsageBucket>?
        if period == .today {
            let day = try dayKey(now)
            predicate = #Predicate { $0.day == day }
        } else { predicate = nil }
        let buckets = try container.mainContext.fetch(FetchDescriptor<UsageBucket>(predicate: predicate))
        var total = UsageTotals()
        var byModel: [String: UsageTotals] = [:]
        for bucket in buckets {
            try total.merge(bucket.totals)
            var modelTotal = byModel[bucket.model] ?? UsageTotals()
            try modelTotal.merge(bucket.totals)
            byModel[bucket.model] = modelTotal
        }
        let models = byModel.sorted { $0.key < $1.key }.map { ModelUsageSummary(model: $0.key, totals: $0.value) }
        return UsageSummary(totals: total, models: models)
    }

    private func dayKey(_ date: Date) throws -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw UsageDataError.invalidDate }
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard let era = parts.era, let year = parts.year, let month = parts.month, let day = parts.day else {
            throw UsageDataError.invalidDate
        }
        return "\(era)-\(year)-\(month)-\(day)"
    }
}
