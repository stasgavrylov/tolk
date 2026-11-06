import Foundation
@testable import TolkCore

/// URLProtocol stub keyed per test via a header-free global handler; tests using it are serialized.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        var holdOpen = false
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Response)?
    nonisolated(unsafe) static var received: [URLRequest] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open()
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: 4096)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            buf.deallocate()
            stream.close()
            req.httpBody = data
        }
        Self.received.append(req)
        let r = Self.handler?(req) ?? Response(status: 500, body: Data())
        let http = HTTPURLResponse(url: req.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: r.body)
        if !r.holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}

func sse(_ events: [String]) -> Data {
    Data(events.map { "data: \($0)\n\n" }.joined().utf8)
}

func base64URL(_ s: String) -> String {
    Data(s.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func fakeJWT(_ payloadJSON: String) -> String {
    "\(base64URL("{\"alg\":\"none\"}")).\(base64URL(payloadJSON)).sig"
}

@MainActor
func makeSettings() -> AppSettings {
    let defaults = UserDefaults(suiteName: "tolk-tests-\(UUID().uuidString)")!
    return AppSettings(defaults: defaults)
}
