//
//  ChatHaptic.swift
//  Astrologie
//
//  Which haptic, if any, a `ChatState` transition earns. Decided here as a pure
//  function of the old and new state so the rule is testable without a device —
//  the simulator can't play haptics, so the only thing a test can check is that
//  the right one is *asked for*. `ChatView` maps the answer to `SensoryFeedback`.
//

import Foundation

/// A haptic the chat screen plays in response to a change of ``ChatState``.
///
/// Derived from the transition rather than fired from ``ChatViewModel/send()``,
/// for the same reason the typing indicator reads ``ChatState/showsTypingIndicator``:
/// a separate "should buzz" flag could drift out of step with the state it's
/// meant to describe.
nonisolated enum ChatHaptic: Equatable {

    /// The tap went out: the state entered `.sending`.
    case send

    /// A reply arrived and finished: `.streaming` → `.idle`.
    case replyCompleted

    /// The send failed (other than by being cancelled).
    case failed

    /// The haptic for moving from `old` to `new`, or `nil` for none.
    ///
    /// - Entering `.sending` from anywhere else is a send.
    /// - `.streaming` → `.idle` is the only success: some of the reply arrived
    ///   and the stream then ended cleanly.
    /// - `.sending` → `.idle` gets nothing. Nothing of a reply arrived — an empty
    ///   reply, or a send cancelled before its first piece — so there's no
    ///   completion to celebrate.
    /// - Entering `.failed` is an error, except `.network(.cancelled)`: a send
    ///   that was called off isn't a failure the person needs to feel.
    /// - Everything else (`.sending` → `.streaming`, a banner being cleared back
    ///   to `.idle`, no change at all) is silent. The first piece arriving is
    ///   already visible; buzzing on it too would crowd the completion haptic.
    static func forTransition(from old: ChatState, to new: ChatState) -> ChatHaptic? {
        guard old != new else { return nil }

        switch (old, new) {
        case (_, .sending):
            return .send
        case (.streaming, .idle):
            return .replyCompleted
        case (_, .failed(.network(.cancelled))):
            return nil
        case (_, .failed):
            return .failed
        default:
            return nil
        }
    }
}
