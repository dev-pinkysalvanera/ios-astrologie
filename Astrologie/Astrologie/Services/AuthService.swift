//
//  AuthService.swift
//  Astrologie
//
//  The real ``AuthServiceProtocol``: one anonymous user per install, the Supabase
//  SDK keeping that session in the Keychain so a relaunch picks the same user back
//  up, and the access token asked for fresh every time so an expired one is the
//  SDK's problem rather than a stale string someone captured.
//
//  Anonymous rather than email/password because the app has no sign-up flow and
//  doesn't want one: the backend only needs to know that a caller is *a* user, and
//  it scopes everything else by the session id in the request body.
//

import Foundation
import Supabase

// MARK: - Provider seam

/// The two things this service needs from Supabase Auth.
///
/// Narrow on purpose, and written in this app's own ``AuthSession`` rather than the
/// SDK's `Session`: a test hands over a stub that persists a canned session, which
/// is what makes the reuse-don't-re-mint rule below provable without a network or
/// a Keychain. Same idea as ``ChatTransport`` for ``ChatService``.
nonisolated protocol AuthSessionProvider: Sendable {

    /// The persisted session, with its token refreshed if it had expired, or `nil`
    /// if nobody has signed in on this install yet.
    ///
    /// - Throws: Only for a genuine failure. "Nobody signed in" is `nil`, not an
    ///   error — it is the expected state of a fresh install.
    func storedSession() async throws -> AuthSession?

    /// Creates a new anonymous user and persists the resulting session.
    func signInAnonymously() async throws -> AuthSession
}

// MARK: - SDK-backed provider

/// ``AuthSessionProvider`` backed by `supabase-swift`.
///
/// Thin by intent — it maps the SDK's `Session` onto ``AuthSession`` and nothing
/// else. Persistence is the SDK's: it writes the session to the Keychain by
/// default, which is what makes a relaunch reuse the same anonymous user, and also
/// why this type is the one thing in the auth path a unit test doesn't exercise.
nonisolated struct SupabaseAuthSessionProvider: AuthSessionProvider {

    private let client: SupabaseClient

    /// - Parameter client: The Supabase client whose `auth` is used. Defaults to
    ///   one built from ``SupabaseConfig``.
    init(
        client: SupabaseClient = SupabaseClient(
            supabaseURL: SupabaseConfig.projectURL,
            supabaseKey: SupabaseConfig.publishableKey
        )
    ) {
        self.client = client
    }

    func storedSession() async throws -> AuthSession? {
        do {
            // `session` rather than `currentSession`: the latter can hand back an
            // expired token, this one refreshes first.
            return AuthSession(try await client.auth.session)
        } catch AuthError.sessionMissing {
            // First launch, or a session that was signed out. Not a failure.
            return nil
        }
    }

    func signInAnonymously() async throws -> AuthSession {
        AuthSession(try await client.auth.signInAnonymously())
    }
}

private extension AuthSession {

    /// Narrows the SDK's session to the two fields this app has any use for.
    init(_ session: Session) {
        self.init(
            userID: session.user.id.uuidString,
            accessToken: session.accessToken
        )
    }
}

// MARK: - Auth service

/// Single source of truth for the app's Supabase identity.
///
/// An `actor` rather than a lock-guarded value type because every step here is
/// async. The serialization it buys is the point: two sends firing at once on a
/// fresh install must not create two anonymous users, which would split the
/// backend's per-user state between them.
///
/// Nothing is cached. Each ask goes to the provider, which answers from persisted
/// storage and refreshes an expired token on the way — so a long-lived instance
/// can't end up handing out a token that stopped working an hour ago.
actor AuthService: AuthServiceProtocol {

    /// Shared instance the app signs in with at launch.
    static let shared = AuthService()

    private let provider: any AuthSessionProvider

    /// The sign-in currently in flight, if there is one.
    ///
    /// Held only for the length of that call. Joining it is what makes concurrent
    /// first callers share one new user instead of racing to mint several.
    private var signInTask: Task<AuthSession, any Error>?

    /// - Parameter provider: Source of sessions. Defaults to the SDK-backed
    ///   provider; tests inject one that persists in memory.
    init(provider: any AuthSessionProvider = SupabaseAuthSessionProvider()) {
        self.provider = provider
    }

    // MARK: AuthServiceProtocol

    func signIn() async throws -> AuthSession {
        if let stored = try await provider.storedSession() { return stored }

        if let signInTask { return try await signInTask.value }

        let task = Task { try await provider.signInAnonymously() }
        signInTask = task
        // Cleared whichever way the call ends: a failed sign-in shouldn't leave a
        // dead task behind for the next caller to join.
        defer { signInTask = nil }

        return try await task.value
    }
}
