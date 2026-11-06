import Foundation
import Network

/// One-shot localhost HTTP listener that receives the OAuth redirect.
public final class OAuthCallbackServer: @unchecked Sendable {
    public enum CallbackError: Error, LocalizedError {
        case portUnavailable(String)
        case stateMismatch
        case denied(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .portUnavailable(let d): "Port \(CodexOAuth.callbackPort) is unavailable (\(d)). Close Codex CLI login, or paste the redirect URL."
            case .stateMismatch: "Login state mismatch. Please try again."
            case .denied(let d): "Login was not completed: \(d)"
            case .cancelled: "Login cancelled."
            }
        }
    }

    private let listener: NWListener
    private let expectedState: String
    private let queue = DispatchQueue(label: "dev.stas.tolk.oauth")
    private var continuation: CheckedContinuation<String, Error>?
    private var pending: Result<String, Error>?
    private var finished = false
    private var startContinuation: CheckedContinuation<Void, Error>?

    public init(state: String, port: UInt16 = CodexOAuth.callbackPort) throws {
        expectedState = state
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            throw CallbackError.portUnavailable(error.localizedDescription)
        }
    }

    /// Starts listening; returns once the listener is ready, failed, or was stopped.
    public func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // All state lives on `queue`, which also runs the listener handlers.
            queue.async {
                guard !self.finished else { cont.resume(throwing: CallbackError.cancelled); return }
                self.startContinuation = cont
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.resumeStart(nil)
                    case .failed(let error):
                        let failure = CallbackError.portUnavailable(error.localizedDescription)
                        if self.startContinuation != nil { self.resumeStart(failure) } else { self.complete(.failure(failure)) }
                    case .cancelled:
                        self.resumeStart(CallbackError.cancelled)
                    default: break
                    }
                }
                self.listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    /// Call on `queue`.
    private func resumeStart(_ error: Error?) {
        guard let start = startContinuation else { return }
        startContinuation = nil
        if let error { start.resume(throwing: error) } else { start.resume() }
    }

    /// Waits for the authorization code.
    public func waitForCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                queue.async {
                    if let pending = self.pending { cont.resume(with: pending) }
                    else { self.continuation = cont }
                }
            }
        } onCancel: {
            self.complete(.failure(CallbackError.cancelled))
        }
    }

    /// Stops listening and releases any caller still waiting in `start()` or `waitForCode()`.
    public func stop() {
        complete(.failure(CallbackError.cancelled))
    }

    private func complete(_ result: Result<String, Error>) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            if let c = self.continuation { self.continuation = nil; c.resume(with: result) }
            else { self.pending = result }
            self.resumeStart(CallbackError.cancelled)
            self.listener.cancel()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let (status, body, result) = self.route(request)
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let result { self.complete(result) }
        }
    }

    /// Pure routing for testability: (HTTP status line, HTML body, completion result if any).
    func route(_ request: String) -> (String, String, Result<String, Error>?) {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])),
              components.path == CodexOAuth.callbackPath
        else { return ("404 Not Found", Self.page("Not found"), nil) }
        let items = components.queryItems ?? []
        func item(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = item("error") {
            let detail = item("error_description") ?? error
            return ("400 Bad Request", Self.page("Sign-in failed: \(detail)"), .failure(CallbackError.denied(detail)))
        }
        guard item("state") == expectedState else {
            return ("400 Bad Request", Self.page("State mismatch. Return to Tolk and try again."), .failure(CallbackError.stateMismatch))
        }
        guard let code = item("code"), !code.isEmpty else {
            return ("400 Bad Request", Self.page("Missing authorization code."), nil)
        }
        return ("200 OK", Self.page("Signed in to Tolk. You can close this tab."), .success(code))
    }

    static func page(_ message: String) -> String {
        let escaped = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return "<!doctype html><html><head><meta charset=utf-8><title>Tolk</title></head><body style=\"font:16px -apple-system;margin:4em;text-align:center\"><h2>\(escaped)</h2></body></html>"
    }
}
