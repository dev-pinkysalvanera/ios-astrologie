//
//  ChatViewErrorTests.swift
//  AstrologieTests
//
//  Covers the part of the failure display that can be checked without rendering:
//  whether there is an error to show, what it says, and when it goes away. The
//  banner is a pure function of `ChatState`, so driving a real `send()` through a
//  throwing stub is enough to pin all three — no network, and no reaching past
//  `state`'s private setter.
//

import Foundation
import Testing

@testable import Astrologie

/// A rejected token. The request does carry one now, so this means the session
/// stopped working rather than the endpoint never having been given a chance.
private let unauthorized = ChatError.httpStatus(
    code: ChatError.unauthorizedStatusCode,
    message: "Missing authorization header"
)

/// A backend failure whose own wording is worth showing: it is already written for
/// the person reading it, and only the auth-adjacent cases override it.
private let rateLimited = ChatError.httpStatus(code: 429, message: "Rate limit exceeded.")

@MainActor
struct ChatViewErrorTests {

    // MARK: - When there's nothing wrong

    /// A fresh screen has no failure to report, so the banner isn't there at all —
    /// an always-present slot would leave a gap above the compose bar.
    @Test func aRestingScreenShowsNoError() {
        let viewModel = ChatViewModel(service: MockChatService(.failure(unauthorized)))

        #expect(viewModel.state == .idle)
        #expect(ChatView(viewModel: viewModel).errorMessage == nil)
    }

    /// Every state but ``ChatState/failed(_:)`` is a state with nothing to show,
    /// including the two in-flight ones — a send in progress is not a failure.
    @Test func onlyAFailedStateHasSomethingToShow() {
        #expect(ChatState.idle.error == nil)
        #expect(ChatState.sending.error == nil)
        #expect(ChatState.streaming.error == nil)
        #expect(ChatState.failed(unauthorized).error == unauthorized)
    }

    // MARK: - After a failure

    /// The defect this covers: the send failed, the person's message stayed put,
    /// and nothing said why.
    @Test func aFailedSendShowsTheError() async {
        let viewModel = ChatViewModel(service: MockChatService(.failure(unauthorized)))
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        #expect(viewModel.state == .failed(unauthorized))
        #expect(view.errorMessage != nil)
        // Nothing is rolled back: the question is still there, under the reason.
        #expect(viewModel.messages.map(\.role) == [.user])
    }

    /// The wording comes from ``ChatError/errorDescription`` rather than from the
    /// view, so the client-safe copy lives in one place. For an HTTP failure that
    /// means the backend's own message, which is already written for this audience.
    @Test func theMessageComesFromTheErrorsDescription() async {
        let viewModel = ChatViewModel(service: MockChatService(.failure(rateLimited)))
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        #expect(view.errorMessage == rateLimited.errorDescription)
        #expect(view.errorMessage == "Rate limit exceeded.")
    }

    /// The exception to the rule above, and the reason for it: a 401 arrives after
    /// the request carried a token, so "Missing authorization header" describes the
    /// wire and leaves the reader with nothing to do.
    @Test func aRejectedTokenShowsTheSessionCopyRatherThanTheBackendsWording() async throws {
        let viewModel = ChatViewModel(service: MockChatService(.failure(unauthorized)))
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        let message = try #require(view.errorMessage)
        #expect(message.localizedCaseInsensitiveContains("session"))
        #expect(!message.contains("Missing authorization header"))
    }

    /// The three failures Task 6 had to separate, read off the banner the way the
    /// person sees them: sign-in refused, the device offline, the token rejected.
    /// Two of them reading alike is the defect.
    @Test func theThreeAuthAdjacentFailuresReadDifferentlyInTheBanner() async throws {
        let errors: [ChatError] = [
            .signInFailed(description: "AuthError.sessionMissing"),
            .network(.notConnectedToInternet),
            unauthorized,
        ]

        var copy: [String] = []
        for error in errors {
            let viewModel = ChatViewModel(service: MockChatService(.failure(error)))
            let view = ChatView(viewModel: viewModel)
            viewModel.inputText = "What's up with Mercury?"

            await viewModel.send()

            copy.append(try #require(view.errorMessage))
        }

        #expect(Set(copy).count == 3, "these three read alike: \(copy)")
        #expect(copy[0].localizedCaseInsensitiveContains("sign"))
        // Only the genuine connectivity failure gets the connectivity copy.
        #expect(copy[1] == "No connection. Check your network and try again.")
        #expect(!copy[0].localizedCaseInsensitiveContains("connection"))
        #expect(!copy[2].localizedCaseInsensitiveContains("connection"))
    }

    /// Same rule whatever the failure is — including the cases that deliberately
    /// keep their diagnostics to themselves.
    @Test func everyFailureReportsItsOwnDescription() async {
        let errors: [ChatError] = [
            unauthorized,
            .httpStatus(code: 500, message: nil),
            .network(.notConnectedToInternet),
            .signInFailed(description: "AuthError.sessionMissing"),
            .decodingFailed(description: "keyNotFound(\"reply\")"),
            .invalidURL,
        ]

        for error in errors {
            let viewModel = ChatViewModel(service: MockChatService(.failure(error)))
            let view = ChatView(viewModel: viewModel)
            viewModel.inputText = "What's up with Mercury?"

            await viewModel.send()

            #expect(view.errorMessage == error.errorDescription, "\(error) should show its own description")
            // Never empty: a banner with no words is worse than no banner.
            #expect(view.errorMessage?.isEmpty == false)
        }
    }

    /// VoiceOver gets the word "Error" first, because the tint and the glyph are
    /// the only things that carry that reading visually and neither is spoken.
    @Test func theErrorIsAnnouncedAsAnError() {
        let label = ChatView.accessibilityLabel(forError: "Missing authorization header")

        #expect(label == "Error: Missing authorization header")
        #expect(label.hasPrefix(ChatView.errorAccessibilityPrefix))
    }

    // MARK: - After a retry

    // MARK: - Turn limit escape hatch

    /// The 403 that means the conversation hit its limit is the one failure the
    /// banner offers a way past, rather than leaving the compose bar as the only
    /// retry.
    @Test func theTurnLimitBannerOffersAWayForward() async {
        let turnLimit = ChatError.httpStatus(
            code: ChatError.turnLimitStatusCode,
            message: "Conversation limit reached. Please start a new thread."
        )
        let viewModel = ChatViewModel(service: MockChatService(.failure(turnLimit)), resetSession: {})
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        #expect(view.errorMessage == "Conversation limit reached. Please start a new thread.")
        #expect(view.isTurnLimitReached)
    }

    /// Every other failure — including a 403 that isn't specifically the turn
    /// limit — leaves the compose bar as the only way to try again, same as
    /// before this task.
    @Test func onlyTheTurnLimitOffersTheEscapeHatch() async {
        let errors: [ChatError] = [
            unauthorized,
            rateLimited,
            .network(.notConnectedToInternet),
        ]

        for error in errors {
            let viewModel = ChatViewModel(service: MockChatService(.failure(error)), resetSession: {})
            let view = ChatView(viewModel: viewModel)
            viewModel.inputText = "What's up with Mercury?"

            await viewModel.send()

            #expect(!view.isTurnLimitReached, "\(error) should not offer the escape hatch")
        }
    }

    /// Invoking the escape hatch is what actually gets the person unstuck: the
    /// failure clears and a send can go through again.
    @Test func invokingTheEscapeHatchRecoversTheScreen() async {
        let turnLimit = ChatError.httpStatus(
            code: ChatError.turnLimitStatusCode,
            message: "Conversation limit reached. Please start a new thread."
        )
        var resetCallCount = 0
        let viewModel = ChatViewModel(
            service: MockChatService(.failure(turnLimit)),
            resetSession: { resetCallCount += 1 }
        )
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = "What's up with Mercury?"
        await viewModel.send()
        #expect(view.isTurnLimitReached)

        viewModel.startNewConversation()

        #expect(resetCallCount == 1)
        #expect(view.errorMessage == nil)
        #expect(!view.isTurnLimitReached)
    }

    /// A successful send leaves no residue: ``ChatViewModel/send()`` enters
    /// `.sending`, which replaces the previous `.failed`, so the banner goes with
    /// it and the last attempt's error can't sit under a reply that worked.
    @Test func aSuccessfulRetryClearsTheError() async {
        let service = MockChatService(.failure(unauthorized), .reply("Mercury is retrograde."))
        let viewModel = ChatViewModel(service: service)
        let view = ChatView(viewModel: viewModel)

        viewModel.inputText = "What's up with Mercury?"
        await viewModel.send()
        #expect(view.errorMessage == unauthorized.errorDescription)

        viewModel.inputText = "What's up with Mercury?"
        await viewModel.send()

        #expect(viewModel.state == .idle)
        #expect(view.errorMessage == nil)
        #expect(viewModel.messages.map(\.role) == [.user, .user, .assistant])
        #expect(viewModel.messages.last?.text == "Mercury is retrograde.")
    }
}

// MARK: - Rate limit wording

@MainActor
struct ChatViewRateLimitMessageTests {

    /// The backend's own wording for a 429, as the handler sends it.
    @Test func aRateLimitShowsTheBackendsWording() async {
        let viewModel = ChatViewModel(service: MockChatService(.rateLimited()))
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        #expect(view.errorMessage == MockChatService.rateLimitMessage)
    }

    /// A 429 whose body couldn't be read still gets friendly copy, never a
    /// status code or an empty banner.
    @Test func aRateLimitWithNoMessageFallsBackToFriendlyCopy() async {
        let viewModel = ChatViewModel(service: MockChatService(.rateLimited(message: nil)))
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        #expect(view.errorMessage == "The astrologer couldn't answer that. Please try again.")
        #expect(view.errorMessage?.contains("429") == false)
    }
}
