import Foundation
import TolkCore

/// Scripted LLM provider: records requests and replays chunked responses.
package final class MockProvider: LLMProvider, @unchecked Sendable {
    package struct Reply: Sendable {
        package var chunks: [String]
        package var delay: Duration = .zero
        package var error: Error?
        package var chunkDelay: Duration = .zero

        package init(chunks: [String], delay: Duration = .zero, error: Error? = nil, chunkDelay: Duration = .zero) {
            self.chunks = chunks
            self.delay = delay
            self.error = error
            self.chunkDelay = chunkDelay
        }
    }

    private let lock = NSLock()
    private var _requests: [LLMRequest] = []
    private let responder: @Sendable (LLMRequest) -> Reply

    package init(responder: @escaping @Sendable (LLMRequest) -> Reply = { _ in Reply(chunks: ["ok"]) }) {
        self.responder = responder
    }

    package var requests: [LLMRequest] { lock.withLock { _requests } }

    package func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _requests.append(request) }
        let reply = responder(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                if reply.delay > .zero { try? await Task.sleep(for: reply.delay) }
                for chunk in reply.chunks {
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                    if reply.chunkDelay > .zero { try? await Task.sleep(for: reply.chunkDelay) }
                }
                if let error = reply.error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Manually completed streams for deterministic cancellation, retry, and stale-result tests.
package final class ControlledProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(LLMRequest, AsyncThrowingStream<String, Error>.Continuation)] = []

    package init() {}
    package var requests: [LLMRequest] { lock.withLock { pending.map(\.0) } }

    package func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { pending.append((request, continuation)) }
        }
    }

    package func finish(_ index: Int, text: String = "", error: Error? = nil) {
        let continuation = lock.withLock { pending[index].1 }
        if !text.isEmpty { continuation.yield(text) }
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
}

/// Polls until `condition` holds or the timeout elapses.
@MainActor
package func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
