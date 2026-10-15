//
//  ChatBubbleTests.swift
//  AstrologieTests
//
//  Covers the part of `ChatBubble` that can be checked without rendering: the
//  role-driven presentation. Which side a bubble sits on, how it's filled, and how
//  it's read aloud are the only things that say who is talking, so each one is
//  pinned to the role rather than left to the layout.
//

import SwiftUI
import Testing

@testable import Astrologie

@MainActor
struct ChatBubbleRoleStylingTests {

    // MARK: - Alignment

    @Test func theUserSitsOnTheTrailingEdgeAndTheAstrologerOnTheLeading() {
        #expect(ChatMessage.Role.user.isTrailingAligned)
        #expect(ChatMessage.Role.assistant.isTrailingAligned == false)
    }

    /// Every case has to differ from the others on something visible, or two
    /// speakers render identically. Written over `allCases` so a third role can't
    /// be added without this failing.
    @Test func everyRoleIsVisuallyDistinct() {
        let fills = Set(ChatMessage.Role.allCases.map(\.bubbleFill))
        let alignments = Set(ChatMessage.Role.allCases.map(\.isTrailingAligned))

        #expect(fills.count == ChatMessage.Role.allCases.count)
        #expect(alignments.count == ChatMessage.Role.allCases.count)
    }

    // MARK: - Colours

    @Test func fillAndForegroundArePairedForContrast() {
        // The pairing is the point: a fill change that kept the old text colour
        // would be legal and unreadable.
        #expect(ChatMessage.Role.user.bubbleFill == Color.accentColor)
        #expect(ChatMessage.Role.user.bubbleForeground == Color.white)
        #expect(ChatMessage.Role.assistant.bubbleForeground == Color.primary)
    }

    /// `.secondary` derived rather than a fixed grey, so the astrologer's bubble
    /// follows the appearance instead of needing a second asset.
    @Test func theAssistantFillAdaptsToTheAppearance() {
        #expect(ChatMessage.Role.assistant.bubbleFill == Color.secondary.opacity(0.18))
    }

    // MARK: - Accessibility

    @Test func rolesAreAnnouncedDistinctly() {
        let descriptions = Set(ChatMessage.Role.allCases.map(\.speakerDescription))

        #expect(descriptions.count == ChatMessage.Role.allCases.count)
        #expect(ChatMessage.Role.user.speakerDescription.isEmpty == false)
        #expect(ChatMessage.Role.assistant.speakerDescription.isEmpty == false)
    }
}

// MARK: - Accessibility label

@MainActor
struct ChatBubbleAccessibilityLabelTests {

    @Test func labelNamesTheSpeakerThenQuotesTheMessage() {
        let user = ChatBubble.accessibilityLabel(for: .user("What's up with Mercury?"))
        let assistant = ChatBubble.accessibilityLabel(for: .assistant("Mercury is retrograde."))

        #expect(user == "You said: What's up with Mercury?")
        #expect(assistant == "Astrologer said: Mercury is retrograde.")
    }

    /// The bubble is combined into one accessibility element, so the whole reply
    /// has to be in the label — a truncated one would be read as the whole message.
    @Test func labelCarriesTheFullTextVerbatim() {
        let text = "Mercury is retrograde.\nReread anything before you sign it."

        let label = ChatBubble.accessibilityLabel(for: .assistant(text))

        #expect(label.hasSuffix(text))
    }

    /// A streamed reply starts empty for an instant. It must still announce its
    /// speaker rather than reading as a blank row.
    @Test func labelStillNamesTheSpeakerForAnEmptyMessage() {
        let label = ChatBubble.accessibilityLabel(for: .assistant())

        #expect(label == "Astrologer said: ")
    }
}
