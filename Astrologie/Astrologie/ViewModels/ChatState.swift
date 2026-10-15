//
//  ChatState.swift
//  Astrologie
//
//  The chat screen's state as one value instead of a handful of flags. Replaces
//  the `isWaitingForResponse` / `lastError` pair on `ChatViewModel`: those two
//  could contradict each other (waiting *and* failed), and nothing in the type
//  system stopped it. Here the cases are mutually exclusive by construction.
//

import Foundation

/// Where the chat screen is in the send/reply cycle.
///
/// One value, one truth: the ViewModel is either resting, waiting on a reply,
/// receiving one, or holding a failure — never two of those at once. Views switch
/// over this rather than reading several booleans and hoping the combination is
/// one the ViewModel actually intended.
///
/// `Equatable` so tests can assert an exact state, which works because
/// ``ChatError`` carries plain value payloads rather than boxed `Error` values.
nonisolated enum ChatState: Equatable {

    /// Nothing outstanding. The compose field is live and a send may start.
    ///
    /// Also the state after a *successful* reply — success leaves no residue, so
    /// there's no separate "finished" case to drain.
    case idle

    /// A request is in flight and no part of the reply has arrived yet.
    ///
    /// The person's message is already in the transcript by this point; the send
    /// is optimistic, so `sending` describes the network, not the UI.
    case sending

    /// The reply has started arriving and is still being appended to.
    ///
    /// Unreachable this week. The service returns a complete reply
    /// (``ChatServiceProtocol/sendMessage(_:)``), so the flow goes
    /// `sending → idle` and never lands here. The case exists now so Week 6's SSE
    /// handling extends the flow instead of reshaping this enum — and so views
    /// written against it don't have to grow a new branch later.
    case streaming

    /// The last send failed. Carries the reason, ready to show.
    ///
    /// Terminal until the next send: the failure stays put so the person can read
    /// it, and their message stays in the transcript (nothing is rolled back).
    case failed(ChatError)
}

// MARK: - Derived flags

extension ChatState {

    /// Whether a turn is already underway.
    ///
    /// The guard on sending, and the one place that decides that `sending` and
    /// `streaming` mean the same thing to a caller — so adding a third in-flight
    /// case later doesn't mean auditing every `switch` in the view layer.
    var isBusy: Bool {
        switch self {
        case .sending, .streaming:
            return true
        case .idle, .failed:
            return false
        }
    }

    /// Whether the typing indicator belongs on screen.
    ///
    /// True only in `.sending`: the gap between the tap and the first piece of
    /// the reply, when nothing of it exists yet. Once a piece lands the state is
    /// `.streaming` and the growing bubble shows progress itself; a failure or a
    /// cancelled send leaves `.sending` too. Derived rather than stored so it
    /// can't drift out of step with the state it describes — deliberately *not*
    /// ``isBusy``, which also holds while the reply is arriving.
    var showsTypingIndicator: Bool {
        self == .sending
    }

    /// The failure being held, or `nil` in every other state.
    ///
    /// A convenience for views that only want to know whether to show an error,
    /// without unwrapping the case themselves.
    var error: ChatError? {
        switch self {
        case let .failed(error):
            return error
        case .idle, .sending, .streaming:
            return nil
        }
    }
}
