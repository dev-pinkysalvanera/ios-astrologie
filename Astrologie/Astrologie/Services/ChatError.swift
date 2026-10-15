//
//  ChatError.swift
//  Astrologie
//
//  The single failure type the chat service layer throws. Everything that can go
//  wrong on the way to a reply — a malformed endpoint, a dropped connection, a
//  non-2xx answer, a body that doesn't decode — arrives at the ViewModel as one
//  of these cases, so callers never have to pattern-match on `URLError`,
//  `DecodingError` and raw status codes side by side.
//

import Foundation

/// A failure raised while sending a message to the chat backend.
///
/// Payloads are deliberately plain value types rather than the underlying
/// `Error` values: it keeps the enum `Equatable`, which lets tests assert on an
/// exact failure and lets a view state carry the error without breaking value
/// semantics (see the `failed(ChatError)` state in Week 5, Task 5).
nonisolated enum ChatError: Error, Equatable {

    /// The request URL could not be formed from the configured base URL and path.
    ///
    /// A programming or configuration error, not something the person can retry.
    case invalidURL

    /// Sign-in didn't produce a token, so the request never went out.
    ///
    /// Its own case rather than a fold into ``network(_:)``: this failure happens
    /// *before* the request is built, and a device that can't sign in is not a
    /// device that's offline. Reading it as "No connection" is what would send the
    /// next debugging session looking at the network instead of at Supabase Auth.
    ///
    /// A genuinely offline sign-in still lands on ``network(_:)`` — the token
    /// closure's `URLError` keeps its code — so this case means "auth said no",
    /// not "the attempt didn't get out".
    ///
    /// - Parameter description: Diagnostics from the underlying auth failure.
    ///   For logging only; never shown to the person using the app.
    case signInFailed(description: String)

    /// The request never completed: offline, timed out, TLS rejected, cancelled.
    ///
    /// Carries `URLError.Code` rather than the whole `URLError` so the case stays
    /// comparable; `URLError.Code.notConnectedToInternet` and friends are what a
    /// caller actually branches on.
    case network(URLError.Code)

    /// The backend answered with a non-2xx status.
    ///
    /// - Parameters:
    ///   - code: The HTTP status code. The `chat` function uses 400, 401, 403,
    ///     413, 429, 500, 502, 503 (limit store unreachable) and 504.
    ///   - message: The `error` string from ``ChatErrorResponseDTO``, or `nil`
    ///     when the body was missing or unreadable.
    case httpStatus(code: Int, message: String?)

    /// The response arrived but could not be read as the expected shape.
    ///
    /// - Parameter description: Diagnostics from the underlying decoding failure.
    ///   For logging only; never shown to the person using the app.
    case decodingFailed(description: String)

    /// The status that means the token the request carried wasn't accepted.
    ///
    /// Named because ``errorDescription`` treats it differently from every other
    /// non-2xx, and because the number appearing in two places is how the case and
    /// its copy drift apart.
    static let unauthorizedStatusCode = 401

    /// The status the backend answers with once a session's turn count hits
    /// `turnCounter.ts`'s `DEFAULT_MAX_TURNS`.
    ///
    /// Named for the same reason as ``unauthorizedStatusCode``: ``errorDescription``
    /// and the escape hatch in the banner both need to recognize this specific
    /// 403 rather than the generic "couldn't answer that" every other non-2xx
    /// falls back to.
    static let turnLimitStatusCode = 403
}

// MARK: - Turn limit

extension ChatError {

    /// Whether this is the 403 the backend answers once a session's turn count is
    /// exhausted, rather than some other rejection that happens to share the
    /// status code.
    ///
    /// The one thing the banner needs to decide whether to offer a way past a
    /// dead end: the backend's turn counter has no expiry, so without this,
    /// message 21 is where the conversation ends.
    nonisolated var isTurnLimitReached: Bool {
        if case .httpStatus(Self.turnLimitStatusCode, _) = self {
            return true
        }
        return false
    }
}

// MARK: - Presentation

extension ChatError: LocalizedError {

    /// A message safe to show in the UI.
    ///
    /// Three failures that used to read alike now read apart, because each one
    /// points somewhere different:
    ///
    /// - ``signInFailed(description:)`` says so. It used to arrive as
    ///   ``network(_:)`` and read as "No connection", which is the wrong place to
    ///   start looking.
    /// - ``network(_:)`` keeps the connectivity copy, and now only means that.
    /// - A 401 gets its own line instead of the backend's. The request *did* carry
    ///   a token (see ``ChatService``), so a rejection means the session is no
    ///   longer good rather than the question being wrong — and the handler's own
    ///   wording for it ("Missing authorization header") describes the wire, not
    ///   anything the person can act on.
    ///
    /// Every other ``httpStatus(code:message:)`` still prefers the backend's text,
    /// which is already written for a client audience, with a generic line standing
    /// in when the body carried nothing usable. No case leaks its diagnostics or a
    /// status code.
    nonisolated var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Couldn't reach the astrologer. Please try again later."
        case .signInFailed:
            return "Couldn't sign you in. Please try again."
        case .network:
            return "No connection. Check your network and try again."
        case let .httpStatus(code, message):
            guard code != Self.unauthorizedStatusCode else {
                return "Your session expired. Please restart the app and try again."
            }
            // The turn-limit 403 keeps the backend's own wording rather than
            // getting an override like 401's: "Conversation limit reached. Please
            // start a new thread." already says what happened and reads fine on
            // its own. What it lacks is a way to *act* on it, which is why the
            // banner adds a button rather than this case adding a line — see
            // ``isTurnLimitReached`` and `ChatView.errorBanner`.
            return message ?? "The astrologer couldn't answer that. Please try again."
        case .decodingFailed:
            return "Got an unexpected answer from the astrologer. Please try again."
        }
    }
}
