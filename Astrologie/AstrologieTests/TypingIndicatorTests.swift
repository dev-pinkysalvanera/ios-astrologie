//
//  TypingIndicatorTests.swift
//  AstrologieTests
//
//  Pins when the typing indicator shows: only in `.sending`, the gap before the
//  first piece of a reply. A real reply can land in ~34 ms, far too fast to
//  confirm by eye, so these drive a real `send()` through a mock stream that
//  waits a deliberate, wall-clock delay before its first piece — long enough to
//  look at the screen state mid-wait, then again once the reply starts.
//

import Foundation
import Testing

@testable import Astrologie

// MARK: - Helpers

/// Polls `condition` on the main actor until it holds or `timeout` passes.
///
/// Wall-clock rather than a count of yields, because the mock's delay is
/// wall-clock too.
@MainActor
private func waitUntil(
    timeout: Duration = .seconds(5),
    _ description: @autoclosure () -> String,
    _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for \(description()).")
}

private let question = "Is Saturn returning?"

// MARK: - Derived flag

struct ChatStateTypingIndicatorTests {

    /// Only the wait before the first piece shows it — not the reply arriving,
    /// not a failure, not rest.
    @Test func onlySendingShowsTheIndicator() {
        #expect(ChatState.sending.showsTypingIndicator)
        #expect(!ChatState.idle.showsTypingIndicator)
        #expect(!ChatState.streaming.showsTypingIndicator)
        #expect(!ChatState.failed(.network(.timedOut)).showsTypingIndicator)
    }
}

// MARK: - Against a delayed stream

@MainActor
struct TypingIndicatorDelayedStreamTests {

    /// The done-condition: visible before the first token, gone when it lands,
    /// and still gone while the rest of the reply streams in.
    @Test(.timeLimit(.minutes(1)))
    func showsBeforeTheFirstPieceAndHidesWhenItArrives() async {
        let service = MockChatService(
            .reply(["Saturn", " returns", " slowly."]),
            firstPieceDelay: .milliseconds(600),
            betweenPieces: .milliseconds(300)
        )
        let viewModel = ChatViewModel(service: service)
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = question

        #expect(!view.showsTypingIndicator)

        let send = Task { await viewModel.send() }
        await waitUntil("the send to start") { viewModel.state == .sending }

        // During the delay: indicator up, no assistant bubble yet.
        #expect(view.showsTypingIndicator)
        #expect(viewModel.messages.map(\.role) == [.user])

        // Still mid-delay a moment later — it holds for the whole wait, not a
        // single frame.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(view.showsTypingIndicator)
        #expect(viewModel.messages.map(\.role) == [.user])

        // First piece lands: the growing bubble takes over.
        await waitUntil("the first piece") { viewModel.messages.last?.role == .assistant }
        #expect(viewModel.state == .streaming)
        #expect(viewModel.messages.last?.text == "Saturn")
        #expect(!view.showsTypingIndicator)

        // Between later pieces, it doesn't come back.
        await waitUntil("the second piece") { viewModel.messages.last?.text == "Saturn returns" }
        #expect(!view.showsTypingIndicator)

        await send.value
        #expect(viewModel.state == .idle)
        #expect(viewModel.messages.last?.text == "Saturn returns slowly.")
        #expect(!view.showsTypingIndicator)
    }

    /// A failure before any piece: the indicator goes and the error banner comes
    /// — never both at once.
    @Test(.timeLimit(.minutes(1)))
    func hidesWhenTheSendFails() async {
        let failure = ChatError.network(.timedOut)
        let service = MockChatService(.failure(failure), firstPieceDelay: .milliseconds(400))
        let viewModel = ChatViewModel(service: service)
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = question

        let send = Task { await viewModel.send() }
        await waitUntil("the send to start") { viewModel.state == .sending }
        #expect(view.showsTypingIndicator)
        #expect(view.errorMessage == nil)

        await send.value

        #expect(viewModel.state == .failed(failure))
        #expect(!view.showsTypingIndicator)
        #expect(view.errorMessage != nil)
    }

    /// A failure after the reply started: hidden already, and stays hidden
    /// beside the banner.
    @Test(.timeLimit(.minutes(1)))
    func staysHiddenWhenTheStreamFailsPartWayThrough() async {
        let failure = ChatError.network(.networkConnectionLost)
        let service = MockChatService(
            .partial(["Saturn"], then: failure),
            firstPieceDelay: .milliseconds(300)
        )
        let viewModel = ChatViewModel(service: service)
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = question

        let send = Task { await viewModel.send() }
        await waitUntil("the send to start") { viewModel.state == .sending }
        #expect(view.showsTypingIndicator)

        await send.value

        #expect(viewModel.state == .failed(failure))
        #expect(!view.showsTypingIndicator)
    }

    /// Cancelling the send mid-wait takes the indicator with it rather than
    /// leaving it spinning over a request that no longer exists.
    @Test(.timeLimit(.minutes(1)))
    func hidesWhenTheSendIsCancelled() async {
        let service = MockChatService(.reply("Never"), firstPieceDelay: .seconds(30))
        let viewModel = ChatViewModel(service: service)
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = question

        let send = Task { await viewModel.send() }
        await waitUntil("the send to start") { viewModel.state == .sending }
        #expect(view.showsTypingIndicator)

        send.cancel()
        await send.value

        #expect(viewModel.state != .sending)
        #expect(!view.showsTypingIndicator)
        #expect(viewModel.messages.map(\.role) == [.user])
    }
}

// MARK: - Accessibility

struct TypingIndicatorAccessibilityTests {

    /// Announced in words, not left as a silent animation.
    @Test func hasASpokenLabel() {
        #expect(TypingIndicator.accessibilityLabel == "Astrologer is typing")
    }
}
