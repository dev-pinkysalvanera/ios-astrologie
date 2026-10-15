//
//  MessageReporting.swift
//  Astrologie
//
//  The seam for reporting an assistant reply (Week 9 Task 4). Separate from
//  `ChatServiceProtocol` because reporting is its own capability: a preview or a
//  test that only needs replies shouldn't have to say anything about reports, and
//  a screen without a reporter simply doesn't offer the action.
//

import Foundation

/// Sends a report of an assistant reply to the backend.
///
/// `Sendable` with a `nonisolated` method for the same reason as
/// ``ChatServiceProtocol``: the `@MainActor` ViewModel holds it, and the network
/// work belongs off the main actor.
protocol MessageReporting: Sendable {

    /// Reports the reply with `messageID` and `text`.
    ///
    /// - Parameters:
    ///   - messageID: The reply's ``ChatMessage/id``.
    ///   - text: The reply's raw ``ChatMessage/text``, exactly as the model
    ///     produced it.
    /// - Throws: ``ChatError`` for every failure mode. Returning normally means the
    ///   backend stored the report.
    nonisolated func reportMessage(id messageID: UUID, text: String) async throws
}
