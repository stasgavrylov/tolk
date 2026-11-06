import Foundation
import Testing
import TolkTestSupport
@testable import TolkCore

struct FixedCredentials: CodexCredentialSource {
    var first = CodexAuth(accessToken: "tok1", accountId: "acct")
    var second: CodexAuth? = CodexAuth(accessToken: "tok2", accountId: "acct")
    func currentAuth() async throws -> CodexAuth { first }
    func authAfterUnauthorized() async throws -> CodexAuth {
        guard let second else { throw LLMError.unauthorized }
        return second
    }
}

/// URLProtocol stubs share global state, so every suite using them is nested here and runs serially.
@Suite(.serialized) struct StubbedNetworkTests {
@Suite struct CodexClientTests {
    let request = LLMRequest(model: ModelChoice(model: "gpt-5.6-luna", effort: "low"), instructions: "sys", input: "hello")

    func client(_ creds: FixedCredentials = FixedCredentials()) -> CodexClient {
        CodexClient(credentials: creds, session: StubURLProtocol.session())
    }

    @Test func streamsDeltasAndSendsCodexHeaders() async throws {
        StubURLProtocol.received = []
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: sse([
                #"{"type":"response.created"}"#,
                #"{"type":"response.output_text.delta","delta":"Hal"}"#,
                #"{"type":"response.output_text.delta","delta":"lo"}"#,
                #"{"type":"response.completed","response":{}}"#,
            ]))
        }
        var deltas: [String] = []
        for try await d in client().stream(request) { deltas.append(d) }
        #expect(deltas == ["Hal", "lo"])
        let sent = try #require(StubURLProtocol.received.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer tok1")
        #expect(sent.value(forHTTPHeaderField: "chatgpt-account-id") == "acct")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(sent.httpBody))
        #expect(body["store"] == .bool(false))
        #expect(body["stream"] == .bool(true))
        #expect(body["model"]?.stringValue == "gpt-5.6-luna")
        #expect(body["reasoning"]?["effort"]?.stringValue == "low")
        #expect(body["instructions"]?.stringValue == "sys")
        #expect(body["input"] == [["role": "user", "content": [["type": "input_text", "text": "hello"]]]])
    }

    @Test func structuredFormatIsSentAsStrictJSONSchema() throws {
        let req = LLMRequest(model: .liveDefault, instructions: "i", input: "x",
                             format: StructuredFormat(name: "s", schema: ["type": "object"]))
        let body = try JSONDecoder().decode(JSONValue.self, from: CodexClient.body(for: req))
        #expect(body["text"]?["format"] == ["type": "json_schema", "name": "s", "schema": ["type": "object"], "strict": true])
        let noEffort = LLMRequest(model: ModelChoice(model: "m", effort: nil), instructions: "i", input: "x")
        #expect(try JSONDecoder().decode(JSONValue.self, from: CodexClient.body(for: noEffort))["reasoning"] == nil)
    }

    @Test func retriesOnceWithRefreshedTokenAfter401() async throws {
        StubURLProtocol.received = []
        StubURLProtocol.handler = { req in
            req.value(forHTTPHeaderField: "Authorization") == "Bearer tok1"
                ? .init(status: 401, body: Data("{}".utf8))
                : .init(status: 200, body: sse([#"{"type":"response.output_text.delta","delta":"ok"}"#, #"{"type":"response.completed"}"#]))
        }
        let out = try await client().complete(request)
        #expect(out == "ok")
        #expect(StubURLProtocol.received.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer tok1", "Bearer tok2"])
    }

    @Test func usageLimitHTTPErrorIsTyped() async {
        StubURLProtocol.handler = { _ in
            .init(status: 429, body: Data(#"{"error":{"type":"usage_limit_reached","message":"limit","resets_in_seconds":600}}"#.utf8))
        }
        await #expect(throws: LLMError.usageLimit(message: "limit", resetsInSeconds: 600)) {
            _ = try await client().complete(request)
        }
    }

    @Test func failedEventSurfacesServerError() async {
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: sse([#"{"type":"response.failed","response":{"error":{"code":"server_error","message":"boom"}}}"#]))
        }
        await #expect(throws: LLMError.server(code: "server_error", message: "boom")) {
            _ = try await client().complete(request)
        }
    }

    @MainActor @Test func recordsUsageOnceForDuplicateTerminalEvents() async throws {
        let usage = try UsageStore(inMemory: true)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: sse([
                #"{"type":"response.output_text.delta","delta":"ok"}"#,
                #"{"type":"response.completed","response":{"usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}"#,
                #"{"type":"response.done","response":{"usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}"#,
            ]))
        }
        let client = CodexClient(credentials: FixedCredentials(), session: StubURLProtocol.session(), onUsage: { await usage.record($0) })
        #expect(try await client.complete(request) == "ok")
        let summary = try usage.summary(period: .allTime)
        #expect(summary.totals.reportedRequests == 1)
        #expect(summary.totals.totalTokens == 120)
        #expect(summary.models.map(\.model) == [request.model.model])
    }

    @MainActor @Test func malformedUsageDoesNotBreakTranslatedText() async throws {
        let usage = try UsageStore(inMemory: true)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: sse([
                #"{"type":"response.output_text.delta","delta":"ok"}"#,
                #"{"type":"response.completed","response":{"usage":{"input_tokens":-1,"output_tokens":3}}}"#,
            ]))
        }
        let client = CodexClient(credentials: FixedCredentials(), session: StubURLProtocol.session(), onUsage: { await usage.record($0) })
        #expect(try await client.complete(request) == "ok")
        let summary = try usage.summary(period: .allTime)
        #expect(summary.totals.invalidUsageRequests == 1)
        #expect(summary.totals.reportedRequests == 0)
        #expect(summary.totals.unreportedRequests == 0)
    }

    @MainActor @Test func missingUsageAndPrematureEOFRemainUnreported() async throws {
        let usage = try UsageStore(inMemory: true)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: sse([#"{"type":"response.completed","response":{}}"#]))
        }
        let client = CodexClient(credentials: FixedCredentials(), session: StubURLProtocol.session(), onUsage: { await usage.record($0) })
        _ = try await client.complete(request)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: sse([#"{"type":"response.output_text.delta","delta":"partial"}"#]))
        }
        await #expect(throws: LLMError.self) { _ = try await client.complete(request) }
        let summary = try usage.summary(period: .allTime)
        #expect(summary.totals.unreportedRequests == 2)
        #expect(summary.totals.reportedRequests == 0)
    }

    @MainActor @Test func stoppingTranslationRecordsTheInterruptedRequestWithoutInventingTokens() async throws {
        let usage = try UsageStore(inMemory: true)
        let started = ResultBox<Void>()
        StubURLProtocol.handler = { _ in
            started.lock.withLock { started.value = .success(()) }
            // Hold the response before its first delta so Stop exercises in-flight cancellation.
            return .init(status: 200, body: Data(), headers: ["Content-Type": "text/event-stream"], holdOpen: true)
        }
        let client = CodexClient(credentials: FixedCredentials(), session: StubURLProtocol.session(), onUsage: { await usage.record($0) })
        let settings = makeSettings()
        settings.liveTranslation = false
        let translator = TranslatorModel(settings: settings, provider: client)
        translator.load(text: "hello", source: .language("en"), target: "nl", translation: "Previous result")
        translator.translateNow()
        #expect(await eventually { started.lock.withLock { started.value != nil } })
        translator.stop()
        #expect(await eventually { (try? usage.summary(period: .allTime).totals.unreportedRequests) == 1 })
        #expect(try usage.summary(period: .allTime).totals.reportedRequests == 0)
        #expect(translator.translation == "Previous result")
    }

    @MainActor @Test func incompleteResponsesCanStillReportSpentTokens() async throws {
        let usage = try UsageStore(inMemory: true)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: sse([
                #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"},"usage":{"input_tokens":7,"output_tokens":3}}}"#,
            ]))
        }
        let client = CodexClient(credentials: FixedCredentials(), session: StubURLProtocol.session(), onUsage: { await usage.record($0) })
        await #expect(throws: LLMError.server(code: "incomplete", message: "Response incomplete (max_output_tokens)")) {
            _ = try await client.complete(request)
        }
        #expect(try usage.summary(period: .allTime).totals.totalTokens == 10)
        #expect(try usage.summary(period: .allTime).totals.reportedRequests == 1)
    }

    @MainActor @Test func authRetryCountsOneLogicalRequestAndSignedOutDoesNotCount() async throws {
        let usage = try UsageStore(inMemory: true)
        StubURLProtocol.handler = { req in
            req.value(forHTTPHeaderField: "Authorization") == "Bearer tok1"
                ? .init(status: 401, body: Data("{}".utf8))
                : .init(status: 200, body: sse([#"{"type":"response.completed","response":{"usage":{"input_tokens":7,"output_tokens":3}}}"#]))
        }
        let client = CodexClient(credentials: FixedCredentials(), session: StubURLProtocol.session(), onUsage: { await usage.record($0) })
        _ = try await client.complete(request)
        let signedOut = CodexClient(credentials: AuthManager(store: InMemoryCredentialStore()), session: StubURLProtocol.session(), onUsage: { await usage.record($0) })
        await #expect(throws: LLMError.notSignedIn) { _ = try await signedOut.complete(request) }
        let summary = try usage.summary(period: .allTime)
        #expect(summary.totals.reportedRequests == 1)
        #expect(summary.totals.unreportedRequests == 0)
        #expect(summary.totals.totalTokens == 10)
    }

    @Test func streamWithoutCompletionIsAnError() async {
        StubURLProtocol.handler = { _ in .init(status: 200, body: sse([#"{"type":"response.output_text.delta","delta":"par"}"#])) }
        await #expect(throws: LLMError.self) { _ = try await client().complete(request) }
    }
}

@Suite struct OAuthTests {
    @Test func pkceChallengeMatchesRFC7636Example() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func authorizationURLCarriesPKCEAndState() throws {
        let p = PKCE(verifier: "v")
        let url = CodexOAuth.authorizationURL(pkce: p, state: "st")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        #expect(url.host == "auth.openai.com")
        #expect(q("code_challenge") == p.challenge)
        #expect(q("code_challenge_method") == "S256")
        #expect(q("state") == "st")
        #expect(q("redirect_uri") == "http://localhost:1455/auth/callback")
        #expect(q("client_id") == "app_EMoamEEZ73f0CkXaXp7hrann")
    }

    @Test(arguments: [
        ("http://localhost:1455/auth/callback?code=abc&state=s1", "abc", "s1"),
        ("abc#s1", "abc", "s1"),
        ("code=abc&state=s1", "abc", "s1"),
        ("abc", "abc", nil),
    ] as [(String, String, String?)])
    func parsesPastedAuthorizationInput(input: String, code: String, state: String?) {
        let r = CodexOAuth.parseAuthorizationInput(input)
        #expect(r.code == code)
        #expect(r.state == state)
    }

    @Test func tokenResponseYieldsAccountIdAndExpiry() throws {
        let access = fakeJWT(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acc-9"}}"#)
        let id = fakeJWT(#"{"email":"me@example.com"}"#)
        let json = #"{"access_token":"\#(access)","refresh_token":"r1","id_token":"\#(id)","expires_in":3600}"#
        let now = Date(timeIntervalSince1970: 100)
        let c = try CodexOAuth.parseTokenResponse(Data(json.utf8), now: now)
        #expect(c.accountId == "acc-9")
        #expect(c.email == "me@example.com")
        #expect(c.refreshToken == "r1")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 3700))
    }

    @Test func tokenWithoutAccountIsRejected() {
        let json = #"{"access_token":"\#(fakeJWT("{}"))","refresh_token":"r","expires_in":1}"#
        #expect(throws: LLMError.self) { try CodexOAuth.parseTokenResponse(Data(json.utf8)) }
    }

    @Test func refreshPostsFormEncodedGrant() async throws {
        StubURLProtocol.received = []
        let access = fakeJWT(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"a"}}"#)
        StubURLProtocol.handler = { _ in
            .init(status: 200, body: Data(#"{"access_token":"\#(access)","refresh_token":"r2","expires_in":60}"#.utf8))
        }
        let c = try await CodexOAuth.refresh("r/1+", session: StubURLProtocol.session())
        #expect(c.refreshToken == "r2")
        let body = String(decoding: try #require(StubURLProtocol.received.first?.httpBody), as: UTF8.self)
        #expect(body == "grant_type=refresh_token&refresh_token=r%2F1%2B&client_id=app_EMoamEEZ73f0CkXaXp7hrann")
    }

    @Test func invalidGrantMeansUnauthorized() async {
        StubURLProtocol.handler = { _ in .init(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)) }
        await #expect(throws: LLMError.unauthorized) {
            _ = try await CodexOAuth.refresh("r", session: StubURLProtocol.session())
        }
    }
}

}

@Suite struct AuthManagerTests {
    func creds(_ access: String, expires: TimeInterval) -> OAuthCredentials {
        OAuthCredentials(accessToken: access, refreshToken: "r-\(access)", expiresAt: Date(timeIntervalSince1970: expires), accountId: "a", email: "e")
    }

    @Test func freshTokenIsUsedWithoutRefresh() async throws {
        let store = InMemoryCredentialStore(creds("t1", expires: 10_000))
        let m = AuthManager(store: store, refresher: { _ in Issue.record("unexpected refresh"); throw LLMError.unauthorized },
                            now: { Date(timeIntervalSince1970: 0) })
        #expect(try await m.currentAuth().accessToken == "t1")
    }

    @Test func nearExpiryRefreshesOncePersistsAndKeepsEmail() async throws {
        let store = InMemoryCredentialStore(creds("t1", expires: 100))
        let counter = Counter()
        let m = AuthManager(store: store, refresher: { token in
            #expect(token == "r-t1")
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return OAuthCredentials(accessToken: "t2", refreshToken: "r-t2", expiresAt: Date(timeIntervalSince1970: 99_999), accountId: "a")
        }, now: { Date(timeIntervalSince1970: 0) })
        async let a = m.currentAuth()
        async let b = m.currentAuth()
        let (x, y) = try await (a, b)
        #expect(x.accessToken == "t2" && y.accessToken == "t2")
        #expect(await counter.value == 1)
        #expect(try store.load()?.refreshToken == "r-t2")
        #expect(try store.load()?.email == "e")
    }

    @Test func signedOutThrowsNotSignedIn() async {
        let m = AuthManager(store: InMemoryCredentialStore())
        await #expect(throws: LLMError.notSignedIn) { _ = try await m.currentAuth() }
    }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}

@Suite struct OAuthCallbackRoutingTests {
    let server = try! OAuthCallbackServer(state: "good", port: 0)

    @Test func acceptsCodeWithMatchingState() throws {
        let (status, _, result) = server.route("GET /auth/callback?code=xyz&state=good HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(status == "200 OK")
        #expect(try result?.get() == "xyz")
    }

    @Test func rejectsWrongStateAndUnknownPaths() {
        let (status, _, result) = server.route("GET /auth/callback?code=xyz&state=bad HTTP/1.1\r\n\r\n")
        #expect(status.hasPrefix("400"))
        #expect(throws: (any Error).self) { try result?.get() }
        #expect(server.route("GET /favicon.ico HTTP/1.1\r\n\r\n").2 == nil)
    }

    @Test func receivesCodeOverRealSocket() async throws {
        let state = "s-\(UUID().uuidString)"
        let port: UInt16 = 18_455
        let s = try OAuthCallbackServer(state: state, port: port)
        try await s.start()
        async let code = s.waitForCode()
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?code=abc&state=\(state)")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Signed in"))
        #expect(try await code == "abc")
    }

    /// Runs `op` detached and polls for its result, so a stranded continuation fails the test instead of hanging it.
    func outcome<T: Sendable>(within timeout: Duration = .seconds(2), _ op: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
        let box = ResultBox<T>()
        Task {
            let r: Result<T, Error>
            do { r = .success(try await op()) } catch { r = .failure(error) }
            box.lock.withLock { box.value = r }
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let v = box.lock.withLock({ box.value }) { return v }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test func stopReleasesAWaitingCaller() async throws {
        let s = try OAuthCallbackServer(state: "s", port: 18_456)
        try await s.start()
        let waiting = Task { await outcome { try await s.waitForCode() } }
        try? await Task.sleep(for: .milliseconds(50))
        s.stop()
        let result = await waiting.value
        #expect(result != nil, "waitForCode is still suspended after stop()")
        #expect(throws: OAuthCallbackServer.CallbackError.self) { try result?.get() }
    }

    @Test func stopBeforeReadyDoesNotStrandStart() async throws {
        let s = try OAuthCallbackServer(state: "s", port: 18_457)
        let starting = Task { await outcome { try await s.start() } }
        s.stop()
        #expect(await starting.value != nil, "start() is still suspended after stop()")
    }
}

final class ResultBox<T>: @unchecked Sendable {
    let lock = NSLock()
    var value: Result<T, Error>?
}
