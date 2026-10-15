//
//  SessionManager.swift
//  Astrologie
//
//  Owns the client-generated session identifier the backend uses to scope its
//  rate limit and conversation-turn counters. A new id is minted for each launch
//  and held in memory; the service layer just asks for ``SessionManager/sessionID``
//  and drops it into `ChatRequestDTO`.
//
//  One launch, one session (Week 10 Task 4). The id used to live in the Keychain
//  and survive relaunches, but messages are in memory only, so a relaunch showed
//  an empty chat while the backend kept counting turns from before — a chat that
//  looked new could hit "Conversation limit reached" early. Minting per launch
//  keeps the two in step.
//
//  Two unrelated things in this app get called a "session". They are not
//  interchangeable:
//
//  - **This one.** A client-generated `UUID` that travels in the request *body*.
//    It is a grouping key — the backend counts requests and conversation turns
//    against it — and it proves nothing about who is asking. Anyone could send any
//    id; it authenticates nothing.
//  - **The Supabase auth session.** A server-issued JWT that travels in the
//    `Authorization` *header*, owned by ``AuthService``. That one is the identity,
//    and the `chat` function answers 401 without it. It still lives in the
//    Keychain and survives relaunch.
//
//  So they stay apart: this id must never be sent as a bearer token, and the
//  access token must never be used as the session id.
//

import Foundation

/// Single source of truth for the session identifier.
///
/// First read generates a `UUID` string; every read after that in the same launch
/// returns that same value, until ``resetSession()`` mints another. Nothing is
/// persisted, so the next launch starts a new session.
final class SessionManager {

    /// Shared instance the app and service layer use.
    static let shared = SessionManager()

    private let generateID: () -> String

    /// Guards ``currentID`` so concurrent callers can't mint two identifiers.
    private let lock = NSLock()
    private var currentID: String?

    init(generateID: @escaping () -> String = { UUID().uuidString }) {
        self.generateID = generateID
    }

    /// The session identifier for this launch.
    ///
    /// Generated on first access and held in memory for the life of the process.
    ///
    /// - Note: Goes in the request body as `ChatRequestDTO/sessionId`, never in a
    ///   header. It is a counter key, not a credential — see the file header, and
    ///   ``AuthSession`` for the token that actually authorizes a request.
    var sessionID: String {
        lock.lock()
        defer { lock.unlock() }

        if let currentID { return currentID }

        let generated = generateID()
        currentID = generated
        return generated
    }

    /// Mints a new identifier and makes it the one ``sessionID`` returns from now
    /// on.
    ///
    /// The backend scopes its per-conversation turn counter to the session id with
    /// no expiry and no reset of its own (`turnCounter.ts`), so once a
    /// conversation hits that limit the only way past a 403 is a different id —
    /// this is that escape hatch, behind "Start new conversation".
    ///
    /// - Returns: The new session identifier.
    @discardableResult
    func resetSession() -> String {
        lock.lock()
        defer { lock.unlock() }

        let generated = generateID()
        currentID = generated
        return generated
    }
}
