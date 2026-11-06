import Foundation
import Testing
@testable import TolkCore

@Suite struct TokenUsageTests {
    @Test func parsesReportedCountsWithoutDoubleCountingCachedOrReasoningTokens() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"input_tokens":100,"output_tokens":20,"total_tokens":120,"input_tokens_details":{"cached_tokens":40},"output_tokens_details":{"reasoning_tokens":10}}"#.utf8))
        let expected = try TokenUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 40, reasoningOutputTokens: 10)
        #expect(UsageReport.parse(value) == .reported(expected))
        #expect(expected.totalTokens == 120)
    }

    @Test func missingBreakdownsStayUnknownWhileReportedZeroStaysZero() throws {
        let absent = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"input_tokens":0,"output_tokens":0,"input_tokens_details":null}"#.utf8))
        #expect(UsageReport.parse(absent) == .reported(try TokenUsage(inputTokens: 0, outputTokens: 0)))
        let zero = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"input_tokens":0,"output_tokens":0,"input_tokens_details":{"cached_tokens":0}}"#.utf8))
        #expect(UsageReport.parse(zero) == .reported(try TokenUsage(inputTokens: 0, outputTokens: 0, cachedInputTokens: 0)))
        #expect(UsageReport.parse(nil) == .notReported)
        #expect(UsageReport.parse(.null) == .notReported)
    }

    @Test(arguments: [
        #"{}"#,
        #"{"input_tokens":-1,"output_tokens":2}"#,
        #"{"input_tokens":true,"output_tokens":2}"#,
        #"{"input_tokens":1.5,"output_tokens":2}"#,
        #"{"input_tokens":1e100,"output_tokens":2}"#,
        #"{"input_tokens":1,"output_tokens":2,"total_tokens":4}"#,
        #"{"input_tokens":1,"output_tokens":2,"input_tokens_details":{"cached_tokens":2}}"#,
        #"{"input_tokens":1,"output_tokens":2,"output_tokens_details":{"reasoning_tokens":3}}"#,
        #"{"input_tokens":1,"output_tokens":2,"input_tokens_details":"bad"}"#,
    ])
    func rejectsInvalidUsageInsteadOfTurningItIntoMissingOrZero(json: String) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(UsageReport.parse(value) == .invalid)
    }
}

@MainActor @Suite struct UsageStoreTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let firstDay = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aggregatesByDayAndModelAndKeepsCoverageOfOptionalBreakdowns() throws {
        let store = try UsageStore(inMemory: true, calendar: calendar)
        let today = firstDay.addingTimeInterval(86_400)
        store.record(UsageObservation(model: "alpha", report: .reported(try TokenUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 40, reasoningOutputTokens: 10)), finishedAt: firstDay))
        store.record(UsageObservation(model: "alpha", report: .reported(try TokenUsage(inputTokens: 80, outputTokens: 10)), finishedAt: today))
        store.record(UsageObservation(model: "beta", report: .reported(try TokenUsage(inputTokens: 10, outputTokens: 5, cachedInputTokens: 0, reasoningOutputTokens: 0)), finishedAt: today))
        store.record(UsageObservation(model: "beta", report: .notReported, finishedAt: today))
        store.record(UsageObservation(model: "beta", report: .invalid, finishedAt: today))
        #expect(store.error == nil)
        let all = try store.summary(period: .allTime, now: today)
        #expect(all.totals.inputTokens == 190)
        #expect(all.totals.outputTokens == 35)
        #expect(all.totals.totalTokens == 225)
        #expect(all.totals.reportedRequests == 3)
        #expect(all.totals.unreportedRequests == 1)
        #expect(all.totals.invalidUsageRequests == 1)
        #expect(all.totals.cachedInputTokens == 40)
        #expect(all.totals.cachedReports == 2)
        #expect(all.totals.reasoningOutputTokens == 10)
        #expect(all.totals.reasoningReports == 2)
        #expect(all.models.map(\.model) == ["alpha", "beta"])
        #expect(all.models.map { $0.totals.totalTokens } == [210, 15])
        let daily = try store.summary(period: .today, now: today)
        #expect(daily.totals.totalTokens == 105)
        #expect(daily.totals.cachedInputTokens == 0)
        #expect(daily.totals.cachedReports == 1)
        #expect(daily.totals.reportedRequests == 2)
        #expect(try store.summary(period: .today, now: today.addingTimeInterval(86_400)).models.isEmpty)
    }

    @Test func missingUsageDoesNotPretendToBeAReportedZeroTokenResponse() throws {
        let store = try UsageStore(inMemory: true, calendar: calendar)
        store.record(UsageObservation(model: "alpha", report: .notReported, finishedAt: firstDay))
        let missing = try store.summary(period: .allTime)
        #expect(missing.totals.reportedRequests == 0)
        #expect(missing.totals.unreportedRequests == 1)
        store.record(UsageObservation(model: "alpha", report: .reported(try TokenUsage(inputTokens: 0, outputTokens: 0)), finishedAt: firstDay))
        let zero = try store.summary(period: .allTime)
        #expect(zero.totals.reportedRequests == 1)
        #expect(zero.totals.totalTokens == 0)
        #expect(zero.totals.cachedReports == 0)
    }

    @Test func countsSurviveReopeningTheLocalStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Usage.store")
        do {
            let store = try UsageStore(url: url, calendar: calendar)
            store.record(UsageObservation(model: "alpha", report: .reported(try TokenUsage(inputTokens: 7, outputTokens: 3)), finishedAt: firstDay))
            #expect(store.error == nil)
        }
        let reopened = try UsageStore(url: url, calendar: calendar)
        #expect(try reopened.summary(period: .allTime).totals.totalTokens == 10)
        #expect(try reopened.summary(period: .allTime).totals.reportedRequests == 1)
    }

    @Test func aFailedRecordPreservesTotalsAndKeepsItsWarningAfterLaterSuccess() throws {
        let store = try UsageStore(inMemory: true, calendar: calendar)
        store.record(UsageObservation(model: "alpha", report: .reported(try TokenUsage(inputTokens: 7, outputTokens: 3)), finishedAt: firstDay))
        store.record(UsageObservation(model: "alpha", report: .notReported, finishedAt: Date(timeIntervalSince1970: .infinity)))
        #expect(store.error != nil)
        #expect(try store.summary(period: .allTime).totals.totalTokens == 10)
        store.record(UsageObservation(model: "alpha", report: .reported(try TokenUsage(inputTokens: 1, outputTokens: 2)), finishedAt: firstDay))
        #expect(try store.summary(period: .allTime).totals.totalTokens == 13)
        #expect(store.error != nil, "A later save cannot make an earlier dropped observation complete")
    }

    @Test func invalidStoreLocationIsAnErrorNotAnEmptyHistory() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try UsageStore(url: file.appendingPathComponent("Usage.store")) }
    }
}
