import Foundation

public enum UsageDataError: Error {
    case invalidCounts, counterOverflow, invalidDate
}

public struct TokenUsage: Equatable, Sendable {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let totalTokens: Int64
    public let cachedInputTokens: Int64?
    public let reasoningOutputTokens: Int64?

    public init(inputTokens: Int64, outputTokens: Int64, totalTokens: Int64? = nil,
                cachedInputTokens: Int64? = nil, reasoningOutputTokens: Int64? = nil) throws {
        let sum = inputTokens.addingReportingOverflow(outputTokens)
        guard inputTokens >= 0, outputTokens >= 0, !sum.overflow,
              totalTokens == nil || totalTokens == sum.partialValue,
              cachedInputTokens.map({ $0 >= 0 && $0 <= inputTokens }) != false,
              reasoningOutputTokens.map({ $0 >= 0 && $0 <= outputTokens }) != false
        else { throw UsageDataError.invalidCounts }
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = sum.partialValue
        self.cachedInputTokens = cachedInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }
}

/// Accounting metadata must never turn a successful translation into a failure.
/// Invalid metadata remains distinguishable from an absent report.
public enum UsageReport: Equatable, Sendable {
    case reported(TokenUsage)
    case notReported
    case invalid

    public static func parse(_ value: JSONValue?) -> UsageReport {
        guard let value, value != .null else { return .notReported }
        do {
            guard case .object = value,
                  let input = try integer(value["input_tokens"]),
                  let output = try integer(value["output_tokens"]) else { return .invalid }
            return .reported(try TokenUsage(
                inputTokens: input, outputTokens: output, totalTokens: integer(value["total_tokens"]),
                cachedInputTokens: detail(value["input_tokens_details"], key: "cached_tokens"),
                reasoningOutputTokens: detail(value["output_tokens_details"], key: "reasoning_tokens")))
        } catch { return .invalid }
    }

    private static func integer(_ value: JSONValue?) throws -> Int64? {
        guard let value, value != .null else { return nil }
        // JSONValue stores doubles: reject counts beyond their exact-integer range.
        guard let number = value.numberValue, number >= 0, number <= 9_007_199_254_740_991,
              let integer = Int64(exactly: number) else { throw UsageDataError.invalidCounts }
        return integer
    }

    private static func detail(_ value: JSONValue?, key: String) throws -> Int64? {
        guard let value, value != .null else { return nil }
        guard case .object = value else { throw UsageDataError.invalidCounts }
        return try integer(value[key])
    }
}

/// No prompts, generated text, credentials, or account identifiers enter the usage store.
public struct UsageObservation: Sendable {
    public let model: String
    public let report: UsageReport
    public let finishedAt: Date

    public init(model: String, report: UsageReport, finishedAt: Date = Date()) {
        self.model = model
        self.report = report
        self.finishedAt = finishedAt
    }
}

public enum UsagePeriod: String, CaseIterable, Sendable {
    case today, allTime
    public var title: String { self == .today ? "Today" : "All time" }
}

public struct UsageTotals: Equatable, Sendable {
    public internal(set) var inputTokens: Int64 = 0
    public internal(set) var outputTokens: Int64 = 0
    public internal(set) var totalTokens: Int64 = 0
    public internal(set) var cachedInputTokens: Int64 = 0
    public internal(set) var reasoningOutputTokens: Int64 = 0
    public internal(set) var reportedRequests: Int64 = 0
    public internal(set) var unreportedRequests: Int64 = 0
    public internal(set) var invalidUsageRequests: Int64 = 0
    public internal(set) var cachedReports: Int64 = 0
    public internal(set) var reasoningReports: Int64 = 0

    public init() {}

    mutating func add(_ report: UsageReport) throws {
        var change = UsageTotals()
        switch report {
        case .notReported: change.unreportedRequests = 1
        case .invalid: change.invalidUsageRequests = 1
        case .reported(let usage):
            change.reportedRequests = 1
            change.inputTokens = usage.inputTokens
            change.outputTokens = usage.outputTokens
            change.totalTokens = usage.totalTokens
            if let cached = usage.cachedInputTokens {
                change.cachedInputTokens = cached
                change.cachedReports = 1
            }
            if let reasoning = usage.reasoningOutputTokens {
                change.reasoningOutputTokens = reasoning
                change.reasoningReports = 1
            }
        }
        try merge(change)
    }

    mutating func merge(_ other: UsageTotals) throws {
        let fields: [WritableKeyPath<UsageTotals, Int64>] = [
            \.inputTokens, \.outputTokens, \.totalTokens, \.cachedInputTokens, \.reasoningOutputTokens,
            \.reportedRequests, \.unreportedRequests, \.invalidUsageRequests, \.cachedReports, \.reasoningReports,
        ]
        for field in fields {
            guard other[keyPath: field] >= 0 else { throw UsageDataError.invalidCounts }
            let sum = self[keyPath: field].addingReportingOverflow(other[keyPath: field])
            guard !sum.overflow else { throw UsageDataError.counterOverflow }
            self[keyPath: field] = sum.partialValue
        }
    }
}

public struct ModelUsageSummary: Identifiable, Sendable {
    public let model: String
    public let totals: UsageTotals
    public var id: String { model }
}

public struct UsageSummary: Sendable {
    public let totals: UsageTotals
    public let models: [ModelUsageSummary]
}
