//
//  ChatAPIDTOs.swift
//  Astrologie
//
//  Wire-format types for the `chat` edge function. These mirror the backend
//  contract in `supabase/functions/chat/handler.ts` and nothing else — they are
//  deliberately kept apart from the view-layer model so the two can diverge.
//

import Foundation

// MARK: - Request

/// Request body for `POST /functions/v1/chat`.
///
/// Mirrors `ValidatedChatRequest` in `handler.ts`: a JSON object with exactly
/// `sessionId` and `message`, both required strings. The backend rejects
/// anything else with a 400 and a ``ChatErrorResponseDTO`` body.
nonisolated struct ChatRequestDTO: Codable, Equatable {
    /// Client-generated session identifier. Scopes the backend's rate limit and
    /// conversation-turn counters.
    let sessionId: String

    /// The user's message. Must be non-empty once trimmed and at most
    /// ``maxMessageLength`` characters, or the backend answers 400.
    let message: String
}

extension ChatRequestDTO {
    /// `MAX_MESSAGE_LENGTH` in `handler.ts` — the character ceiling the backend
    /// enforces on `message`.
    nonisolated static let maxMessageLength = 2000
}

// MARK: - Report request

/// Request body for reporting an assistant reply: `POST /functions/v1/chat` with
/// `action: "report"`.
///
/// Mirrors `handleReport` in `handler.ts`. `sessionId`, `messageId` and
/// `messageText` are required; `reason` is optional and left out, since reporting
/// is a single tap with nothing to choose. Answered with 201 on success, or the
/// usual ``ChatErrorResponseDTO`` shape.
nonisolated struct ReportRequestDTO: Codable, Equatable {
    /// Routes the request to `handleReport` instead of the chat path.
    let action: String

    /// The session the reply belongs to.
    let sessionId: String

    /// The reply's client-side ``ChatMessage/id``. Only meaningful alongside the
    /// text: the backend never sees message ids otherwise.
    let messageId: String

    /// The reply as the model produced it, markdown and all — not the stripped
    /// text the bubble shows. Replies aren't stored anywhere else, so this is the
    /// only record of what was reported.
    let messageText: String

    init(sessionId: String, messageId: String, messageText: String) {
        self.action = Self.action
        self.sessionId = sessionId
        self.messageId = messageId
        self.messageText = messageText
    }
}

extension ReportRequestDTO {
    /// The `action` value `handler.ts` routes to `handleReport`.
    nonisolated static let action = "report"
}

// MARK: - Success response

/// One decoded frame of the success response.
///
/// A 200 is `text/event-stream`, not JSON: the backend emits
/// `data: <text chunk>\n\n` for each piece of the reply and closes with
/// `data: [DONE]\n\n`. There is no JSON success body, so this enum stands in
/// for the "response DTO" of the happy path.
nonisolated enum ChatStreamEvent: Equatable {
    /// A piece of the assistant's reply, taken verbatim from a `data:` field.
    ///
    /// The backend substitutes the literal text `[Content filtered]` for a chunk
    /// its output moderator rejects; that still arrives as an ordinary chunk.
    case chunk(String)

    /// The terminating `data: [DONE]` frame. The reply is complete.
    case done
}

extension ChatStreamEvent {
    /// The payload the backend uses to signal end of stream.
    nonisolated static let doneSentinel = "[DONE]"

    /// Classifies the payload of a single SSE `data:` field.
    nonisolated init(dataPayload: String) {
        self = dataPayload == Self.doneSentinel ? .done : .chunk(dataPayload)
    }
}

// MARK: - Error response

/// Body of every non-2xx response from the `chat` function.
///
/// The backend funnels all failures through one helper, so the shape is stable:
/// `{ "error": String }`, optionally with a `debug` object attached. Statuses in
/// use are 400, 401, 403, 413, 429, 500, 502 and 504.
nonisolated struct ChatErrorResponseDTO: Codable, Equatable {
    /// Client-facing failure message. Always present.
    let error: String

    /// Optional diagnostics. Unstructured on the wire, so only the one field the
    /// client can act on is surfaced; see ``ChatErrorDebugDTO``.
    let debug: ChatErrorDebugDTO?

    private enum CodingKeys: String, CodingKey {
        case error
        case debug
    }

    init(error: String, debug: ChatErrorDebugDTO? = nil) {
        self.error = error
        self.debug = debug
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decode(String.self, forKey: .error)
        // `debug` carries whatever the failing path chose to attach. A shape we
        // don't recognize must never take down the decode of `error`.
        debug = try? container.decodeIfPresent(ChatErrorDebugDTO.self, forKey: .debug)
    }
}

/// The recognized slice of the backend's free-form `debug` payload.
///
/// Everything else the backend attaches (`stage`, `name`, `status`, `maxTurns`,
/// …) is diagnostic-only and intentionally not modeled.
nonisolated struct ChatErrorDebugDTO: Codable, Equatable {
    /// Backoff hint sent with a 429, in milliseconds. Mirrors the `Retry-After`
    /// header on the same response.
    let retryAfterMs: Int?
}
