import Foundation

public struct CodexAuth: Sendable, Equatable {
    public var accessToken: String
    public var accountId: String

    public init(accessToken: String, accountId: String) {
        self.accessToken = accessToken
        self.accountId = accountId
    }
}

/// Supplies ChatGPT credentials to the Codex client.
public protocol CodexCredentialSource: Sendable {
    /// A currently valid token, refreshed proactively when close to expiry.
    func currentAuth() async throws -> CodexAuth
    /// Called after a 401: force a refresh, or throw `LLMError.unauthorized`.
    func authAfterUnauthorized() async throws -> CodexAuth
}

/// Client for the ChatGPT-subscription Codex Responses endpoint (SSE streaming).
public struct CodexClient: LLMProvider {
    public static let defaultURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

    let credentials: CodexCredentialSource
    let session: URLSession
    let url: URL
    private let onUsage: (@Sendable (UsageObservation) async -> Void)?

    public init(credentials: CodexCredentialSource, session: URLSession = .shared, url: URL = CodexClient.defaultURL,
                onUsage: (@Sendable (UsageObservation) async -> Void)? = nil) {
        self.credentials = credentials
        self.session = session
        self.url = url
        self.onUsage = onUsage
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func body(for request: LLMRequest) throws -> Data {
        var text: [String: JSONValue] = ["verbosity": "low"]
        if let format = request.format {
            text["format"] = [
                "type": "json_schema", "name": .string(format.name), "schema": format.schema, "strict": true,
            ]
        }
        var body: [String: JSONValue] = [
            "model": .string(request.model.model),
            "store": false,
            "stream": true,
            "instructions": .string(request.instructions),
            "input": [
                ["role": "user", "content": [["type": "input_text", "text": .string(request.input)]]],
            ],
            "text": .object(text),
        ]
        if let effort = request.model.effort { body["reasoning"] = ["effort": .string(effort)] }
        return try JSONEncoder().encode(JSONValue.object(body))
    }

    func urlRequest(_ request: LLMRequest, auth: CodexAuth) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue(auth.accountId, forHTTPHeaderField: "chatgpt-account-id")
        r.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("tolk", forHTTPHeaderField: "originator")
        r.httpBody = try Self.body(for: request)
        return r
    }

    private func run(_ request: LLMRequest, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        var started = false
        var usage: UsageReport?
        let outcome: Result<Void, Error>
        do {
            var auth = try await credentials.currentAuth()
            let initialRequest = try urlRequest(request, auth: auth)
            started = true
            var (bytes, response) = try await session.bytes(for: initialRequest)
            if (response as? HTTPURLResponse)?.statusCode == 401 {
                auth = try await credentials.authAfterUnauthorized()
                (bytes, response) = try await session.bytes(for: urlRequest(request, auth: auth))
            }
            guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse("no HTTP response") }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 64_000 { break }
                }
                throw Self.httpError(status: http.statusCode, body: data)
            }

            var parser = SSEParser()
            var line = Data()
            var completed = false
            func handle(_ payloads: [String]) throws {
                for payload in payloads {
                    if try Self.handleEvent(payload, continuation: continuation, onUsage: { report in
                        // Aliased/duplicate terminal events are not additional requests.
                        // Prefer a usable report if an earlier alias omitted its metadata.
                        if case .reported? = usage { return }
                        if report != .notReported || usage == nil { usage = report }
                    }) { completed = true }
                }
            }
            for try await byte in bytes {
                line.append(byte)
                if byte == UInt8(ascii: "\n") {
                    try handle(parser.feed(line))
                    line.removeAll(keepingCapacity: true)
                }
            }
            try handle(parser.feed(line))
            try handle(parser.finish())
            try Task.checkCancellation()
            if !completed { throw LLMError.invalidResponse("stream ended before completion") }
            outcome = .success(())
        } catch { outcome = .failure(error) }
        // Do this before finishing the text stream, including on cancellation/failure.
        // Missing credentials never started a network request and must not inflate coverage gaps.
        if started, let onUsage {
            await onUsage(UsageObservation(model: request.model.model, report: usage ?? .notReported))
        }
        try outcome.get()
    }

    /// Returns true when the event marks the end of the response.
    static func handleEvent(_ payload: String, continuation: AsyncThrowingStream<String, Error>.Continuation,
                            onUsage: ((UsageReport) -> Void)? = nil) throws -> Bool {
        guard payload != "[DONE]" else { return true }
        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return false }
        switch event["type"]?.stringValue {
        case "response.output_text.delta":
            if let delta = event["delta"]?.stringValue { continuation.yield(delta) }
        case "response.completed", "response.done":
            onUsage?(usageReport(in: event))
            return true
        case "response.incomplete":
            onUsage?(usageReport(in: event))
            let reason = event["response"]?["incomplete_details"]?["reason"]?.stringValue ?? "unknown"
            throw LLMError.server(code: "incomplete", message: "Response incomplete (\(reason))")
        case "response.failed":
            onUsage?(usageReport(in: event))
            let error = event["response"]?["error"]
            throw serverError(code: error?["code"]?.stringValue, message: error?["message"]?.stringValue)
        case "error":
            let error = event["error"] ?? event
            throw serverError(code: error["code"]?.stringValue, message: error["message"]?.stringValue)
        default:
            break
        }
        return false
    }

    private static func usageReport(in event: JSONValue) -> UsageReport {
        guard let response = event["response"], response != .null else { return .notReported }
        guard case .object = response else { return .invalid }
        return UsageReport.parse(response["usage"])
    }

    static func serverError(code: String?, message: String?) -> LLMError {
        if let code, ["usage_limit_reached", "usage_not_included", "rate_limit_exceeded"].contains(code) {
            return .usageLimit(message: message ?? code, resetsInSeconds: nil)
        }
        return .server(code: code, message: message ?? code ?? "unknown error")
    }

    static func httpError(status: Int, body: Data) -> LLMError {
        let json = try? JSONDecoder().decode(JSONValue.self, from: body)
        let error = json?["error"]
        let message = error?["message"]?.stringValue ?? json?["detail"]?.stringValue
            ?? String(decoding: body.prefix(500), as: UTF8.self)
        let type = error?["type"]?.stringValue ?? error?["code"]?.stringValue
        if status == 401 { return .unauthorized }
        if status == 429 || type == "usage_limit_reached" || type == "usage_not_included" {
            let resets = error?["resets_in_seconds"]?.numberValue.map { Int($0) }
            return .usageLimit(message: message, resetsInSeconds: resets)
        }
        return .http(status: status, message: message)
    }
}
