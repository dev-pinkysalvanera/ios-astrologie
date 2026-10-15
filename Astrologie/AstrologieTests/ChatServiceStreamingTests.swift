//
//  ChatServiceStreamingTests.swift
//  AstrologieTests
//
//  Pins the streamed side of the client: chunks reach the caller as they arrive
//  rather than after the body is complete, frames survive being cut in half by a
//  packet boundary, and every failure still lands on a `ChatError` case — same
//  mapping as the buffered call. The transport is stubbed throughout, and the
//  stub's delivery schedule is driven by the test, so "as they arrive" is an
//  assertion and not a hope.
//

import Foundation
import Testing

@testable import Astrologie

// MARK: - Test doubles

/// Releases the transport's next chunk only when the test says so.
///
/// Chunk 0 starts open so a stream always gets going on its own; every chunk after
/// it waits, which is what lets a test prove a token was delivered *before* the
/// rest of the body existed.
private actor Gate {
    private var opened = 0
    private var waiters: [(index: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Suspends until chunk `index` has been released.
    func wait(for index: Int) async {
        guard index > opened else { return }
        await withCheckedContinuation { waiters.append((index, $0)) }
    }

    /// Releases every chunk up to and including `index`.
    func open(_ index: Int) {
        opened = max(opened, index)
        let released = waiters.filter { $0.index <= opened }
        waiters.removeAll { $0.index <= opened }
        for waiter in released { waiter.continuation.resume() }
    }
}

/// ``ChatTransport`` that replays canned chunks in order, one release at a time.
///
/// Stands in for a connection that dribbles frames out over several packets: each
/// chunk is handed over as bytes exactly as written, so a frame split across two
/// of them reaches the parser split.
private final class ReplayTransport: ChatTransport, @unchecked Sendable {
    private(set) var sentRequests: [URLRequest] = []

    private let status: Int
    private let chunks: [String]
    private let gate: Gate?
    /// Raised instead of a response, the way `URLSession` reports a connection
    /// that never got anywhere.
    private let connectFailure: (any Error)?
    /// Raised after the chunks run out, standing in for a connection dropped
    /// mid-reply.
    private let streamFailure: (any Error)?

    init(
        status: Int = 200,
        chunks: [String],
        gate: Gate? = nil,
        connectFailure: (any Error)? = nil,
        streamFailure: (any Error)? = nil
    ) {
        self.status = status
        self.chunks = chunks
        self.gate = gate
        self.connectFailure = connectFailure
        self.streamFailure = streamFailure
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await stream(request)
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return (data, response)
    }

    nonisolated func stream(_ request: URLRequest) async throws -> (ChatByteStream, URLResponse) {
        sentRequests.append(request)
        if let connectFailure { throw connectFailure }

        let response = HTTPURLResponse(
            url: .stubEndpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!

        let chunks = chunks
        let gate = gate
        let streamFailure = streamFailure

        let bytes = ChatByteStream { continuation in
            let delivery = Task {
                for (index, chunk) in chunks.enumerated() {
                    await gate?.wait(for: index)
                    for byte in Data(chunk.utf8) { continuation.yield(byte) }
                }
                continuation.finish(throwing: streamFailure)
            }
            continuation.onTermination = { _ in delivery.cancel() }
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
        accessToken: String = "test-access-token"
    ) -> ChatService {
        ChatService(
            endpoint: endpoint,
            apiKey: "sb_publishable_test-key",
            transport: transport,
            sessionID: { "session-under-test" },
            accessToken: { accessToken }
        )
    }
}

/// A token that only exists once the test hands it over.
///
/// Stands in for sign-in still in flight. Streaming is the path the app actually
/// takes, so this is the shape of a real cold-launch first send.
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

/// Reads a stream to completion, keeping whatever arrived before a failure.
///
/// Both halves matter: a stream that fails part-way through has still handed the
/// caller real tokens, and the tests below assert on them.
private func drain(
    _ stream: AsyncThrowingStream<String, any Error>
) async -> (tokens: [String], failure: (any Error)?) {
    var tokens: [String] = []
    do {
        for try await token in stream { tokens.append(token) }
        return (tokens, nil)
    } catch {
        return (tokens, error)
    }
}

// MARK: - Incremental delivery

struct ChatServiceStreamingTests {

    /// The gated chunks below are cut mid-frame on purpose: `" i"` + `"s"` splits a
    /// chunk's text and `"da"` + `"ta:"` splits the field name itself. A token only
    /// releases the next chunk, so reaching the end at all means each frame was
    /// parsed before the rest of the body existed.
    @Test(.timeLimit(.minutes(1)))
    func deliversEachChunkAsItArrivesAcrossPacketBoundaries() async throws {
        let gate = Gate()
        let service = ChatService.stubbed(
            transport: ReplayTransport(
                chunks: [
                    "data: Mercury\n\ndata:  i",
                    "s\n\ndata:  retrograde.\n\nda",
                    "ta: [DONE]\n\n"
                ],
                gate: gate
            )
        )

        var tokens: [String] = []
        for try await token in service.streamMessage("What's up with Mercury?") {
            tokens.append(token)
            await gate.open(tokens.count)
        }

        // One space after `data:` is SSE framing and gets stripped; a second one
        // belongs to the chunk.
        #expect(tokens == ["Mercury", " is", " retrograde."])
        #expect(tokens.joined() == "Mercury is retrograde.")
    }

    @Test func keepsLineBreaksInsideAChunk() async throws {
        // A chunk with a newline arrives as one `data:` line per line of text.
        let service = ChatService.stubbed(
            transport: ReplayTransport(chunks: ["data: Line one\ndata: Line two\n\ndata: [DONE]\n\n"])
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.tokens == ["Line one\nLine two"])
        #expect(result.failure == nil)
    }

    /// The production bug: a paragraph break inside a chunk. Every byte boundary
    /// is a read boundary here, so the multi-line event is split mid-field,
    /// mid-`data:` and between the lines of its own blank-line separator.
    @Test(.timeLimit(.minutes(1)))
    func keepsParagraphBreaksInAnEventSplitAcrossReads() async throws {
        let wire = "data: Saturn in the 7th.\ndata: \ndata: It slows partnerships.\n\n"
            + "data:  Patience\ndata: pays.\n\n"
            + "data: [DONE]\n\n"
        let service = ChatService.stubbed(
            transport: ReplayTransport(chunks: wire.map { String($0) })
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.failure == nil)
        #expect(result.tokens == ["Saturn in the 7th.\n\nIt slows partnerships.", " Patience\npays."])
    }

    @Test func treatsALoneCarriageReturnAsALineEnding() async throws {
        let service = ChatService.stubbed(
            transport: ReplayTransport(chunks: ["data: One\rdata: Two\r", "\rdata: [DONE]\r\r"])
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.tokens == ["One\nTwo"])
        #expect(result.failure == nil)
    }

    @Test func toleratesCRLFFramingSplitAcrossChunks() async throws {
        // The `\r` and its `\n` arrive in different packets, so the boundary can
        // only be recognized by remembering the pending carriage return.
        let service = ChatService.stubbed(
            transport: ReplayTransport(chunks: ["data: Reply\r", "\n\r\ndata: [DONE]\r\n\r\n"])
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.tokens == ["Reply"])
        #expect(result.failure == nil)
    }

    @Test func stopsAtTheDoneSentinel() async throws {
        let service = ChatService.stubbed(
            transport: ReplayTransport(
                chunks: ["data: Kept\n\ndata: [DONE]\n\ndata: Ignored\n\n"]
            )
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.tokens == ["Kept"])
    }

    @Test func sendsTheSamePOSTAsTheBufferedCall() async throws {
        let transport = ReplayTransport(chunks: ["data: Reply\n\ndata: [DONE]\n\n"])
        let service = ChatService.stubbed(transport: transport)

        _ = await drain(service.streamMessage("What's up with Mercury?"))

        let request = try #require(transport.sentRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        let decoded = try JSONDecoder()
            .decode(ChatRequestDTO.self, from: #require(request.httpBody))
        #expect(
            decoded == ChatRequestDTO(
                sessionId: "session-under-test",
                message: "What's up with Mercury?"
            )
        )
    }

    @Test func carriesTheBearerTokenOnTheStreamedRequest() async throws {
        let transport = ReplayTransport(chunks: ["data: Reply\n\ndata: [DONE]\n\n"])
        let service = ChatService.stubbed(transport: transport, accessToken: "jwt-under-test")

        _ = await drain(service.streamMessage("Hi"))

        let request = try #require(transport.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer jwt-under-test")
        // The publishable key stays where it belongs; it is not a JWT.
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_test-key")
    }

    @Test(.timeLimit(.minutes(1)))
    func waitsForATokenThatResolvesAfterTheStreamStarted() async throws {
        let transport = ReplayTransport(chunks: ["data: Reply\n\ndata: [DONE]\n\n"])
        let token = DeferredToken()
        let service = ChatService(
            endpoint: .stubEndpoint,
            apiKey: "sb_publishable_test-key",
            transport: transport,
            sessionID: { "session-under-test" },
            accessToken: { await token.token() }
        )

        let reading = Task { await drain(service.streamMessage("Hi")) }
        try await Task.sleep(for: .milliseconds(20))
        // The stream is being read, but nothing can go out yet.
        #expect(transport.sentRequests.isEmpty)

        // Sign-in lands only after the send is already under way.
        await token.resolve("late-arriving-token")
        let result = await reading.value

        #expect(result.tokens == ["Reply"])
        #expect(result.failure == nil)
        let request = try #require(transport.sentRequests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer late-arriving-token")
    }

    @Test func doesNotSendUntilTheStreamIsIterated() async throws {
        let transport = ReplayTransport(chunks: ["data: Reply\n\ndata: [DONE]\n\n"])
        let stream = ChatService.stubbed(transport: transport).streamMessage("Hi")

        #expect(transport.sentRequests.isEmpty)

        _ = await drain(stream)

        #expect(transport.sentRequests.count == 1)
    }
}

// MARK: - Failure mapping

struct ChatServiceStreamingErrorTests {

    @Test func mapsATruncatedStreamToDecodingFailedAfterDeliveringWhatArrived() async {
        // Chunks arrived but `[DONE]` never did: a fragment is not an answer, even
        // though the caller has already seen part of it.
        let service = ChatService.stubbed(
            transport: ReplayTransport(chunks: ["data: Half an ans"])
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.tokens == ["Half an ans"])
        guard case .decodingFailed? = result.failure as? ChatError else {
            Issue.record("Expected a decoding failure, got \(String(describing: result.failure)).")
            return
        }
    }

    @Test func mapsAStreamThatCarriesNoChunkToDecodingFailed() async {
        let service = ChatService.stubbed(transport: ReplayTransport(chunks: ["data: [DONE]\n\n"]))

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.tokens.isEmpty)
        guard case .decodingFailed? = result.failure as? ChatError else {
            Issue.record("Expected a decoding failure, got \(String(describing: result.failure)).")
            return
        }
    }

    @Test func mapsNon2xxToHTTPStatusWithTheBackendMessageAndNoTokens() async {
        let service = ChatService.stubbed(
            transport: ReplayTransport(
                status: 429,
                // Split mid-JSON: the failure body is read whole before it's decoded.
                chunks: [
                    #"{"error":"Rate limit exceeded. Try again later.""#,
                    #","debug":{"retryAfterMs":1500}}"#
                ]
            )
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.tokens.isEmpty)
        #expect(
            result.failure as? ChatError
                == .httpStatus(code: 429, message: "Rate limit exceeded. Try again later.")
        )
    }

    @Test func mapsAnUnreadableErrorBodyToANilMessage() async {
        let service = ChatService.stubbed(
            transport: ReplayTransport(status: 502, chunks: ["<html>Bad gateway</html>"])
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.failure as? ChatError == .httpStatus(code: 502, message: nil))
    }

    @Test func mapsAConnectionFailureToNetworkWithItsCode() async {
        let service = ChatService.stubbed(
            transport: ReplayTransport(
                chunks: [],
                connectFailure: URLError(.notConnectedToInternet)
            )
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.tokens.isEmpty)
        #expect(result.failure as? ChatError == .network(.notConnectedToInternet))
    }

    @Test func mapsAFailurePartWayThroughTheBodyToNetwork() async {
        let service = ChatService.stubbed(
            transport: ReplayTransport(
                chunks: ["data: Partial\n\n"],
                streamFailure: URLError(.networkConnectionLost)
            )
        )

        let result = await drain(service.streamMessage("Hi"))

        // The caller keeps what it was given, then hears why the rest isn't coming.
        #expect(result.tokens == ["Partial"])
        #expect(result.failure as? ChatError == .network(.networkConnectionLost))
    }

    @Test func mapsANonURLErrorFailureToAnUnlabeledNetworkFailure() async {
        struct OddFailure: Error {}
        let service = ChatService.stubbed(
            transport: ReplayTransport(chunks: [], streamFailure: OddFailure())
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.failure as? ChatError == .network(.unknown))
    }

    @Test func mapsAMissingEndpointToInvalidURLWithoutSending() async {
        let transport = ReplayTransport(chunks: ["data: Reply\n\ndata: [DONE]\n\n"])
        let service = ChatService.stubbed(transport: transport, endpoint: nil)

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.failure as? ChatError == .invalidURL)
        #expect(transport.sentRequests.isEmpty)
    }
}

// MARK: - Protocol fallback

/// A conformer with nothing but a buffered reply to offer, like the stubs driving
/// the ViewModel tests.
private struct BufferedOnlyService: ChatServiceProtocol {
    let outcome: Result<String, ChatError>

    func sendMessage(_ message: String) async throws -> String {
        try outcome.get()
    }
}

struct ChatServiceProtocolStreamingTests {

    @Test func streamsABufferedReplyAsASingleToken() async {
        let service: any ChatServiceProtocol = BufferedOnlyService(
            outcome: .success("Mercury is retrograde.")
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.tokens == ["Mercury is retrograde."])
        #expect(result.failure == nil)
    }

    @Test func propagatesABufferedFailureThroughTheStream() async {
        let service: any ChatServiceProtocol = BufferedOnlyService(
            outcome: .failure(.httpStatus(code: 429, message: "Rate limit exceeded."))
        )

        let result = await drain(service.streamMessage("Hi"))

        #expect(result.tokens.isEmpty)
        #expect(result.failure as? ChatError == .httpStatus(code: 429, message: "Rate limit exceeded."))
    }
}

// MARK: - Rate limit, end to end

/// A real 429 body through the real ``ChatService`` into the ViewModel and the
/// banner (Week 10 Task 2). The parts are tested on their own elsewhere; this
/// pins that they fit together.
@MainActor
struct ChatRateLimitEndToEndTests {

    @Test func aBackend429ReachesTheBannerWithItsWording() async {
        let service = ChatService.stubbed(
            transport: ReplayTransport(
                status: 429,
                chunks: [#"{"error":"Rate limit exceeded. Try again later.","debug":{"retryAfterMs":1500}}"#]
            )
        )
        let viewModel = ChatViewModel(service: service)
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        #expect(view.errorMessage == "Rate limit exceeded. Try again later.")
        #expect(viewModel.inputText == "What's up with Mercury?")
        #expect(viewModel.messages.map(\.role) == [.user])
    }
}
