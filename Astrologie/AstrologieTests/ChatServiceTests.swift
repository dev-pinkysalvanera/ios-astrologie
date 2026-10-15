//
//  ChatServiceTests.swift
//  AstrologieTests
//
//  Pins the real client against the contract in
//  `supabase/functions/chat/handler.ts`: what goes out on the wire (session id,
//  `apikey` header, bearer token, JSON body), how an SSE reply is reassembled, and
//  how each failure lands on a `ChatError` case. The transport is stubbed
//  throughout — nothing here touches the network.
//

import Foundation
import Testing

@testable import Astrologie

// MARK: - Test doubles

/// ``ChatTransport`` that records what it was handed and replays a canned result.
private final class StubTransport: ChatTransport, @unchecked Sendable {
    private(set) var sentRequests: [URLRequest] = []
    private let outcome: Result<(Data, URLResponse), any Error>

    /// Replays an HTTP response with `status` and `body`.
    init(status: Int = 200, body: String) {
        let response = HTTPURLResponse(
            url: .stubEndpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        outcome = .success((Data(body.utf8), response))
    }

    /// Fails the send, the way `URLSession` reports a transport fault.
    init(failure: any Error) {
        outcome = .failure(failure)
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        sentRequests.append(request)
        return try outcome.get()
    }

    /// Hands the canned body over in one go.
    ///
    /// Deliberately not incremental: this stub exists for the buffered path, and
    /// the streaming tests use one that replays chunks on a schedule.
    nonisolated func stream(_ request: URLRequest) async throws -> (ChatByteStream, URLResponse) {
        let (data, response) = try await send(request)
        let bytes = ChatByteStream { continuation in
            for byte in data { continuation.yield(byte) }
            continuation.finish()
        }
        return (bytes, response)
    }
}

private extension URL {
    /// Stand-in endpoint. Deliberately not the real project URL.
    static let stubEndpoint = URL(string: "https://example.test/functions/v1/chat")!
}

private extension ChatService {
    /// A service wired to `transport`, with a fixed session id, api key and token.
    static func stubbed(
        transport: any ChatTransport,
        endpoint: URL? = .stubEndpoint,
        sessionID: String = "session-under-test",
        accessToken: String = "test-access-token"
    ) -> ChatService {
        stubbed(
            transport: transport,
            endpoint: endpoint,
            sessionID: sessionID,
            accessToken: { accessToken }
        )
    }

    /// The same, with sign-in left to the test — so a token closure that throws is
    /// as easy to arrange as one that answers.
    static func stubbed(
        transport: any ChatTransport,
        endpoint: URL? = .stubEndpoint,
        sessionID: String = "session-under-test",
        accessToken: @escaping @Sendable () async throws -> String
    ) -> ChatService {
        ChatService(
            endpoint: endpoint,
            apiKey: "sb_publishable_test-key",
            transport: transport,
            sessionID: { sessionID },
            accessToken: accessToken
        )
    }
}

/// Stands in for whatever Supabase Auth throws: this layer only knows it isn't a
/// `URLError`, which is exactly the case that used to read as "No connection."
private struct AuthFailure: Error {}

/// A token that only exists once the test hands it over.
///
/// Stands in for sign-in still in flight: a send that starts before it resolves has
/// to wait for it, which is the whole reason the service takes an async closure
/// instead of a captured `String`.
private actor DeferredToken {
    private var value: String?
    private var waiters: [CheckedContinuation<String, Never>] = []

    /// Suspends until ``resolve(_:)`` is called, then answers that token.
    func token() async -> String {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Releases everyone waiting on the token.
    func resolve(_ token: String) {
        value = token
        for waiter in waiters { waiter.resume(returning: token) }
        waiters.removeAll()
    }
}

/// Hands out a fixed list of ids in order, repeating the last one.
private final class IDSequence: @unchecked Sendable {
    private let values: [String]
    private var index = 0

    init(values: [String]) {
        self.values = values
    }

    func next() -> String {
        defer { index = min(index + 1, values.count - 1) }
        return values[index]
    }
}

/// A minimal well-formed success body: one chunk, then the sentinel.
private let singleChunkStream = "data: Mercury is retrograde.\n\ndata: [DONE]\n\n"

// MARK: - Request

struct ChatServiceRequestTests {

    @Test func postsJSONWithTheSessionIDAndTheMessage() async throws {
        let transport = StubTransport(body: singleChunkStream)
        let service = ChatService.stubbed(transport: transport)

        _ = try await service.sendMessage("What's up with Mercury?")

        let request = try #require(transport.sentRequests.first)
        #expect(transport.sentRequests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url == .stubEndpoint)

        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode(ChatRequestDTO.self, from: body)
        #expect(
            decoded == ChatRequestDTO(
                sessionId: "session-under-test",
                message: "What's up with Mercury?"
            )
        )
    }

    @Test func sendsThePublishableKeyAsTheAPIKeyHeaderAndNotAsABearerToken() async throws {
        let transport = StubTransport(body: singleChunkStream)
        let service = ChatService.stubbed(transport: transport)

        _ = try await service.sendMessage("Hello")

        let request = try #require(transport.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        // The publishable key is not a JWT: it identifies the project and must
        // never stand in for the user's token.
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(!authorization.contains("sb_publishable_test-key"))
    }

    @Test func sendsTheAccessTokenAsABearerToken() async throws {
        let transport = StubTransport(body: singleChunkStream)
        let service = ChatService.stubbed(transport: transport, accessToken: "jwt-under-test")

        _ = try await service.sendMessage("Hello")

        let request = try #require(transport.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-under-test")
    }

    @Test(.timeLimit(.minutes(1)))
    func waitsForATokenThatResolvesAfterTheSendStarted() async throws {
        // The cold-launch case: `ContentView` builds the service before sign-in has
        // finished, so the first send has to wait for the token rather than go out
        // without one and come back 401.
        let transport = StubTransport(body: singleChunkStream)
        let token = DeferredToken()
        let service = ChatService(
            endpoint: .stubEndpoint,
            apiKey: "sb_publishable_test-key",
            transport: transport,
            sessionID: { "session-under-test" },
            accessToken: { await token.token() }
        )

        let send = Task { try await service.sendMessage("Hello") }
        try await Task.sleep(for: .milliseconds(20))
        // Nothing may go out while the token is still missing.
        #expect(transport.sentRequests.isEmpty)

        await token.resolve("late-arriving-token")
        _ = try await send.value

        let request = try #require(transport.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer late-arriving-token")
    }

    @Test func mapsAFailedSignInToSignInFailedWithoutSending() async {
        // Auth failures arrive as the SDK's own error types, so the catch-all is
        // the case that matters: folding them into `.network(.unknown)` is what
        // made a rejected sign-in read as an offline device.
        let transport = StubTransport(body: singleChunkStream)
        let service = ChatService.stubbed(transport: transport, accessToken: { throw AuthFailure() })

        let thrown = await #expect(throws: ChatError.self) {
            try await service.sendMessage("Hello")
        }

        guard case .signInFailed? = thrown else {
            Issue.record("Expected a sign-in failure, got \(String(describing: thrown)).")
            return
        }
        #expect(transport.sentRequests.isEmpty)
    }

    @Test func keepsAnOfflineSignInOnTheNetworkCase() async {
        // A sign-in that couldn't reach Supabase *is* a connectivity problem, so
        // this one keeps the connectivity copy rather than blaming auth.
        let service = ChatService.stubbed(
            transport: StubTransport(body: singleChunkStream),
            accessToken: { throw URLError(.notConnectedToInternet) }
        )

        await #expect(throws: ChatError.network(.notConnectedToInternet)) {
            try await service.sendMessage("Hello")
        }
    }

    @Test func keepsASendCancelledWhileWaitingForATokenOnTheNetworkCase() async {
        // Dropping the send while it waited on sign-in isn't a failed sign-in.
        let service = ChatService.stubbed(
            transport: StubTransport(body: singleChunkStream),
            accessToken: { throw CancellationError() }
        )

        await #expect(throws: ChatError.network(.cancelled)) {
            try await service.sendMessage("Hello")
        }
    }

    @Test func readsTheSessionIDOnEverySend() async throws {
        let transport = StubTransport(body: singleChunkStream)
        // Stands in for an id that changed between sends: each request has to
        // carry the value current at send time, not one captured at init.
        let ids = IDSequence(values: ["first-id", "second-id"])
        let service = ChatService(
            endpoint: .stubEndpoint,
            apiKey: "sb_publishable_test-key",
            transport: transport,
            sessionID: { ids.next() }
        )

        _ = try await service.sendMessage("One")
        _ = try await service.sendMessage("Two")

        let sessionIDs = try transport.sentRequests.map { request in
            try JSONDecoder()
                .decode(ChatRequestDTO.self, from: #require(request.httpBody))
                .sessionId
        }
        #expect(sessionIDs == ["first-id", "second-id"])
    }
}

// MARK: - Token refresh

/// In-memory ``AuthSessionProvider`` used to simulate the SDK refreshing an
/// access token underneath a live session, without a network or a Keychain.
///
/// Same double ``AuthServiceTests`` uses to prove ``AuthService`` reads the
/// provider fresh each time; here it feeds a real ``AuthService`` into a real
/// ``ChatService`` to prove the same thing end to end.
private final class RefreshableAuthSessionProvider: AuthSessionProvider, @unchecked Sendable {
    var stored: AuthSession?

    init(stored: AuthSession) {
        self.stored = stored
    }

    func storedSession() async throws -> AuthSession? { stored }

    func signInAnonymously() async throws -> AuthSession {
        // Not exercised here: a session is already stored, so `AuthService`
        // never needs to mint one.
        fatalError("Unexpected sign-in in a refresh test.")
    }
}

struct ChatServiceTokenRefreshTests {

    /// Task 9's contract: nothing between the SDK and the wire caches a token, so
    /// a refresh that happens between two sends — the SDK's job, not this app's —
    /// reaches the second request with no retry path needed for it to do so.
    ///
    /// `AuthService.accessToken()` re-reads its provider on every call (pinned in
    /// `AuthServiceTests.theTokenIsReadFreshSoARefreshIsVisible`), and
    /// `ChatService` awaits that same closure fresh per send (pinned in
    /// `waitsForATokenThatResolvesAfterTheSendStarted`). This test chains the two
    /// real types together, standing in only for the SDK boundary, to prove the
    /// chain as a whole rather than each half in isolation.
    ///
    /// **Validates: Task 9 — a send after token expiry still gets a reply.**
    @Test func aSendAfterTheUnderlyingTokenIsRefreshedCarriesTheNewToken() async throws {
        let provider = RefreshableAuthSessionProvider(
            stored: AuthSession(userID: "user", accessToken: "about-to-expire-token")
        )
        let auth = AuthService(provider: provider)
        let transport = StubTransport(body: singleChunkStream)
        let service = ChatService(
            endpoint: .stubEndpoint,
            apiKey: "sb_publishable_test-key",
            transport: transport,
            sessionID: { "session-under-test" },
            accessToken: { try await auth.accessToken() }
        )

        _ = try await service.sendMessage("First, before expiry")

        // Stands in for the SDK's background refresh landing between two sends —
        // the part this app doesn't control and doesn't need to: the token
        // closure re-invokes `accessToken()`, which re-reads the provider.
        provider.stored = AuthSession(userID: "user", accessToken: "refreshed-token")

        let reply = try await service.sendMessage("Second, after expiry")

        #expect(reply == "Mercury is retrograde.")
        #expect(transport.sentRequests.count == 2)
        #expect(
            transport.sentRequests[0].value(forHTTPHeaderField: "Authorization")
                == "Bearer about-to-expire-token"
        )
        #expect(
            transport.sentRequests[1].value(forHTTPHeaderField: "Authorization")
                == "Bearer refreshed-token"
        )
    }
}

// MARK: - Success path

struct ChatServiceStreamTests {

    @Test func concatenatesChunksIntoOneReply() async throws {
        let transport = StubTransport(
            body: "data: Mercury\n\ndata:  is\n\ndata:  retrograde.\n\ndata: [DONE]\n\n"
        )

        let reply = try await ChatService.stubbed(transport: transport).sendMessage("Hi")

        // One space after `data:` is SSE framing and gets stripped; a second one
        // belongs to the chunk.
        #expect(reply == "Mercury is retrograde.")
    }

    @Test func keepsTheFilteredPlaceholderInPlace() async throws {
        let transport = StubTransport(
            body: "data: Before\n\ndata: [Content filtered]\n\ndata: [DONE]\n\n"
        )

        let reply = try await ChatService.stubbed(transport: transport).sendMessage("Hi")

        #expect(reply == "Before[Content filtered]")
    }

    @Test func keepsLineBreaksInsideAChunk() async throws {
        // A chunk with a newline arrives as one `data:` line per line of text.
        let transport = StubTransport(body: "data: Line one\ndata: Line two\n\ndata: [DONE]\n\n")

        let reply = try await ChatService.stubbed(transport: transport).sendMessage("Hi")

        #expect(reply == "Line one\nLine two")
    }

    @Test func keepsParagraphBreaksInsideAChunk() async throws {
        // The production bug: text after a `\n\n` in the model's reply was lost.
        let transport = StubTransport(
            body: "data: Para one.\ndata: \ndata: Para two.\n\ndata: [DONE]\n\n"
        )

        let reply = try await ChatService.stubbed(transport: transport).sendMessage("Hi")

        #expect(reply == "Para one.\n\nPara two.")
    }

    @Test func readsALiteralDoneChunkSplitByTheBackendAsText() async throws {
        // The backend sends a chunk that is literally `[DONE]` as `[` + `DONE]`
        // so it can't be mistaken for the terminator.
        let transport = StubTransport(
            body: "data: Say \n\ndata: [\n\ndata: DONE]\n\ndata: [DONE]\n\n"
        )

        let reply = try await ChatService.stubbed(transport: transport).sendMessage("Hi")

        #expect(reply == "Say [DONE]")
    }

    @Test func toleratesCRLFFraming() async throws {
        let transport = StubTransport(body: "data: Reply\r\n\r\ndata: [DONE]\r\n\r\n")

        let reply = try await ChatService.stubbed(transport: transport).sendMessage("Hi")

        #expect(reply == "Reply")
    }

    @Test func stopsAtTheDoneSentinel() async throws {
        let transport = StubTransport(body: "data: Kept\n\ndata: [DONE]\n\ndata: Ignored\n\n")

        let reply = try await ChatService.stubbed(transport: transport).sendMessage("Hi")

        #expect(reply == "Kept")
    }
}

// MARK: - Failure mapping

struct ChatServiceErrorMappingTests {

    @Test func mapsAMissingEndpointToInvalidURLWithoutSending() async {
        let transport = StubTransport(body: singleChunkStream)
        let service = ChatService.stubbed(transport: transport, endpoint: nil)

        await #expect(throws: ChatError.invalidURL) {
            try await service.sendMessage("Hi")
        }
        #expect(transport.sentRequests.isEmpty)
    }

    @Test func mapsATransportFailureToNetworkWithItsCode() async {
        let service = ChatService.stubbed(
            transport: StubTransport(failure: URLError(.notConnectedToInternet))
        )

        await #expect(throws: ChatError.network(.notConnectedToInternet)) {
            try await service.sendMessage("Hi")
        }
    }

    @Test func mapsANonURLErrorFailureToAnUnlabeledNetworkFailure() async {
        struct OddFailure: Error {}
        let service = ChatService.stubbed(transport: StubTransport(failure: OddFailure()))

        await #expect(throws: ChatError.network(.unknown)) {
            try await service.sendMessage("Hi")
        }
    }

    @Test func mapsNon2xxToHTTPStatusWithTheBackendMessage() async {
        let service = ChatService.stubbed(
            transport: StubTransport(
                status: 429,
                body: #"{"error":"Rate limit exceeded. Try again later.","debug":{"retryAfterMs":1500}}"#
            )
        )

        await #expect(
            throws: ChatError.httpStatus(
                code: 429,
                message: "Rate limit exceeded. Try again later."
            )
        ) {
            try await service.sendMessage("Hi")
        }
    }

    @Test func mapsAnUnreadableErrorBodyToANilMessage() async {
        let service = ChatService.stubbed(
            transport: StubTransport(status: 502, body: "<html>Bad gateway</html>")
        )

        await #expect(throws: ChatError.httpStatus(code: 502, message: nil)) {
            try await service.sendMessage("Hi")
        }
    }

    @Test func mapsAnEmptyErrorBodyToANilMessage() async {
        let service = ChatService.stubbed(transport: StubTransport(status: 500, body: ""))

        await #expect(throws: ChatError.httpStatus(code: 500, message: nil)) {
            try await service.sendMessage("Hi")
        }
    }

    @Test func mapsATruncatedStreamToDecodingFailed() async {
        // Chunks arrived but `[DONE]` never did: a fragment is not an answer.
        let service = ChatService.stubbed(transport: StubTransport(body: "data: Half an ans"))

        let thrown = await #expect(throws: ChatError.self) {
            try await service.sendMessage("Hi")
        }

        guard case .decodingFailed? = thrown else {
            Issue.record("Expected a decoding failure, got \(String(describing: thrown)).")
            return
        }
    }

    @Test func mapsASuccessBodyWithoutEventFramesToDecodingFailed() async {
        let service = ChatService.stubbed(
            transport: StubTransport(body: #"{"reply":"Not the documented shape."}"#)
        )

        let thrown = await #expect(throws: ChatError.self) {
            try await service.sendMessage("Hi")
        }

        guard case .decodingFailed? = thrown else {
            Issue.record("Expected a decoding failure, got \(String(describing: thrown)).")
            return
        }
    }

    @Test func mapsAStreamThatCarriesNoChunkToDecodingFailed() async {
        let service = ChatService.stubbed(transport: StubTransport(body: "data: [DONE]\n\n"))

        let thrown = await #expect(throws: ChatError.self) {
            try await service.sendMessage("Hi")
        }

        guard case .decodingFailed? = thrown else {
            Issue.record("Expected a decoding failure, got \(String(describing: thrown)).")
            return
        }
    }

    /// The three failures that used to be indistinguishable on screen, each one
    /// produced by the real mapping rather than constructed by hand: sign-in threw,
    /// the send never got out, the token wasn't accepted. If any two ever collapse
    /// to the same wording this fails, which is the whole point of the test.
    @Test func tellsAFailedSignInAnOfflineSendAndARejectedTokenApart() async throws {
        let signIn = ChatService.stubbed(
            transport: StubTransport(body: singleChunkStream),
            accessToken: { throw AuthFailure() }
        )
        let offline = ChatService.stubbed(
            transport: StubTransport(failure: URLError(.notConnectedToInternet))
        )
        let rejectedToken = ChatService.stubbed(
            transport: StubTransport(
                status: ChatError.unauthorizedStatusCode,
                body: #"{"error":"Missing authorization header"}"#
            )
        )

        var copy: [String] = []
        for service in [signIn, offline, rejectedToken] {
            let thrown = await #expect(throws: ChatError.self) {
                try await service.sendMessage("Hi")
            }
            copy.append(try #require(thrown?.errorDescription))
        }

        #expect(Set(copy).count == 3, "these three read alike: \(copy)")
        // And each points at its own layer, not at one of the other two.
        #expect(copy[0].localizedCaseInsensitiveContains("sign"))
        #expect(copy[1] == "No connection. Check your network and try again.")
        #expect(copy[2].localizedCaseInsensitiveContains("session"))
        #expect(!copy[2].contains("Missing authorization header"))
    }
}

// MARK: - Reporting

/// The report action (Week 9 Task 4): same endpoint, key, token and session as a
/// chat turn, the raw reply text in the body, and every failure a ``ChatError``.
struct ChatServiceReportTests {

    private let messageID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!

    @Test func postsTheReportActionWithTheSessionIDMessageIDAndRawText() async throws {
        let transport = StubTransport(status: 201, body: #"{"success":true}"#)
        let service = ChatService.stubbed(transport: transport, sessionID: "session-42")

        try await service.reportMessage(id: messageID, text: "## Saturn\n**Big** year.")

        let request = try #require(transport.sentRequests.first)
        #expect(transport.sentRequests.count == 1)
        #expect(request.httpMethod == "POST")
        #expect(request.url == .stubEndpoint)

        let body = try JSONDecoder().decode(
            ReportRequestDTO.self, from: try #require(request.httpBody)
        )
        #expect(body.action == "report")
        #expect(body.sessionId == "session-42")
        #expect(body.messageId == messageID.uuidString)
        // Raw, markdown included: the report is what the model produced.
        #expect(body.messageText == "## Saturn\n**Big** year.")
    }

    @Test func sendsTheAccessTokenAndAPIKey() async throws {
        let transport = StubTransport(status: 201, body: "")
        let service = ChatService.stubbed(transport: transport, accessToken: "jwt-for-report")

        try await service.reportMessage(id: messageID, text: "Reply")

        let request = try #require(transport.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-for-report")
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test-key")
    }

    @Test func aNon2xxThrowsWithTheBackendMessage() async {
        let transport = StubTransport(status: 502, body: #"{"error":"Failed to store report."}"#)
        let service = ChatService.stubbed(transport: transport)

        await #expect(throws: ChatError.httpStatus(code: 502, message: "Failed to store report.")) {
            try await service.reportMessage(id: messageID, text: "Reply")
        }
    }

    @Test func aTransportFailureThrowsANetworkError() async {
        let service = ChatService.stubbed(
            transport: StubTransport(failure: URLError(.notConnectedToInternet))
        )

        await #expect(throws: ChatError.network(.notConnectedToInternet)) {
            try await service.reportMessage(id: messageID, text: "Reply")
        }
    }

    @Test func aFailedSignInThrowsWithoutSending() async {
        let transport = StubTransport(status: 201, body: "")
        let service = ChatService.stubbed(
            transport: transport,
            accessToken: { throw AuthFailure() }
        )

        await #expect(throws: ChatError.self) {
            try await service.reportMessage(id: messageID, text: "Reply")
        }
        #expect(transport.sentRequests.isEmpty)
    }
}
