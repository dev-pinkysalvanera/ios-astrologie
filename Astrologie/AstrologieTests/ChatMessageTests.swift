//
//  ChatMessageTests.swift
//  AstrologieTests
//
//  Covers the view-layer model's identity and equality behavior — the parts
//  SwiftUI relies on when rendering the transcript.
//

import Foundation
import Testing

@testable import Astrologie

struct ChatMessageTests {

    @Test func factoriesSetTheRole() {
        #expect(ChatMessage.user("hi").role == .user)
        #expect(ChatMessage.assistant("hello").role == .assistant)
    }

    @Test func assistantReplyStartsEmptyByDefault() {
        #expect(ChatMessage.assistant().text.isEmpty)
    }

    @Test func eachMessageGetsItsOwnIdentity() {
        let first = ChatMessage.user("same text")
        let second = ChatMessage.user("same text")

        #expect(first.id != second.id)
        #expect(first != second)
    }

    @Test func identitySurvivesStreamingAppend() {
        var message = ChatMessage.assistant()
        let id = message.id

        message.text += "Mercury"
        message.text += " is retrograde"

        #expect(message.id == id)
        #expect(message.text == "Mercury is retrograde")
    }

    @Test func equalWhenEveryFieldMatches() {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let left = ChatMessage(id: id, role: .user, text: "What's my chart?", timestamp: timestamp)
        let right = ChatMessage(id: id, role: .user, text: "What's my chart?", timestamp: timestamp)

        #expect(left == right)
    }

    @Test func differsWhenOnlyTextChanges() {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let original = ChatMessage(id: id, role: .assistant, text: "Mercury", timestamp: timestamp)
        var appended = original
        appended.text += " is retrograde"

        #expect(original != appended)
    }
}
