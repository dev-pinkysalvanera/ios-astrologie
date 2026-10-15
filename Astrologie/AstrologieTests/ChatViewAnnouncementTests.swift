//
//  ChatViewAnnouncementTests.swift
//  AstrologieTests
//
//  What VoiceOver is told when the chat state changes (Week 9 Task 5): the typing
//  indicator and the error banner are announced as they appear, since neither has
//  focus when it does. Checked as a pure rule; the simulator can't run VoiceOver.
//

import Foundation
import Testing

@testable import Astrologie

@MainActor
struct ChatViewAnnouncementTests {

    @Test(arguments: [ChatState.idle, .failed(.network(.timedOut))])
    func startingASendAnnouncesTheTypingIndicator(from old: ChatState) {
        #expect(
            ChatView.accessibilityAnnouncement(from: old, to: .sending)
                == TypingIndicator.accessibilityLabel
        )
    }

    @Test(arguments: [ChatState.sending, .streaming])
    func aFailureAnnouncesTheBannerText(from old: ChatState) {
        let error = ChatError.network(.notConnectedToInternet)

        #expect(
            ChatView.accessibilityAnnouncement(from: old, to: .failed(error))
                == ChatView.accessibilityLabel(forError: try! #require(error.errorDescription))
        )
    }

    @Test func aCancelledSendIsNotAnnounced() {
        #expect(
            ChatView.accessibilityAnnouncement(from: .sending, to: .failed(.network(.cancelled)))
                == nil
        )
    }

    /// The reply's own bubble is there to read; announcing its arrival or every
    /// chunk would talk over it.
    @Test(arguments: [
        (ChatState.sending, ChatState.streaming),
        (.streaming, .idle),
        (.sending, .idle),
        (.failed(.network(.timedOut)), .idle),
        (.idle, .idle),
        (.sending, .sending),
    ])
    func otherTransitionsAreSilent(old: ChatState, new: ChatState) {
        #expect(ChatView.accessibilityAnnouncement(from: old, to: new) == nil)
    }
}
