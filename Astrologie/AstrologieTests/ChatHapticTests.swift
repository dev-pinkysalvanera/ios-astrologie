//
//  ChatHapticTests.swift
//  AstrologieTests
//
//  Pins which haptic each `ChatState` transition asks for. The simulator can't
//  play haptics, so this is as far as an automated test can go: that the right
//  one is requested. Feeling them apart still needs a physical device.
//

import SwiftUI
import Testing

@testable import Astrologie

struct ChatHapticTests {

    /// One value per shape of state, including the cancelled failure that's
    /// deliberately silent. Hand-maintained, like `ChatStateTests.allCases`.
    private static let states: [ChatState] = [
        .idle,
        .sending,
        .streaming,
        .failed(.network(.timedOut)),
        .failed(.network(.cancelled)),
        .failed(.httpStatus(code: 403, message: "Conversation limit reached.")),
    ]

    // MARK: - Send

    @Test func enteringSendingIsASend() {
        #expect(ChatHaptic.forTransition(from: .idle, to: .sending) == .send)
        // A retry after a failure is a send too.
        #expect(ChatHaptic.forTransition(from: .failed(.network(.timedOut)), to: .sending) == .send)
    }

    // MARK: - Completion

    @Test func streamingToIdleIsASuccess() {
        #expect(ChatHaptic.forTransition(from: .streaming, to: .idle) == .replyCompleted)
    }

    @Test func firstPieceArrivingIsSilent() {
        #expect(ChatHaptic.forTransition(from: .sending, to: .streaming) == nil)
    }

    /// Nothing of a reply arrived — an empty reply, or a cancel before the
    /// first piece with a stream that ends cleanly.
    @Test func sendingStraightToIdleIsNotASuccess() {
        #expect(ChatHaptic.forTransition(from: .sending, to: .idle) == nil)
    }

    // MARK: - Failure

    @Test func failingIsAnErrorNeverASuccess() {
        let failure = ChatState.failed(.network(.timedOut))
        #expect(ChatHaptic.forTransition(from: .sending, to: failure) == .failed)
        #expect(ChatHaptic.forTransition(from: .streaming, to: failure) == .failed)
    }

    @Test func cancellingIsSilent() {
        let cancelled = ChatState.failed(.network(.cancelled))
        #expect(ChatHaptic.forTransition(from: .sending, to: cancelled) == nil)
        #expect(ChatHaptic.forTransition(from: .streaming, to: cancelled) == nil)
    }

    /// Clearing the banner (e.g. "Start new conversation") isn't a completion.
    @Test func leavingAFailureForIdleIsSilent() {
        #expect(ChatHaptic.forTransition(from: .failed(.network(.timedOut)), to: .idle) == nil)
    }

    // MARK: - Across every transition

    /// Exhaustive over the table: success only ever comes from `.streaming` →
    /// `.idle`, and no transition into a failure is ever a success.
    @Test func successOnlyFromStreamingToIdle() {
        for old in Self.states {
            for new in Self.states {
                let haptic = ChatHaptic.forTransition(from: old, to: new)
                if haptic == .replyCompleted {
                    #expect(old == .streaming && new == .idle, "success on \(old) → \(new)")
                }
                if new.error != nil {
                    #expect(haptic != .replyCompleted, "success on \(old) → \(new)")
                }
                if old == new {
                    #expect(haptic == nil, "haptic on a non-change \(old)")
                }
            }
        }
    }

    // MARK: - Feedback mapping

    @Test func eachHapticMapsToDistinctFeedback() {
        #expect(ChatView.sensoryFeedback(for: .send) == .impact(weight: .light))
        #expect(ChatView.sensoryFeedback(for: .replyCompleted) == .success)
        #expect(ChatView.sensoryFeedback(for: .failed) == .error)
    }
}
