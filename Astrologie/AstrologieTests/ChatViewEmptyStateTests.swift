//
//  ChatViewEmptyStateTests.swift
//  AstrologieTests
//
//  The empty state is an invitation for a transcript with nothing in it. It must
//  go the moment a turn starts, so it never shares the screen with the person's
//  own message or the typing indicator.
//

import Testing

@testable import Astrologie

@MainActor
struct ChatViewEmptyStateTests {

    @Test func aFreshTranscriptShowsTheEmptyState() {
        let view = ChatView(viewModel: ChatViewModel(service: MockChatService(.echo)))

        #expect(view.showsEmptyState)
    }

    @Test func anyMessageHidesTheEmptyState() {
        let viewModel = ChatViewModel(service: MockChatService(.echo))
        viewModel.messages = [.user("What's up with Mercury?")]

        #expect(ChatView(viewModel: viewModel).showsEmptyState == false)
    }

    /// After a completed turn the transcript holds both sides, and the empty
    /// state stays gone.
    @Test func aCompletedTurnKeepsTheEmptyStateHidden() async {
        let viewModel = ChatViewModel(service: MockChatService(.echo))
        viewModel.inputText = "What's up with Mercury?"

        await viewModel.send()

        #expect(ChatView(viewModel: viewModel).showsEmptyState == false)
    }
}
