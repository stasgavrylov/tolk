import Foundation

public struct ModelChoice: Codable, Hashable, Sendable {
    public var model: String
    /// Reasoning effort ("none", "low", "medium", "high"); nil omits the field.
    public var effort: String?

    public init(model: String, effort: String?) {
        self.model = model
        self.effort = effort
    }

    /// Measured fastest on the ChatGPT Codex endpoint (~1.1 s to first token).
    public static let liveDefault = ModelChoice(model: "gpt-5.6-luna", effort: "low")
    public static let suggestionsDefault = ModelChoice(model: "gpt-5.6-luna", effort: "low")

    /// Models exposed by the ChatGPT subscription Codex endpoint at the time of writing.
    public static let knownModels = [
        "gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol",
        "gpt-6-luna", "gpt-6-sol", "gpt-6-astra", "gpt-6.1-sol",
    ]
    public static let efforts = ["none", "low", "medium", "high"]
}

public struct StructuredFormat: Sendable {
    public var name: String
    public var schema: JSONValue

    public init(name: String, schema: JSONValue) {
        self.name = name
        self.schema = schema
    }
}

public struct LLMRequest: Sendable {
    public var model: ModelChoice
    public var instructions: String
    public var input: String
    public var format: StructuredFormat?

    public init(model: ModelChoice, instructions: String, input: String, format: StructuredFormat? = nil) {
        self.model = model
        self.instructions = instructions
        self.input = input
        self.format = format
    }
}

public enum LLMError: Error, Equatable, LocalizedError {
    case notSignedIn
    case unauthorized
    case usageLimit(message: String, resetsInSeconds: Int?)
    case http(status: Int, message: String)
    case server(code: String?, message: String)
    case invalidResponse(String)

    public var requiresSignIn: Bool {
        switch self {
        case .notSignedIn, .unauthorized: true
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in. Sign in with ChatGPT in Settings → AI."
        case .unauthorized: "ChatGPT session expired. Sign in again in Settings → AI."
        case .usageLimit(let message, let resets):
            if let resets { "Usage limit reached (\(message)). Resets in \(resets / 60) min." }
            else { "Usage limit reached: \(message)" }
        case .http(let status, let message): "OpenAI error \(status): \(message)"
        case .server(_, let message): "OpenAI error: \(message)"
        case .invalidResponse(let detail): "Unexpected response: \(detail)"
        }
    }
}

/// Streaming text generation. The stream yields text deltas.
public protocol LLMProvider: Sendable {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<String, Error>
}

extension LLMProvider {
    public func complete(_ request: LLMRequest) async throws -> String {
        var out = ""
        for try await delta in stream(request) { out += delta }
        return out
    }
}
