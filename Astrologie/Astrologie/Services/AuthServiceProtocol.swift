//
//  AuthServiceProtocol.swift
//  Astrologie
//
//  The seam between the app and Supabase Auth. Anything that needs an access
//  token is written against this protocol, never against the SDK, so a test can
//  hand over a canned token with no network — the same arrangement
//  `ChatServiceProtocol` gives the ViewModel.
//

import Foundation

// MARK: - Identity

/// A signed-in Supabase identity: who the backend takes us for, and the token
/// that proves it.
///
/// Not to be confused with ``SessionManager``'s session identifier. That one is
/// client-generated, travels in the request *body*, and scopes the backend's
/// rate-limit and conversation-turn counters — it authenticates nothing. This one
/// is server-issued and travels in the `Authorization` *header*. Two different
/// things that both get called a "session"; keeping them apart is the point.
nonisolated struct AuthSession: Equatable, Sendable {

    /// The user's id — the `sub` claim of ``accessToken``.
    ///
    /// Stable for the life of the install once sign-in has happened, which is the
    /// whole reason the session is persisted: a new anonymous user on every
    /// launch would silently reset whatever the backend keys to this id.
    let userID: String

    /// A JWT, ready to go out as `Authorization: Bearer <token>`.
    ///
    /// Short-lived — roughly an hour — and refreshed underneath
    /// ``AuthServiceProtocol/signIn()``, so it is asked for per request rather
    /// than captured once at construction.
    let accessToken: String
}

// MARK: - Seam

/// Establishes the app's identity and supplies the token requests are authorized
/// with.
///
/// One requirement, because there is only one question worth asking: *who are we,
/// right now?* Answering it may mean signing in, reusing a stored session, or
/// refreshing an expired token, and no caller should have to know which.
///
/// Conformers must be `Sendable` and the requirement is `nonisolated`, matching
/// ``ChatServiceProtocol``: sign-in is network work and has no business on the
/// main actor, and one instance is shared by everything that sends a request.
nonisolated protocol AuthServiceProtocol: Sendable {

    /// The current identity, signing in anonymously if there isn't one yet.
    ///
    /// Idempotent by design: the first call on a fresh install creates an
    /// anonymous user, and every call after that — later in the same launch or in
    /// a later launch — hands back that same user. Calling it twice must not
    /// produce two users.
    ///
    /// - Returns: A usable ``AuthSession``, with a token good to send now.
    /// - Throws: Whatever the underlying auth provider reports. Callers don't have
    ///   to classify it: ``ChatService`` folds it into
    ///   ``ChatError/signInFailed(description:)``, which the banner reads as a
    ///   sign-in problem rather than a connectivity one.
    func signIn() async throws -> AuthSession
}

// MARK: - Token convenience

extension AuthServiceProtocol {

    /// The access token for the current identity, signing in first if needed.
    ///
    /// Sugar over ``signIn()`` for the common caller, which wants a bearer token
    /// and nothing else. Async rather than a stored value on purpose: a token
    /// read once and kept is a token that expires, and on a cold launch it is a
    /// token read before sign-in ever resolved.
    func accessToken() async throws -> String {
        try await signIn().accessToken
    }
}
