import Foundation

/// Incremental Server-Sent Events parser. Feed raw bytes; get complete event `data` payloads.
public struct SSEParser: Sendable {
    private var buffer = Data()
    private var dataLines: [String] = []

    public init() {}

    /// Appends bytes and returns the data payloads of every event completed by them.
    public mutating func feed(_ bytes: Data) -> [String] {
        buffer.append(bytes)
        var events: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineData.last == UInt8(ascii: "\r") { lineData = lineData.dropLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            if let event = process(line: line) { events.append(event) }
        }
        return events
    }

    /// Flushes a trailing event not terminated by a blank line.
    public mutating func finish() -> [String] {
        var events: [String] = []
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if let event = process(line: line) { events.append(event) }
        }
        if let event = process(line: "") { events.append(event) }
        return events
    }

    private mutating func process(line: String) -> String? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            defer { dataLines.removeAll() }
            return dataLines.joined(separator: "\n")
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.first == " " { value = value.dropFirst() }
            dataLines.append(String(value))
        }
        // `event:`, `id:` and `retry:` are not needed: Codex repeats the type inside the JSON.
        return nil
    }
}
