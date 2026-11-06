import Foundation

/// Runs async operations one at a time, in the order they were enqueued. A failing operation
/// does not block later ones; its error goes only to its own caller.
@MainActor
public final class SerialQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    /// Waits until everything enqueued so far has finished.
    public func drain() async {
        await tail?.value
    }
}
