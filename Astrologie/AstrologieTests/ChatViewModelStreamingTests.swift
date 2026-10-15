//
//  ChatViewModelStreamingTests.swift
//  AstrologieTests
//
//  Pins the streamed side of the ViewModel: the reply grows into one assistant
//  row as pieces land instead of appearing whole, `state` walks
//  `.sending` → `.streaming` → `.idle`, and a failure part-way through keeps what
//  already arrived. The service is stubbed and the *test* owns the stream's
//  continuation, so "incrementally" is an assertion about the transcript between
//  two pieces rather than a claim about timing.
//

import Foundation
import Testing

@testable import Astrologie

// MARK: - Helpers

/// Lets the ViewModel's in-flight send run until `condition` holds.
///
/// The send task and the test share the main actor, so yielding is what gives the
/// ViewModel a turn to consume whatever was just yielded into its stream. Capped
/// rather than open-ended: a condition that never comes true is a failure, not a
/// hang.
@MainActor
private func settle(
    untilTrue condition: () -> Bool,
    _ description: @autoclosure () -> String
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for \(description()).")
}

@MainActor
private extension ChatViewModel {
    /// The assistant row being filled, if a reply has started.
    var reply: ChatMessage? {
        messages.last?.role == .assistant ? messages.last : nil
    }
}

// MARK: - Incremental delivery

@MainActor
struct ChatViewModelStreamingTests {

    @Test(.timeLimit(.minutes(1)))
    func growsOneAssistantRowAsPiecesArrive() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: String.self,
            throwing: (any Error).self
        )
        let viewModel = ChatViewModel(service: MockChatService(.handed(stream)))
        viewModel.inputText = "What's up with Mercury?"

        let send = Task { await viewModel.send() }

        continuation.yield("Mercury")
        await settle(untilTrue: { viewModel.reply != nil }, "the first piece")

        // First piece: a row exists, it holds exactly that piece, and the state
        // says the reply is arriving.
        #expect(viewModel.messages.count == 2)
        #expect(viewModel.reply?.text == "Mercury")
        #expect(viewModel.state == .streaming)
        let replyID = viewModel.reply?.id

        continuation.yield(" is")
        await settle(untilTrue: { viewModel.reply?.text == "Mercury is" }, "the second piece")

        // Second piece: appended in place. Same row, same id — nothing for SwiftUI
        // to tear down.
        #expect(viewModel.messages.count == 2)
        #expect(viewModel.reply?.id == replyID)
        #expect(viewModel.state == .streaming)

        continuation.yield(" retrograde.")
        continuation.finish()
        await send.value

        #expect(viewModel.messages.map(\.role) == [.user, .assistant])
        #expect(viewModel.reply?.text == "Mercury is retrograde.")
        #expect(viewModel.reply?.id == replyID)
        #expect(viewModel.state == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func staysSendingUntilTheFirstPieceArrives() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: String.self,
            throwing: (any Error).self
        )
        let viewModel = ChatViewModel(service: MockChatService(.handed(stream)))
        viewModel.inputText = "What's up with Mercury?"

        let send = Task { await viewModel.send() }
        await settle(untilTrue: { viewModel.state == .sending }, "the send to start")

        // Nothing of the reply exists yet, so there is no empty bubble waiting for
        // it either.
        #expect(viewModel.messages.map(\.role) == [.user])
        #expect(viewModel.state == .sending)
        #expect(viewModel.state.isBusy)

        continuation.yield("Mercury")
        continuation.finish()
        await send.value

        #expect(viewModel.state == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func ignoresASecondSendWhileTheReplyIsStillStreaming() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: String.self,
            throwing: (any Error).self
        )
        let viewModel = ChatViewModel(service: MockChatService(.handed(stream)))
        viewModel.inputText = "First"

        let send = Task { await viewModel.send() }
        continuation.yield("Partial")
        await settle(untilTrue: { viewModel.state == .streaming }, "the reply to start")

        viewModel.inputText = "Second"
        await viewModel.send()

        // `.streaming` is busy, so the guard in `send()` turns this into a no-op.
        #expect(viewModel.messages.map(\.text) == ["First", "Partial"])
        #expect(viewModel.inputText == "Second")

        continuation.finish()
        await send.value
    }

    @Test func sendsTheTrimmedComposeFieldThroughTheStream() async {
        let service = MockChatService(.reply(["Mercury", " is retrograde."]))
        let viewModel = ChatViewModel(service: service)
        viewModel.inputText = "  What's up with Mercury?  "

        await viewModel.send()

        let recorded = await service.log.messages
        #expect(recorded == ["What's up with Mercury?"])
        #expect(viewModel.messages.map(\.text) == ["What's up with Mercury?", "Mercury is retrograde."])
        #expect(viewModel.state == .idle)
    }
}

// MARK: - Failures

@MainActor
struct ChatViewModelStreamingFailureTests {

    @Test(.timeLimit(.minutes(1)))
    func keepsWhatArrivedWhenTheStreamFailsPartWayThrough() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: String.self,
            throwing: (any Error).self
        )
        let viewModel = ChatViewModel(service: MockChatService(.handed(stream)))
        viewModel.inputText = "What's up with Mercury?"

        let send = Task { await viewModel.send() }
        continuation.yield("Mercury is")
        await settle(untilTrue: { viewModel.state == .streaming }, "the reply to start")

        continuation.finish(throwing: ChatError.network(.networkConnectionLost))
        await send.value

        // The truncated reply stays on screen under the error, the same way the
        // person's message is never rolled back.
        #expect(viewModel.state == .failed(.network(.networkConnectionLost)))
        #expect(viewModel.state.isBusy == false)
        #expect(viewModel.messages.map(\.role) == [.user, .assistant])
        #expect(viewModel.messages.last?.text == "Mercury is")
    }

    @Test(.timeLimit(.minutes(1)))
    func addsNoAssistantRowWhenTheStreamFailsBeforeAnyPiece() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: String.self,
            throwing: (any Error).self
        )
        let viewModel = ChatViewModel(service: MockChatService(.handed(stream)))
        viewModel.inputText = "What's up with Mercury?"

        let send = Task { await viewModel.send() }
        await settle(untilTrue: { viewModel.state == .sending }, "the send to start")

        let failure = ChatError.httpStatus(code: 401, message: "Missing authorization header.")
        continuation.finish(throwing: failure)
        await send.value

        #expect(viewModel.state == .failed(failure))
        #expect(viewModel.messages.map(\.role) == [.user])
    }

    @Test(.timeLimit(.minutes(1)))
    func restoresTheComposeFieldWhenTheStreamFails() async {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: String.self,
            throwing: (any Error).self
        )
        let viewModel = ChatViewModel(service: MockChatService(.handed(stream)))
        viewModel.inputText = "  What's up with Mercury?  "

        let send = Task { await viewModel.send() }
        await settle(untilTrue: { viewModel.state == .sending }, "the send to start")

        continuation.finish(throwing: ChatError.network(.networkConnectionLost))
        await send.value

        // The field comes back trimmed, matching what's already in the
        // transcript, so retrying doesn't mean retyping.
        #expect(viewModel.inputText == "What's up with Mercury?")
        #expect(viewModel.state == .failed(.network(.networkConnectionLost)))
    }
}
