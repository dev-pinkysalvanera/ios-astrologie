//
//  ChatService.swift
//  Astrologie
//
//  The real ``ChatServiceProtocol``: one round trip to the `chat` edge function
//  per message, the Keychain session id in the body and the Supabase access token
//  in the `Authorization` header of every request, and every failure folded into
//  ``ChatError`` so the ViewModel never sees `URLError`, `DecodingError` or a raw
//  status code.
//
//  A 200 from that function is `text/event-stream`, not JSON: the backend emits
//  one SSE event per piece of the reply — one `data: <line>` per line of text,
//  then a blank line — and closes with `data: [DONE]\n\n` (see
//  `supabase/functions/chat/handler.ts`). Both shapes of
//  the call read that same format: ``sendMessage(_:)`` collects the body and joins
//  the chunks, ``streamMessage(_:)`` parses frames as the bytes land and forwards
//  each chunk on arrival. The frame rules and the ``ChatError`` mapping are shared
//  between them, so the two can't drift.
//

import Foundation

// MARK: - Transport seam

/// A response body arriving one byte at a time.
///
/// `UInt8` rather than `String` because a frame boundary is a byte pattern and a
/// chunk's text may be multi-byte: decoding is the parser's job, once it holds a
/// whole frame. A failure part-way through a body terminates the stream.
typealias ChatByteStream = AsyncThrowingStream<UInt8, any Error>

/// The two things this service needs from `URLSession`.
///
/// Narrow on purpose: a test hands over a stub that replays canned bytes, so the
/// request building, status mapping and event-stream parsing below can all be
/// exercised without a network or a `URLProtocol` subclass. ``stream(_:)`` is the
/// same idea with the delivery schedule left to the stub, which is what makes
/// "arrives in pieces" testable at all.
nonisolated protocol ChatTransport: Sendable {

    /// Sends `request` and returns the complete response.
    ///
    /// - Throws: `URLError` for transport failures, matching `URLSession`.
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)

    /// Sends `request` and returns the response head plus its body as a stream.
    ///
    /// Returns as soon as the status and headers are known, before the body is
    /// complete — that is the whole point, and it is what lets a non-2xx be
    /// recognized without reading a reply that isn't coming.
    ///
    /// - Throws: `URLError` if the request never got as far as a response.
    ///   Failures after that terminate the returned stream instead.
    func stream(_ request: URLRequest) async throws -> (ChatByteStream, URLResponse)
}

extension URLSession: ChatTransport {

    /// Bridges ``ChatTransport`` onto `data(for:)`.
    ///
    /// That call buffers the whole body before it resolves, which for an SSE
    /// response means "after `[DONE]` closed the stream" — exactly what a
    /// non-streaming caller wants.
    nonisolated func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }

    /// Bridges ``ChatTransport`` onto `bytes(for:)`.
    ///
    /// The pump task exists only to retype `URLSession.AsyncBytes` into the
    /// concrete ``ChatByteStream`` the seam is written against; cancelling the
    /// stream cancels it, which cancels the underlying task.
    nonisolated func stream(_ request: URLRequest) async throws -> (ChatByteStream, URLResponse) {
        let (bytes, response) = try await self.bytes(for: request)

        let body = ChatByteStream { continuation in
            let pump = Task {
                do {
                    for try await byte in bytes { continuation.yield(byte) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }

        return (body, response)
    }
}

// MARK: - Service

/// Talks to the `chat` edge function over HTTP.
///
/// A value type holding only `Sendable` state, and `nonisolated` as a whole, so a
/// `@MainActor` ViewModel can hold one instance while the request, the wait and
/// the parse stay off the main actor.
///
/// Everything it needs from the outside world — where to send, which key to send,
/// which session id to claim, which token to authorize with, and what to send it
/// on — arrives through ``init(endpoint:apiKey:transport:sessionID:accessToken:)``
/// with production defaults.
///
/// - Note: The endpoint wants a Supabase user access token alongside the `apikey`
///   header (see `supabase/PRODUCTION_ENDPOINT.md`); the handler answers 401
///   without one. The token comes from ``AuthServiceProtocol`` through
///   ``accessToken``, and the publishable key is not a JWT so it stays in `apikey`
///   and never goes out as a bearer token.
nonisolated struct ChatService: ChatServiceProtocol {

    /// Where to send. Optional so a configuration that can't produce a URL fails
    /// as ``ChatError/invalidURL`` on send instead of trapping at launch — and so
    /// that path stays reachable from a test.
    private let endpoint: URL?

    /// Project publishable key, sent in the `apikey` header.
    private let apiKey: String

    /// How the request is actually sent.
    private let transport: any ChatTransport

    /// Supplies the session id for the request body, read fresh on every send.
    ///
    /// A closure rather than a stored id because ``SessionManager`` owns it:
    /// asking each time keeps this type out of the caching business and leaves
    /// room for a later "start a new thread" reset. `@MainActor` because that is
    /// where the session manager's state lives — hence the `await` in
    /// ``makeRequest(for:)``, which is one actor hop per send, not per byte.
    private let sessionID: @MainActor @Sendable () -> String

    /// Supplies the bearer token for the `Authorization` header, asked for fresh
    /// on every send.
    ///
    /// **Async, and that is the whole point.** A captured `String` would be read
    /// when the service is built — `ContentView` does that synchronously in a
    /// `@State` initializer, before sign-in has resolved — so the first send of a
    /// cold launch would go out unauthorized and come back 401, while every stub
    /// test stayed green because a stub's token is always ready. Awaiting instead
    /// means a send that starts early waits for sign-in rather than racing it, and
    /// a token refreshed in the meantime is the one that goes out.
    ///
    /// Not to be confused with ``sessionID``: that is a client-generated grouping
    /// key for the request *body*, this is the server-issued JWT that authorizes
    /// the request. See ``AuthSession``.
    private let accessToken: @Sendable () async throws -> String

    /// - Parameters:
    ///   - endpoint: The `chat` function URL. Defaults to
    ///     ``SupabaseConfig/chatFunctionURL``; `nil` makes every send fail as
    ///     ``ChatError/invalidURL``.
    ///   - apiKey: Value for the `apikey` header. Defaults to
    ///     ``SupabaseConfig/publishableKey``.
    ///   - transport: Transport for the request. Defaults to the shared session.
    ///   - sessionID: Source of the session identifier. Defaults to
    ///     ``SessionManager/shared``, which mints one per launch.
    ///   - accessToken: Source of the bearer token, awaited per send. Defaults to
    ///     ``AuthService/shared``, which signs in anonymously if nobody has yet.
    init(
        endpoint: URL? = SupabaseConfig.chatFunctionURL,
        apiKey: String = SupabaseConfig.publishableKey,
        transport: any ChatTransport = URLSession.shared,
        sessionID: @escaping @MainActor @Sendable () -> String = {
            SessionManager.shared.sessionID
        },
        accessToken: @escaping @Sendable () async throws -> String = {
            try await AuthService.shared.accessToken()
        }
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.transport = transport
        self.sessionID = sessionID
        self.accessToken = accessToken
    }

    // MARK: ChatServiceProtocol

    nonisolated func sendMessage(_ message: String) async throws -> String {
        let request = try await makeRequest(for: message)
        let (data, response) = try await perform(request)

        guard let http = response as? HTTPURLResponse else {
            throw ChatError.decodingFailed(description: "Response was not an HTTP response.")
        }

        guard Self.successStatusCodes.contains(http.statusCode) else {
            throw ChatError.httpStatus(
                code: http.statusCode,
                message: Self.errorMessage(in: data)
            )
        }

        return try Self.assembleReply(from: data)
    }

    nonisolated func streamMessage(_ message: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await emitReply(for: message, to: continuation)
                    continuation.finish()
                } catch {
                    // Single exit for every failure: whatever went wrong on the
                    // way here leaves as a `ChatError`, the same as the buffered
                    // call's `throw`.
                    continuation.finish(throwing: Self.chatError(from: error))
                }
            }
            // Dropping the stream drops the request; nothing keeps reading a body
            // no one is waiting for.
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Runs one streamed turn: builds the request, checks the status, then
    /// forwards each chunk to `continuation` as its frame completes.
    ///
    /// Returns normally once the `[DONE]` frame arrives. Anything else — a
    /// non-2xx, a body that stops early, bytes that aren't UTF-8 — throws, and
    /// ``streamMessage(_:)`` turns that into the stream's failure.
    private func emitReply(
        for message: String,
        to continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async throws {
        let request = try await makeRequest(for: message)
        let (bytes, response) = try await transport.stream(request)

        guard let http = response as? HTTPURLResponse else {
            throw ChatError.decodingFailed(description: "Response was not an HTTP response.")
        }

        guard Self.successStatusCodes.contains(http.statusCode) else {
            // The failure body is JSON and short, so reading it whole is fine —
            // and best effort, since the status alone already reports the failure.
            let body = (try? await Self.collect(bytes)) ?? Data()
            throw ChatError.httpStatus(
                code: http.statusCode,
                message: Self.errorMessage(in: body)
            )
        }

        var reader = EventFrameReader()
        var characterCount = 0

        /// Forwards a frame's chunk. Answers whether the stream just ended.
        func handle(_ frame: Data) throws -> Bool {
            guard let payload = try Self.dataPayload(inFrame: frame) else { return false }

            switch ChatStreamEvent(dataPayload: payload) {
            case let .chunk(text):
                // An empty `data:` field is framing, not content.
                guard !text.isEmpty else { return false }
                characterCount += text.count
                continuation.yield(text)
                return false
            case .done:
                // Same contract as the buffered path: the backend only opens an
                // event stream once it has real text, so terminating empty is a
                // broken contract rather than an empty reply.
                guard characterCount > 0 else {
                    throw ChatError.decodingFailed(
                        description: "Event stream closed without a reply chunk."
                    )
                }
                return true
            }
        }

        for try await byte in bytes {
            guard let frame = reader.append(byte) else { continue }
            if try handle(frame) { return }
        }

        // A body that stopped without its closing blank line still gets read, so
        // a stream whose last frame is `[DONE]` counts as complete either way.
        if let frame = reader.flush(), try handle(frame) { return }

        throw ChatError.decodingFailed(
            description: """
                Event stream ended without a \(ChatStreamEvent.doneSentinel) frame \
                after \(characterCount) characters.
                """
        )
    }

    // MARK: Request

    /// Builds the `POST` the backend expects: `{ sessionId, message }` as JSON,
    /// the publishable key in `apikey`, the user's access token in
    /// `Authorization`, and an `Accept` that states what a 200 will actually be.
    ///
    /// Suspends until the token is available, so a send that starts before
    /// sign-in has finished still carries one.
    private func makeRequest(for message: String) async throws -> URLRequest {
        try await makeRequest(
            body: ChatRequestDTO(sessionId: await sessionID(), message: message),
            accept: "text/event-stream"
        )
    }

    /// Builds a `POST` to the endpoint carrying `body` as JSON, with the same
    /// `apikey` and `Authorization` headers on every call — a chat turn and a
    /// report both go to the `chat` function and both need the user's token.
    private func makeRequest(body: some Encodable, accept: String) async throws -> URLRequest {
        guard let endpoint,
              let scheme = endpoint.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              endpoint.host?.isEmpty == false
        else {
            throw ChatError.invalidURL
        }

        let token: String
        do {
            token = try await accessToken()
        } catch {
            // Keeps the "nothing leaves this layer untyped" rule: a sign-in
            // failure is a `ChatError` like any other — but its own one, not the
            // catch-all ``ChatError/network(_:)`` the send path uses.
            throw Self.signInError(from: error)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // New-format publishable keys are not JWTs, so the key identifies the
        // project through `apikey` and never through `Authorization`, which
        // carries the Supabase-issued user token instead.
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            // A few strings can't realistically fail to encode; if they somehow do,
            // it is a wire-format problem like any other rather than a crash.
            throw ChatError.decodingFailed(
                description: "Could not encode the request body: \(error)"
            )
        }

        return request
    }

    /// Runs the request and folds every transport failure into
    /// ``ChatError/network(_:)``.
    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await transport.send(request)
        } catch {
            throw Self.chatError(from: error)
        }
    }

    /// Folds anything thrown on the way to a reply into ``ChatError``.
    ///
    /// A `ChatError` is already the answer and passes through. Beyond that only a
    /// transport failure is documented to arrive, so a `URLError` keeps its code
    /// and anything else lands on an unlabeled network failure — the point being
    /// that nothing escapes this layer untyped.
    private static func chatError(from error: any Error) -> ChatError {
        switch error {
        case let chatError as ChatError:
            return chatError
        case let urlError as URLError:
            return .network(urlError.code)
        case is CancellationError:
            return .network(.cancelled)
        default:
            return .network(.unknown)
        }
    }

    /// Folds anything thrown by the token closure into ``ChatError``.
    ///
    /// Same rules as ``chatError(from:)`` except for the catch-all: an
    /// unrecognized failure here is a *sign-in* failure, not an unlabeled network
    /// one. That distinction is the whole point — auth errors arrive as the SDK's
    /// own types, so without it every one of them read as "No connection" and
    /// pointed at the wrong layer.
    ///
    /// The two recognized cases are kept deliberately:
    ///
    /// - A `URLError` stays ``ChatError/network(_:)``. A sign-in that couldn't
    ///   reach the network *is* an offline device, and the connectivity copy is the
    ///   right thing to read.
    /// - A `CancellationError` stays ``ChatError/network(.cancelled)``. Dropping
    ///   the send while it waited on sign-in isn't a failed sign-in.
    private static func signInError(from error: any Error) -> ChatError {
        switch error {
        case let chatError as ChatError:
            return chatError
        case let urlError as URLError:
            return .network(urlError.code)
        case is CancellationError:
            return .network(.cancelled)
        default:
            return .signInFailed(description: String(describing: error))
        }
    }

    // MARK: Response

    private static let successStatusCodes = 200...299

    /// The SSE field carrying reply text. The backend writes one `data: <line>`
    /// per line of a chunk, then a blank line.
    private static let dataFieldName = "data"

    /// Pulls the client-facing message out of a non-2xx body.
    ///
    /// Best effort on purpose: a failure whose body is missing, truncated, or not
    /// the documented shape is still a failure, and the status code alone is
    /// enough to report it.
    private static func errorMessage(in data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ChatErrorResponseDTO.self, from: data).error
    }

    /// Joins the `data:` chunks of a completed event stream into the reply.
    ///
    /// Frames are split on the blank line between them rather than read line by
    /// line: a chunk with line breaks arrives as several `data:` lines in one
    /// frame, and ``dataPayload(in:)`` joins them back with `\n`.
    ///
    /// Anything after `[DONE]` is ignored, and its absence is a failure: without
    /// the terminator the stream was cut short, so what's on hand is a fragment
    /// rather than an answer.
    private static func assembleReply(from data: Data) throws -> String {
        guard let body = String(data: data, encoding: .utf8) else {
            throw ChatError.decodingFailed(description: "Response body was not valid UTF-8.")
        }

        // Normalized so a proxy that rewrites line endings can't hide the frame
        // boundaries. `\r\n`, lone `\r` and `\n` are all SSE line terminators.
        let frames = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")

        var reply = ""

        for frame in frames {
            guard let payload = dataPayload(in: frame) else { continue }

            switch ChatStreamEvent(dataPayload: payload) {
            case let .chunk(text):
                reply += text
            case .done:
                // The backend only commits to an SSE response once it has real
                // text to send (it answers 502 otherwise), so a stream that
                // terminates empty is a broken contract, not an empty reply.
                guard !reply.isEmpty else {
                    throw ChatError.decodingFailed(
                        description: "Event stream closed without a reply chunk."
                    )
                }
                return reply
            }
        }

        throw ChatError.decodingFailed(
            description: """
                Event stream ended without a \(ChatStreamEvent.doneSentinel) frame \
                after \(reply.count) characters.
                """
        )
    }

    /// Reads a whole body out of a byte stream.
    ///
    /// Only used for failure bodies, which are small JSON objects; a success body
    /// is never collected this way on the streaming path.
    private static func collect(_ bytes: ChatByteStream) async throws -> Data {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }

    /// ``dataPayload(in:)`` for a frame still in its wire form.
    ///
    /// Decoding happens per frame rather than per byte precisely so a multi-byte
    /// character split across two packets is whole by the time it is read.
    private static func dataPayload(inFrame frame: Data) throws -> String? {
        guard let text = String(data: frame, encoding: .utf8) else {
            throw ChatError.decodingFailed(description: "Response body was not valid UTF-8.")
        }
        return dataPayload(in: text)
    }

    /// The event's data, or `nil` for a frame that carries no `data:` field — a
    /// comment, a keep-alive, or the trailing newline after the stream.
    ///
    /// Follows the SSE event-stream rules: every `data:` line in the frame
    /// contributes one line to the payload (one optional space after the colon
    /// is stripped, the rest is the value), and the lines are joined with `\n`.
    /// That is how the backend sends a chunk containing line breaks — one
    /// `data: ` line per line of text — so paragraph breaks survive. Comments
    /// (`:` lines) and other fields are ignored.
    ///
    /// Internal rather than private so the framing rules can be pinned directly.
    static func dataPayload(in frame: String) -> String? {
        var dataLines: [Substring] = []

        // `\r\n` is folded before frames reach here; a lone `\r` is still a line
        // terminator per the spec. Splitting on `\n` + `\r` separately keeps a
        // stray `\r\n` from producing a spurious empty data line.
        let lines = frame
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: "\r", omittingEmptySubsequences: false) }

        for line in lines {
            // Blank lines are separators and `:` opens a comment.
            guard !line.isEmpty, line.first != ":" else { continue }

            let field: Substring
            var value: Substring
            if let colon = line.firstIndex(of: ":") {
                field = line[..<colon]
                value = line[line.index(after: colon)...]
            } else {
                field = line
                value = ""
            }

            guard field == dataFieldName else { continue }
            if value.first == " " { value = value.dropFirst() }
            dataLines.append(value)
        }

        guard !dataLines.isEmpty else { return nil }
        return dataLines.joined(separator: "\n")
    }
}

// MARK: - Incremental framing

/// Cuts an event stream into frames while the bytes are still arriving.
///
/// The incremental counterpart to the `components(separatedBy: "\n\n")` in
/// ``ChatService/assembleReply(from:)``, and it has to be a state machine for the
/// same reason the split can't be reused: a frame boundary, or a `\r\n` pair, or a
/// multi-byte character, can land across two packets, so no single byte is enough
/// to decide anything on its own.
///
/// Bytes go in one at a time and a frame comes out the moment its blank line
/// closes it. Frame content is handed back in wire form — decoding is the caller's
/// business, once the frame is whole.
private nonisolated struct EventFrameReader {

    private static let lineFeed = UInt8(0x0A)
    private static let carriageReturn = UInt8(0x0D)

    /// Bytes of the frame being read, with `\r\n` already folded to `\n`.
    private var frame = Data()

    /// A `\r` has been seen and it isn't yet known whether a `\n` follows it, so
    /// it can't be classified as a line ending or as content.
    private var pendingCarriageReturn = false

    /// Feeds one byte.
    ///
    /// - Returns: The frame this byte just closed, or `nil` while it is still
    ///   being read.
    mutating func append(_ byte: UInt8) -> Data? {
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            // `\r\n` is one line ending, matching the normalization the buffered
            // parser does in one pass.
            if byte == Self.lineFeed { return store(Self.lineFeed) }
            // A lone `\r` is a line ending too, per the SSE spec. It may close
            // the frame, in which case this byte starts the next one.
            if let completed = store(Self.lineFeed) {
                // The new frame is empty, so storing into it can't close it.
                if byte == Self.carriageReturn {
                    pendingCarriageReturn = true
                } else {
                    _ = store(byte)
                }
                return completed
            }
        }

        if byte == Self.carriageReturn {
            pendingCarriageReturn = true
            return nil
        }

        return store(byte)
    }

    /// Hands back whatever is left when the body ends without a closing blank
    /// line, or `nil` if nothing is.
    ///
    /// The buffered parser reads a trailing fragment as a frame, so this one does
    /// too — otherwise a body whose last line is `data: [DONE]` with no blank line
    /// after it would read as truncated.
    mutating func flush() -> Data? {
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            // A trailing `\r` is a line ending; if it closes a frame, that frame
            // is the one to hand back.
            if let completed = store(Self.lineFeed) { return completed }
        }

        guard !frame.isEmpty else { return nil }
        defer { frame.removeAll(keepingCapacity: false) }
        return frame
    }

    /// Adds a normalized byte, completing the frame if it closes the blank line.
    private mutating func store(_ byte: UInt8) -> Data? {
        guard byte == Self.lineFeed, frame.last == Self.lineFeed else {
            frame.append(byte)
            return nil
        }

        // Two newlines in a row: the frame ends before the first of them.
        let completed = Data(frame.dropLast())
        frame.removeAll(keepingCapacity: true)
        return completed
    }
}

// MARK: - Reporting

extension ChatService: MessageReporting {

    /// Reports a reply through the `chat` function's `report` action.
    ///
    /// Same endpoint, headers and token as a chat turn, and the same session id,
    /// so the report lands against the conversation it came from. Any 2xx means
    /// the row was stored (the backend answers 201); everything else is a
    /// ``ChatError``, so a failure is never mistaken for a success.
    nonisolated func reportMessage(id messageID: UUID, text: String) async throws {
        let request = try await makeRequest(
            body: ReportRequestDTO(
                sessionId: await sessionID(),
                messageId: messageID.uuidString,
                messageText: text
            ),
            accept: "application/json"
        )
        let (data, response) = try await perform(request)

        guard let http = response as? HTTPURLResponse else {
            throw ChatError.decodingFailed(description: "Response was not an HTTP response.")
        }
        guard Self.successStatusCodes.contains(http.statusCode) else {
            throw ChatError.httpStatus(
                code: http.statusCode,
                message: Self.errorMessage(in: data)
            )
        }
    }
}
