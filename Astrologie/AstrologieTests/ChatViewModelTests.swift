//
//  ChatViewModelTests.swift
//  AstrologieTests
//
//  Pins the ViewModel: it starts empty, takes its service through
//  `ChatServiceProtocol` rather than a concrete type, and runs the optimistic
//  send flow — user message first, reply or error after — transitioning a single
//  `ChatState` value as it goes.
//

import Foundation
import Testing

@testable import Astrologie

@MainActor
struct ChatViewModelTests {

    @Test func startsWithEmptyState() {
        let viewModel = ChatViewModel(service: MockChatService(.echo))

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.inputText.isEmpty)
        #expect(viewModel.state == .idle)
    }

    @Test func holdsTheServiceAsAProtocolExistential() async throws {
        let service: any ChatServiceProtocol = MockChatService(.echo)
        let viewModel = ChatViewModel(service: service)

        let reply = try await viewModel.service.sendMessage("What's up with Mercury?")

        #expect(reply == "echo: What's up with Mercury?")
    }
}

// MARK: - Optimistic send flow

@MainActor
struct ChatViewModelSendTests {

    @Test func appendsTheUserMessageBeforeTheReplyResolves() async {
        let gate = MockChatService.Gate()
        let viewModel = ChatViewModel(
            service: MockChatService(.reply("Mercury is retrograde."), gate: gate)
        )
        viewModel.inputText = "What's up with Mercury?"

        let send = Task { await viewModel.send() }
        await gate.waitUntilEntered()

        // Mid-flight: the person's message is on screen, the field is clear, and
        // the reply hasn't landed yet.
        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.role == .user)
        #expect(viewModel.messages.first?.text == "What's up with Mercury?")
        #expect(viewModel.inputText.isEmpty)
        #expect(viewModel.state == .sending)

        await gate.release()
        await send.value

        #expect(viewModel.messages.count == 2)
        #expect(viewModel.messages.last?.role == .assistant)
        #expect(viewModel.messages.last?.text == "Mercury is retrograde.")
        #expect(viewModel.state == .idle)
    }

    @Test func appendsTheAssistantReplyOnSuccess() async {
        let viewModel = ChatViewModel(service: MockChatService(.echo))
        viewModel.inputText = "  What's up with Mercury?  "

        await viewModel.send()

        #expect(viewModel.messages.map(\.role) == [.user, .assistant])
        #expect(viewModel.messages.first?.text == "What's up with Mercury?")
        #expect(viewModel.messages.last?.text == "echo: What's up with Mercury?")
        #expect(viewModel.inputText.isEmpty)
        #expect(viewModel.state == .idle)
    }

    @Test func surfacesTheFailureAndKeepsTheUserMessage() async {
        let failure = ChatError.httpStatus(code: 429, message: "Rate limit exceeded.")
        let viewModel = ChatViewModel(service: MockChatService(.failure(failure)))
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        #expect(viewModel.state == .failed(failure))
        #expect(viewModel.state.error == failure)
        #expect(viewModel.state.isBusy == false)
        #expect(viewModel.messages.map(\.role) == [.user])
    }

    @Test func restoresTheComposeFieldOnFailure() async {
        let failure = ChatError.network(.timedOut)
        let viewModel = ChatViewModel(service: MockChatService(.failure(failure)))
        viewModel.inputText = "  What's up with Mercury?  "

        await viewModel.send()

        // The field was cleared optimistically, and comes back trimmed — the same
        // text that landed in the transcript — so the person doesn't have to
        // retype it to retry.
        #expect(viewModel.inputText == "What's up with Mercury?")
        #expect(viewModel.messages.map(\.text) == ["What's up with Mercury?"])
        #expect(viewModel.state == .failed(failure))
    }

    @Test func clearsThePreviousFailureOnTheNextSend() async {
        let failure = ChatError.network(.timedOut)
        let viewModel = ChatViewModel(service: MockChatService(.failure(failure), .echo))
        viewModel.inputText = "First try"

        await viewModel.send()
        #expect(viewModel.state == .failed(failure))

        viewModel.inputText = "Try again"
        await viewModel.send()

        // A retry replaces the failure outright rather than layering on top of it.
        #expect(viewModel.state == .idle)
        #expect(viewModel.state.error == nil)
    }

    @Test func allowsARetryAfterAFailure() async {
        let viewModel = ChatViewModel(service: MockChatService(.failure(.invalidURL), .echo))
        viewModel.inputText = "First try"

        await viewModel.send()

        // `.failed` is not busy, so the guard in `send()` lets the next one through.
        #expect(viewModel.state.isBusy == false)

        viewModel.inputText = "Try again"
        await viewModel.send()

        #expect(viewModel.messages.map(\.text) == ["First try", "Try again", "echo: Try again"])
    }

    @Test func ignoresABlankComposeField() async {
        let viewModel = ChatViewModel(service: MockChatService(.echo))
        viewModel.inputText = "   \n "

        await viewModel.send()

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.inputText == "   \n ")
        #expect(viewModel.state == .idle)
    }

    @Test func ignoresASecondSendWhileAReplyIsOutstanding() async {
        let gate = MockChatService.Gate()
        let viewModel = ChatViewModel(
            service: MockChatService(.reply("Reply"), gate: gate)
        )
        viewModel.inputText = "First"

        let send = Task { await viewModel.send() }
        await gate.waitUntilEntered()

        viewModel.inputText = "Second"
        await viewModel.send()

        #expect(viewModel.messages.map(\.text) == ["First"])
        #expect(viewModel.inputText == "Second")

        await gate.release()
        await send.value

        #expect(viewModel.messages.map(\.text) == ["First", "Reply"])
    }

    @Test func normalizesANonChatErrorFailure() async {
        struct ThrowsURLError: ChatServiceProtocol {
            func sendMessage(_ message: String) async throws -> String {
                throw URLError(.notConnectedToInternet)
            }
        }

        let viewModel = ChatViewModel(service: ThrowsURLError())
        viewModel.inputText = "Hello"

        await viewModel.send()

        #expect(viewModel.state == .failed(.network(.notConnectedToInternet)))
    }
}

// MARK: - Turn limit escape hatch

@MainActor
struct ChatViewModelTurnLimitTests {

    private static let turnLimit = ChatError.httpStatus(
        code: ChatError.turnLimitStatusCode,
        message: "Conversation limit reached. Please start a new thread."
    )

    /// The escape hatch itself: after hitting the limit, starting a new
    /// conversation clears the failure so the compose bar is live again.
    @Test func startingANewConversationClearsTheFailure() async {
        let viewModel = ChatViewModel(
            service: MockChatService(.failure(Self.turnLimit)),
            resetSession: {}
        )
        viewModel.inputText = "What's up with Mercury?"
        await viewModel.send()
        #expect(viewModel.state == .failed(Self.turnLimit))

        viewModel.startNewConversation()

        #expect(viewModel.state == .idle)
        #expect(viewModel.state.isBusy == false)
    }

    /// The point of the reset: the *id* changes, not just the screen's state.
    @Test func startingANewConversationCallsTheInjectedReset() async {
        var resetCallCount = 0
        let viewModel = ChatViewModel(
            service: MockChatService(.failure(Self.turnLimit)),
            resetSession: { resetCallCount += 1 }
        )
        viewModel.inputText = "What's up with Mercury?"
        await viewModel.send()

        viewModel.startNewConversation()

        #expect(resetCallCount == 1)
    }

    /// A new conversation starts with an empty transcript (Week 10 Task 4). The
    /// question the failed send put back stays in the field, ready to resend.
    @Test func startingANewConversationClearsTheTranscript() async {
        let viewModel = ChatViewModel(
            service: MockChatService(.failure(Self.turnLimit)),
            resetSession: {}
        )
        viewModel.inputText = "What's up with Mercury?"
        await viewModel.send()
        #expect(!viewModel.messages.isEmpty)

        viewModel.startNewConversation()

        #expect(viewModel.messages.isEmpty)
        #expect(viewModel.inputText == "What's up with Mercury?")
    }

    /// Mid-reply, there's a transcript still being written to, so the reset
    /// waits rather than clearing it out from under the stream.
    @Test func startingANewConversationIsIgnoredWhileAReplyIsArriving() async {
        let gate = MockChatService.Gate()
        var resetCallCount = 0
        let viewModel = ChatViewModel(
            service: MockChatService(.reply("Reply"), gate: gate),
            resetSession: { resetCallCount += 1 }
        )
        viewModel.inputText = "Question"
        let send = Task { await viewModel.send() }
        await gate.waitUntilEntered()

        viewModel.startNewConversation()

        #expect(resetCallCount == 0)
        #expect(viewModel.messages.map(\.text) == ["Question"])

        await gate.release()
        await send.value
    }

    /// After the reset, a send goes through again — the whole point of the
    /// escape hatch is that the dead end doesn't stay dead.
    @Test func aSendAfterStartingANewConversationSucceeds() async {
        let service = MockChatService(.failure(Self.turnLimit), .echo)
        let viewModel = ChatViewModel(service: service, resetSession: {})
        viewModel.inputText = "What's up with Mercury?"
        await viewModel.send()
        #expect(viewModel.state.error == Self.turnLimit)

        viewModel.startNewConversation()
        viewModel.inputText = "What's up with Mercury?"
        await viewModel.send()

        #expect(viewModel.state == .idle)
        #expect(viewModel.messages.last?.role == .assistant)
    }
}


// MARK: - Rate limit

/// The backend's per-session 429 (Week 10 Task 2). It's an ordinary failure to
/// the ViewModel, so these pin the parts a person meets: the question comes back
/// to the field, and waiting it out and sending again works.
@MainActor
struct ChatViewModelRateLimitTests {

    @Test func aRateLimitRestoresTheQuestionAndTheNextSendGoesThrough() async {
        let viewModel = ChatViewModel(service: MockChatService(.rateLimited(), .echo))
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        #expect(viewModel.state == .failed(.httpStatus(code: 429, message: MockChatService.rateLimitMessage)))
        #expect(viewModel.inputText == "What's up with Mercury?")
        #expect(viewModel.messages.map(\.role) == [.user])

        await viewModel.send()

        #expect(viewModel.state == .idle)
        #expect(viewModel.inputText.isEmpty)
        #expect(viewModel.messages.last?.text == "echo: What's up with Mercury?")
    }

    /// Not the turn limit: a 429 clears with time, so it mustn't offer "Start
    /// new conversation" or reset the session.
    @Test func aRateLimitIsNotTheTurnLimit() async {
        let viewModel = ChatViewModel(service: MockChatService(.rateLimited()), resetSession: {
            Issue.record("A 429 must not reset the session.")
        })
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        #expect(viewModel.state.error?.isTurnLimitReached == false)
    }
}
