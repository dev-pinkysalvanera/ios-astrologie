//
//  ChatInputBarTests.swift
//  AstrologieTests
//
//  Covers the two parts of the compose bar that can be checked without rendering:
//  when the send button is live, and what the button is wired to. The first is a
//  rule about text and busyness; the second is `ChatView` handing the bar a
//  binding into `inputText` and the real `send()`.
//

import SwiftUI
import Testing

@testable import Astrologie

// MARK: - When send is live

@MainActor
struct ChatInputBarSendEnablementTests {

    @Test func typedTextEnablesSending() {
        #expect(ChatInputBar.canSend(text: "What's up with Mercury?", isBusy: false))
    }

    @Test func anEmptyFieldDisablesSending() {
        #expect(ChatInputBar.canSend(text: "", isBusy: false) == false)
    }

    /// Trimmed the same way ``ChatViewModel/send()`` trims, so the button can't
    /// look live for something the ViewModel would refuse.
    @Test func aFieldOfOnlyWhitespaceDisablesSending() {
        #expect(ChatInputBar.canSend(text: "   \n\t ", isBusy: false) == false)
        #expect(ChatInputBar.canSend(text: "\n", isBusy: false) == false)
    }

    /// Whitespace around real text is still real text — it's trimmed on send, not
    /// treated as empty.
    @Test func surroundingWhitespaceDoesNotDisableSending() {
        #expect(ChatInputBar.canSend(text: "  What's up with Mercury?  \n", isBusy: false))
    }

    @Test func aTurnInFlightDisablesSending() {
        #expect(ChatInputBar.canSend(text: "What's up with Mercury?", isBusy: true) == false)
    }

    /// Busyness is taken from ``ChatState/isBusy`` rather than decided here, so the
    /// button follows the enum: the two in-flight cases dim it, the two resting
    /// cases don't. A retry after a failure has to stay possible.
    @Test func sendingFollowsTheChatState() {
        let states: [ChatState] = [.idle, .sending, .streaming, .failed(.invalidURL)]

        for state in states {
            #expect(
                ChatInputBar.canSend(text: "What's up with Mercury?", isBusy: state.isBusy) == !state.isBusy,
                "\(state) should \(state.isBusy ? "disable" : "enable") sending"
            )
        }
    }
}

// MARK: - What the bar is wired to

@MainActor
struct ChatViewComposeBarTests {

    @Test func theFieldReadsTheViewModelsInputText() {
        let viewModel = ChatViewModel(service: MockChatService(.echo))
        viewModel.inputText = "What's up with Mercury?"

        #expect(ChatView(viewModel: viewModel).inputBar.text == "What's up with Mercury?")
    }

    @Test func typingWritesBackToTheViewModel() {
        let viewModel = ChatViewModel(service: MockChatService(.echo))
        var bar = ChatView(viewModel: viewModel).inputBar

        bar.text = "What's up with Mercury?"

        #expect(viewModel.inputText == "What's up with Mercury?")
    }

    /// The whole point of the task: text typed into the bar leaves through the
    /// ViewModel's real send, so the transcript ends up with the turn in it.
    @Test func theSendActionRunsTheViewModelsSend() async {
        let viewModel = ChatViewModel(service: MockChatService(.echo))
        var bar = ChatView(viewModel: viewModel).inputBar
        bar.text = "What's up with Mercury?"

        await bar.send()

        #expect(viewModel.messages.map(\.role) == [.user, .assistant])
        #expect(viewModel.messages.first?.text == "What's up with Mercury?")
        #expect(viewModel.messages.last?.text == "echo: What's up with Mercury?")
        // Cleared by the send, which is what returns the button to its dim state.
        #expect(viewModel.inputText.isEmpty)
        #expect(ChatInputBar.canSend(text: viewModel.inputText, isBusy: viewModel.state.isBusy) == false)
    }

    @Test func theBarStartsWithSendingDisabled() {
        let viewModel = ChatViewModel(service: MockChatService(.echo))
        let bar = ChatView(viewModel: viewModel).inputBar

        #expect(bar.isBusy == false)
        #expect(ChatInputBar.canSend(text: bar.text, isBusy: bar.isBusy) == false)
    }

    /// Mid-send the bar has text-worthy conditions everywhere except busyness, so
    /// this is the case that proves the flag is actually plumbed through.
    @Test func theBarReportsBusyWhileAReplyIsOutstanding() async {
        let gate = MockChatService.Gate()
        let viewModel = ChatViewModel(
            service: MockChatService(.reply("Mercury is retrograde."), gate: gate)
        )
        let view = ChatView(viewModel: viewModel)
        viewModel.inputText = "What's up with Mercury?"

        let send = Task { await view.inputBar.send() }
        await gate.waitUntilEntered()

        #expect(viewModel.state.isBusy)
        #expect(view.inputBar.isBusy)

        // Typing the next question mid-reply is fine; sending it is not.
        viewModel.inputText = "And Venus?"
        #expect(ChatInputBar.canSend(text: view.inputBar.text, isBusy: view.inputBar.isBusy) == false)

        await gate.release()
        await send.value

        #expect(view.inputBar.isBusy == false)
    }
}
