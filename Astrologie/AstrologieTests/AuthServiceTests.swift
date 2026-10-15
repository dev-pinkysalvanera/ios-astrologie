//
//  AuthServiceTests.swift
//  AstrologieTests
//
//  Covers the sign-in-once contract: a fresh install mints an anonymous user, a
//  relaunch reuses it rather than minting a second one, concurrent first callers
//  share one sign-in, and the token is read fresh each time so a refresh isn't
//  hidden behind a cached value. All of it through the ``AuthSessionProvider``
//  seam — no network, no Keychain.
//

import Foundation
import Testing

@testable import Astrologie

// MARK: - Doubles

/// In-memory ``AuthSessionProvider`` standing in for the SDK.
///
/// ``stored`` plays the part of the Keychain the SDK writes to, so two
/// ``AuthService`` instances over one provider is this suite's app relaunch — the
/// same trick ``SessionManagerTests`` uses for the session id.
private final class InMemoryAuthSessionProvider: AuthSessionProvider, @unchecked Sendable {

    /// The persisted session, if sign-in has happened.
    var stored: AuthSession?

    /// How many anonymous users have been created. More than one is the bug this
    /// suite exists to catch.
    var signInCount = 0

    var signInError: (any Error)?
    var storedSessionError: (any Error)?

    /// Runs just before a sign-in resolves. Lets a test hold the first call open
    /// long enough for a second one to arrive.
    var beforeSignIn: (@Sendable () async -> Void)?

    init(stored: AuthSession? = nil) {
        self.stored = stored
    }

    func storedSession() async throws -> AuthSession? {
        if let storedSessionError { throw storedSessionError }
        return stored
    }

    func signInAnonymously() async throws -> AuthSession {
        await beforeSignIn?()
        if let signInError { throw signInError }

        signInCount += 1
        let session = AuthSession(
            userID: "user-\(signInCount)",
            accessToken: "token-\(signInCount)"
        )
        stored = session
        return session
    }
}

/// Canned-token ``AuthServiceProtocol``: the seam's reason for existing.
///
/// What a test of a token-consuming type injects instead of reaching a network.
private struct CannedAuthService: AuthServiceProtocol {
    let session: AuthSession

    func signIn() async throws -> AuthSession { session }
}

private enum ProviderFailure: Error { case unavailable }

// MARK: - Tests

struct AuthServiceTests {

    // MARK: First launch

    @Test func firstLaunchSignsInAnonymouslyAndHoldsAToken() async throws {
        let provider = InMemoryAuthSessionProvider()
        let service = AuthService(provider: provider)

        let session = try await service.signIn()

        #expect(!session.accessToken.isEmpty)
        #expect(!session.userID.isEmpty)
        #expect(provider.signInCount == 1)
        #expect(provider.stored == session)
    }

    @Test func repeatedAsksInOneLaunchReuseTheSameUser() async throws {
        let provider = InMemoryAuthSessionProvider()
        let service = AuthService(provider: provider)

        let first = try await service.signIn()
        let second = try await service.signIn()

        #expect(second == first)
        #expect(provider.signInCount == 1)
    }

    // MARK: Relaunch

    @Test func secondLaunchReportsTheSameUserID() async throws {
        let provider = InMemoryAuthSessionProvider()

        let firstLaunch = AuthService(provider: provider)
        let original = try await firstLaunch.signIn()

        // Simulates a relaunch: new service, same persisted session. A second
        // sign-in would hand back `user-2`.
        let secondLaunch = AuthService(provider: provider)
        let afterRelaunch = try await secondLaunch.signIn()

        #expect(afterRelaunch.userID == original.userID)
        #expect(provider.signInCount == 1)
    }

    @Test func aStoredSessionIsUsedWithoutSigningInAtAll() async throws {
        let provider = InMemoryAuthSessionProvider(
            stored: AuthSession(userID: "persisted-user", accessToken: "persisted-token")
        )
        let service = AuthService(provider: provider)

        let session = try await service.signIn()

        #expect(session.userID == "persisted-user")
        #expect(provider.signInCount == 0)
    }

    // MARK: Concurrency

    @Test func concurrentFirstAsksShareOneSignIn() async throws {
        let provider = InMemoryAuthSessionProvider()
        provider.beforeSignIn = { try? await Task.sleep(for: .milliseconds(50)) }
        let service = AuthService(provider: provider)

        async let first = service.signIn()
        async let second = service.signIn()
        let sessions = try await [first, second]

        #expect(sessions[0] == sessions[1])
        // Two users here would split the backend's per-user state between them.
        #expect(provider.signInCount == 1)
    }

    // MARK: Token

    @Test func theTokenIsReadFreshSoARefreshIsVisible() async throws {
        let provider = InMemoryAuthSessionProvider(
            stored: AuthSession(userID: "user", accessToken: "expiring-token")
        )
        let service = AuthService(provider: provider)

        let before = try await service.accessToken()
        // The SDK refreshes underneath us; same user, new token.
        provider.stored = AuthSession(userID: "user", accessToken: "refreshed-token")
        let after = try await service.accessToken()

        #expect(before == "expiring-token")
        #expect(after == "refreshed-token")
    }

    @Test func aFailedSignInPropagatesAndLeavesNothingBehind() async throws {
        let provider = InMemoryAuthSessionProvider()
        provider.signInError = ProviderFailure.unavailable
        let service = AuthService(provider: provider)

        await #expect(throws: ProviderFailure.unavailable) {
            try await service.signIn()
        }

        // A dead in-flight task must not be left for the next caller to join: the
        // retry has to reach the provider again.
        provider.signInError = nil
        let session = try await service.signIn()

        #expect(!session.accessToken.isEmpty)
        #expect(provider.signInCount == 1)
    }

    // MARK: Seam

    @Test func aStubSuppliesACannedTokenWithNoNetwork() async throws {
        let service: any AuthServiceProtocol = CannedAuthService(
            session: AuthSession(userID: "canned-user", accessToken: "canned-token")
        )

        let token = try await service.accessToken()

        #expect(token == "canned-token")
    }
}
