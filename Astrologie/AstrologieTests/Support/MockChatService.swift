//
//  MockChatService.swift
//  AstrologieTests
//
//  One scriptable stand-in for `ChatServiceProtocol` (Week 10 Task 1), replacing
//  the per-file stubs that each did one of these things. It answers each send
//  from a script — a reply, an echo, a failure, a 429, a reply that fails part
//  way, or a stream the test holds — and can delay, park mid-send, and record
//  what it was sent. Nothing touches the network.
//
//  Two stubs stay outside it on purpose: `ChatServiceProtocolTests` and
//  `ChatServiceStreamingTests` test the protocol's *default* `streamMessage`,
//  and this mock overrides it.
//

import Foundation
import Testing

@testable import Astrologie

/// A ``ChatServiceProtocol`` that answers from a script.
///
/// Send N gets `responses[N]`, and every send past the end gets the last one,
/// so `MockChatService(.echo)` echoes forever and
/// `MockChatService(.failure(e), .echo)` fails once and then recovers.
struct MockChatService: ChatServiceProtocol {

    /// What one send gets back.
    enum Response: Sendable {
        /// The reply, delivered as these pieces in order.
        case reply([String])

        /// "echo: <the message>", in one piece. Shows the message reached the
        /// service without the test spelling out the reply.
        case echo

        /// Fails before any of the reply arrives.
        case failure(ChatError)

        /// Delivers these pieces, then fails: a reply cut off part way.
        case partial([String], then: ChatError)

        /// Forwards a stream the test already holds the continuation for, so the
        /// test decides when each piece exists. Ignores the delays.
        case handed(AsyncThrowingStream<String, any Error>)

        /// A one-piece reply.
        static func reply(_ text: String) -> Response {
            .reply([text])
        }

        /// The backend's per-session rate limit: a 429 with its own wording.
        static func rateLimited(
            message: String? = MockChatService.rateLimitMessage
        ) -> Response {
            .failure(.httpStatus(code: 429, message: message))
        }
    }

    /// `ERROR_MESSAGE.RATE_LIMITED` in `handler.ts`.
    static let rateLimitMessage = "Rate limit exceeded. Try again later."

    /// Every message sent, in order. Shared across copies, since the service is
    /// a value type.
    let log = Log()

    private let responses: [Response]
    private let firstPieceDelay: Duration
    private let betweenPieces: Duration
    private let gate: Gate?

    /// - Parameters:
    ///   - responses: The script. Must not be empty.
    ///   - firstPieceDelay: Wait before anything arrives, failures included.
    ///     Real time, so a test can observe `.sending`.
    ///   - betweenPieces: Wait between pieces of a reply.
    ///   - gate: Parks every send after it starts until the test opens it.
    init(
        _ responses: Response...,
        firstPieceDelay: Duration = .zero,
        betweenPieces: Duration = .zero,
        gate: Gate? = nil
    ) {
        precondition(!responses.isEmpty, "A MockChatService needs at least one response.")
        self.responses = responses
        self.firstPieceDelay = firstPieceDelay
        self.betweenPieces = betweenPieces
        self.gate = gate
    }

    // MARK: ChatServiceProtocol

    /// The streamed reply, joined. Same script, same log.
    func sendMessage(_ message: String) async throws -> String {
        var reply = ""
        for try await piece in streamMessage(message) {
            reply += piece
        }
        return reply
    }

    func streamMessage(_ message: String) -> AsyncThrowingStream<String, any Error> {
        let (log, responses, gate) = (log, responses, gate)
        let (firstPieceDelay, betweenPieces) = (firstPieceDelay, betweenPieces)

        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let index = await log.record(message)
                    let response = responses[min(index, responses.count - 1)]

                    if let gate {
                        await gate.enter()
                    }
                    if case let .handed(stream) = response {
                        for try await piece in stream { continuation.yield(piece) }
                        continuation.finish()
                        return
                    }
                    if firstPieceDelay > .zero {
                        try await Task.sleep(for: firstPieceDelay)
                    }

                    let pieces: [String]
                    let failure: ChatError?
                    switch response {
                    case let .reply(replyPieces):
                        (pieces, failure) = (replyPieces, nil)
                    case .echo:
                        (pieces, failure) = (["echo: \(message)"], nil)
                    case let .failure(error):
                        (pieces, failure) = ([], error)
                    case let .partial(partPieces, error):
                        (pieces, failure) = (partPieces, error)
                    case .handed:
                        return  // Handled above.
                    }

                    for (index, piece) in pieces.enumerated() {
                        if index > 0, betweenPieces > .zero {
                            try await Task.sleep(for: betweenPieces)
                        }
                        continuation.yield(piece)
                    }
                    if let failure {
                        continuation.finish(throwing: failure)
                    } else {
                        continuation.finish()
                    }
                } catch is CancellationError {
                    // The consumer went away mid-wait: just end.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}

// MARK: - Log

extension MockChatService {

    /// What the mock was sent.
    actor Log {
        /// Every message, oldest first.
        private(set) var messages: [String] = []

        /// Records `message` and answers its zero-based send number.
        fileprivate func record(_ message: String) -> Int {
            messages.append(message)
            return messages.count - 1
        }
    }
}

// MARK: - Gate

extension MockChatService {

    /// Parks a send mid-flight so the test can look at the screen while the
    /// reply is outstanding.
    ///
    /// The send calls ``enter()``: that marks it as entered, then waits for
    /// ``release()``. The test awaits ``waitUntilEntered()``, checks what it
    /// wants, then releases. Once released, later sends pass straight through.
    actor Gate {
        private let entered = Latch()
        private let released = Latch()

        init() {}

        /// Called by the mock: signals arrival, then waits to be let through.
        fileprivate func enter() async {
            await entered.open()
            await released.wait()
        }

        /// Suspends until a send has reached the gate.
        func waitUntilEntered() async {
            await entered.wait()
        }

        /// Lets every parked and future send through.
        func release() async {
            await released.open()
        }
    }
}

/// One-shot latch. Lets a test and a suspended task step past each other in a
/// known order instead of racing on sleeps.
actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until ``open()`` is called, or returns straight away if it
    /// already was.
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Releases everyone waiting, and everyone who waits later.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
