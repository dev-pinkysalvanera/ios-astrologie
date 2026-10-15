//
//  ChatViewScrollTests.swift
//  AstrologieTests
//
//  Covers the part of auto-scroll that can be checked without rendering: the
//  anchor the list watches. Whether the newest message stays in view comes down
//  to whether that value changes when it should, so each way the transcript can
//  move is pinned here — including the one SwiftUI can't see on its own, a reply
//  growing in place.
//

import Foundation
import Testing

@testable import Astrologie

@MainActor
struct ChatViewScrollAnchorTests {

    private typealias ScrollAnchor = ChatView.ScrollAnchor

    // MARK: - Target

    @Test func theAnchorNamesTheNewestMessage() {
        let messages: [ChatMessage] = [.user("What's up with Mercury?"), .assistant("It's retrograde.")]

        let anchor = ScrollAnchor(for: messages)

        #expect(anchor.id == messages.last?.id)
    }

    /// Nothing to scroll to on a fresh screen. The view reads this as "don't
    /// scroll" rather than guessing at a row that doesn't exist.
    @Test func anEmptyTranscriptHasNoTarget() {
        #expect(ScrollAnchor(for: []).id == nil)
    }

    // MARK: - Detecting change

    @Test func appendingAMessageChangesTheAnchor() {
        var messages: [ChatMessage] = [.user("What's up with Mercury?")]
        let before = ScrollAnchor(for: messages)

        messages.append(.assistant("It's retrograde."))

        #expect(ScrollAnchor(for: messages) != before)
    }

    /// The case the whole type exists for: a streamed reply is appended to in
    /// place, so the count and every id hold still. Watching `messages` alone
    /// would miss this and leave a growing reply running off the bottom.
    @Test func growingTheLastReplyInPlaceChangesTheAnchor() {
        var messages: [ChatMessage] = [.user("What's up with Mercury?"), .assistant()]
        let before = ScrollAnchor(for: messages)

        messages[1].text += "Mercury"

        let afterFirstPiece = ScrollAnchor(for: messages)
        #expect(afterFirstPiece != before)
        // Still the same row, piece after piece — identity never moves, only the
        // text does.
        #expect(afterFirstPiece.id == before.id)

        messages[1].text += " is retrograde."

        #expect(ScrollAnchor(for: messages) != afterFirstPiece)
    }

    /// A redraw that changed nothing must not look like a change, or every
    /// unrelated update drags the list to the bottom and fights the reader
    /// scrolling back.
    @Test func anUnchangedTranscriptGivesAnEqualAnchor() {
        let messages: [ChatMessage] = [.user("What's up with Mercury?"), .assistant("It's retrograde.")]

        #expect(ScrollAnchor(for: messages) == ScrollAnchor(for: messages))
    }

    /// Only the newest message is watched. An edit further up isn't something to
    /// scroll to, and the transcript is append-only anyway.
    @Test func earlierMessagesDoNotMoveTheAnchor() {
        var messages: [ChatMessage] = [.user("What's up with Mercury?"), .assistant("It's retrograde.")]
        let before = ScrollAnchor(for: messages)

        messages[0].text = "Something else entirely."

        #expect(ScrollAnchor(for: messages) == before)
    }

    // MARK: - Animation

    @Test func aNewMessageAnimatesTheScroll() {
        var messages: [ChatMessage] = [.user("What's up with Mercury?")]
        let before = ScrollAnchor(for: messages)

        messages.append(.assistant())

        #expect(ScrollAnchor.animatesScroll(from: before, to: ScrollAnchor(for: messages)))
    }

    /// A stream lands many pieces a second. Animating each one would start an
    /// animation over the last and read as a stutter, so growth moves the list
    /// without one.
    @Test func aGrowingReplyScrollsWithoutAnimating() {
        var messages: [ChatMessage] = [.user("What's up with Mercury?"), .assistant()]
        let before = ScrollAnchor(for: messages)

        messages[1].text += "Mercury is retrograde."

        #expect(ScrollAnchor.animatesScroll(from: before, to: ScrollAnchor(for: messages)) == false)
    }

    /// The first message on an empty screen is still an arrival, so it animates
    /// rather than snapping from nowhere.
    @Test func theFirstMessageAnimates() {
        let empty = ScrollAnchor(for: [])
        let first = ScrollAnchor(for: [.user("What's up with Mercury?")])

        #expect(ScrollAnchor.animatesScroll(from: empty, to: first))
    }
}
