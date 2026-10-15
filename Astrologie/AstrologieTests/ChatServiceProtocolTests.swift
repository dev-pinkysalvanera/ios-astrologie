//
//  ChatServiceProtocolTests.swift
//  AstrologieTests
//
//  Pins the service seam: `ChatError` stays comparable and presentable, and
//  `ChatServiceProtocol` is satisfiable by a plain value type so the ViewModel
//  can be driven without a network.
//

import Foundation
import Testing

@testable import Astrologie

/// Minimal conformer. Its only job here is to prove the protocol is usable as
/// written; the real client arrives with Task 2.
private struct StubChatService: ChatServiceProtocol {
    let outcome: Result<String, ChatError>

    func sendMessage(_ message: String) async throws -> String {
        try outcome.get()
    }
}

struct ChatServiceProtocolTests {

    @Test func returnsReplyThroughTheProtocol() async throws {
        let service: any ChatServiceProtocol = StubChatService(
            outcome: .success("Mercury is retrograde.")
        )

        let reply = try await service.sendMessage("What's up with Mercury?")

        #expect(reply == "Mercury is retrograde.")
    }

    @Test func propagatesChatErrorThroughTheProtocol() async {
        let service: any ChatServiceProtocol = StubChatService(
            outcome: .failure(.httpStatus(code: 429, message: "Rate limit exceeded."))
        )

        await #expect(throws: ChatError.httpStatus(code: 429, message: "Rate limit exceeded.")) {
            try await service.sendMessage("Hello")
        }
    }
}

struct ChatErrorTests {

    @Test func distinguishesCasesByPayload() {
        #expect(ChatError.network(.timedOut) != ChatError.network(.notConnectedToInternet))
        #expect(
            ChatError.httpStatus(code: 429, message: nil)
                != ChatError.httpStatus(code: 500, message: nil)
        )
        #expect(ChatError.network(.timedOut) == ChatError.network(.timedOut))
    }

    @Test func prefersTheBackendMessageWhenPresent() {
        let error = ChatError.httpStatus(code: 413, message: "Payload too large.")

        #expect(error.errorDescription == "Payload too large.")
    }

    @Test func fallsBackToAGenericMessageWithoutABody() {
        let error = ChatError.httpStatus(code: 502, message: nil)

        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.errorDescription?.contains("502") == false)
    }

    @Test func neverSurfacesDecodingDiagnostics() {
        let error = ChatError.decodingFailed(description: "keyNotFound(CodingKeys(stringValue: \"error\"))")

        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.errorDescription?.contains("keyNotFound") == false)
    }

    // MARK: - Auth-adjacent copy

    /// A sign-in that failed is not an offline device, and saying so is the point:
    /// the old wording sent the reader to the network settings when the problem was
    /// Supabase Auth.
    @Test func aFailedSignInReadsAsASignInProblem() throws {
        let error = ChatError.signInFailed(description: "AuthError.sessionMissing")

        let copy = try #require(error.errorDescription)
        #expect(copy.localizedCaseInsensitiveContains("sign"))
        #expect(!copy.localizedCaseInsensitiveContains("connection"))
        #expect(!copy.localizedCaseInsensitiveContains("network"))
    }

    /// Diagnostics stay in the log, same rule as the decoding case.
    @Test func neverSurfacesSignInDiagnostics() {
        let error = ChatError.signInFailed(description: "AuthError.sessionMissing")

        #expect(error.errorDescription?.contains("AuthError") == false)
    }

    /// The request carries a token now, so a rejection means the session stopped
    /// working — and the handler's own words for it describe the wire, not anything
    /// the person can act on.
    @Test func anUnauthorizedStatusReadsAsABrokenSessionRatherThanTheBackendsWording() throws {
        let error = ChatError.httpStatus(
            code: ChatError.unauthorizedStatusCode,
            message: "Missing authorization header"
        )

        let copy = try #require(error.errorDescription)
        #expect(copy.localizedCaseInsensitiveContains("session"))
        #expect(!copy.contains("Missing authorization header"))
        #expect(!copy.contains("401"))
    }

    /// The three failures this week's work had to separate. Reading alike is the
    /// defect; nothing else about them matters here.
    @Test func theThreeAuthAdjacentFailuresReadDifferently() {
        let signIn = ChatError.signInFailed(description: "AuthError.sessionMissing")
        let offline = ChatError.network(.notConnectedToInternet)
        let unauthorized = ChatError.httpStatus(
            code: ChatError.unauthorizedStatusCode,
            message: "Missing authorization header"
        )

        let copy = [signIn, offline, unauthorized].map(\.errorDescription)

        #expect(Set(copy).count == 3)
        #expect(copy.allSatisfy { $0?.isEmpty == false })
        #expect(offline.errorDescription == "No connection. Check your network and try again.")
    }

    // MARK: - Turn limit

    /// The one thing the banner needs to decide whether to offer a way past a
    /// dead end: this 403, and no other status, however it's spelled.
    @Test func onlyTheTurnLimitStatusIsRecognizedAsTheTurnLimit() {
        let turnLimit = ChatError.httpStatus(
            code: ChatError.turnLimitStatusCode,
            message: "Conversation limit reached. Please start a new thread."
        )
        let genericForbidden = ChatError.httpStatus(code: 403, message: nil)
        let unauthorized = ChatError.httpStatus(
            code: ChatError.unauthorizedStatusCode,
            message: "Missing authorization header"
        )
        let rateLimited = ChatError.httpStatus(code: 429, message: "Rate limit exceeded.")

        #expect(turnLimit.isTurnLimitReached)
        // Same status, no message: still the turn limit by code alone — the
        // check doesn't depend on the backend's wording surviving intact.
        #expect(genericForbidden.isTurnLimitReached)
        #expect(!unauthorized.isTurnLimitReached)
        #expect(!rateLimited.isTurnLimitReached)
        #expect(!ChatError.invalidURL.isTurnLimitReached)
        #expect(!ChatError.network(.timedOut).isTurnLimitReached)
        #expect(!ChatError.signInFailed(description: "x").isTurnLimitReached)
        #expect(!ChatError.decodingFailed(description: "x").isTurnLimitReached)
    }

    /// Unlike 401, the turn limit keeps the backend's own message: it already
    /// says what happened, and the escape hatch is the banner's button, not a line
    /// of text here.
    @Test func theTurnLimitKeepsTheBackendsMessage() throws {
        let error = ChatError.httpStatus(
            code: ChatError.turnLimitStatusCode,
            message: "Conversation limit reached. Please start a new thread."
        )

        #expect(error.errorDescription == "Conversation limit reached. Please start a new thread.")
    }
}
