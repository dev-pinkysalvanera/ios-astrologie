//
//  ChatServiceProtocol.swift
//  Astrologie
//
//  The seam between the ViewModel and the network. The ViewModel is written
//  against this protocol, never against a concrete type, so it can be driven by
//  the real `URLSession` client or by a stub in a test without either side
//  knowing the difference.
//

import Foundation

/// Sends a message to the astrologer and hands back the reply.
///
/// Two ways to ask for the same thing: ``sendMessage(_:)`` waits for the whole
/// reply, ``streamMessage(_:)`` hands over the pieces as they arrive. The session
/// identifier, endpoint and headers are the implementation's business either way
/// (it reads the id from ``SessionManager`` and fills in ``ChatRequestDTO``), so
/// callers only ever supply the text the person typed.
///
/// The streaming method is an addition, not a replacement: the backend has always
/// emitted server-sent events, and a caller that just wants a finished string —
/// a preview, a test — is still better served by the buffered call.
///
/// Conformers must be `Sendable` so a single instance can be shared by a
/// `@MainActor` ViewModel and used from a background context. Both methods are
/// `nonisolated` for the same reason — the network work has no business running
/// on the main actor.
protocol ChatServiceProtocol: Sendable {

    /// Sends `message` and waits for the astrologer's full reply.
    ///
    /// - Parameter message: The person's message. Expected to be non-empty once
    ///   trimmed and no longer than ``ChatRequestDTO/maxMessageLength``; the
    ///   backend answers 400 otherwise, which surfaces as
    ///   ``ChatError/httpStatus(code:message:)``.
    /// - Returns: The reply text, ready to drop into a ``ChatMessage``.
    /// - Throws: ``ChatError`` for every failure mode.
    nonisolated func sendMessage(_ message: String) async throws -> String

    /// Sends `message` and hands back the reply in pieces, as the backend
    /// produces them.
    ///
    /// The call itself doesn't suspend: the request goes out when the returned
    /// stream is first iterated, and every element is one piece of the reply,
    /// ready to append to a ``ChatMessage/text`` in place. A complete reply is the
    /// concatenation of everything yielded, so a caller that joins the elements
    /// ends up exactly where ``sendMessage(_:)`` would have left it.
    ///
    /// Failures arrive by terminating the stream, including one that only shows up
    /// partway through — so a caller can be handed several pieces and *then* an
    /// error. Cancelling the iteration cancels the request.
    ///
    /// - Parameter message: The person's message, same expectations as
    ///   ``sendMessage(_:)``.
    /// - Returns: The reply's pieces in order. Throws ``ChatError`` on failure,
    ///   including a stream that ends before the backend said it was finished.
    nonisolated func streamMessage(_ message: String) -> AsyncThrowingStream<String, any Error>
}

// MARK: - Buffered fallback

extension ChatServiceProtocol {

    /// Streams by way of ``sendMessage(_:)``: one element carrying the whole
    /// reply, once it has all arrived.
    ///
    /// Here so the streaming method is an addition rather than a breaking change —
    /// a conformer with nothing but a buffered reply to offer (a stub, a preview)
    /// stays valid and still satisfies a streaming caller. It is not *streaming*
    /// in any useful sense, so a conformer that can do better should say so;
    /// ``ChatService`` overrides it.
    nonisolated func streamMessage(_ message: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let reply = try await sendMessage(message)
                    // An empty reply is no reply: yielding "" would hand the
                    // caller a token that says nothing.
                    if !reply.isEmpty { continuation.yield(reply) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }
}
