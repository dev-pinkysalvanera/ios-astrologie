//
//  ChatMessage.swift
//  Astrologie
//
//  View-layer model for one line in the chat transcript. Deliberately separate
//  from the wire types in `ChatAPIDTOs.swift`: this one carries identity and a
//  local timestamp so SwiftUI can render and diff it, none of which appears in
//  the backend contract.
//

import Foundation

/// A single message in the chat transcript.
///
/// Identity is client-side only — the backend does not hand out message ids, so
/// one is minted on creation and kept stable for the lifetime of the value. That
/// makes the type safe to drive a `ForEach` even while an assistant reply is
/// still streaming in and its ``text`` grows.
struct ChatMessage: Identifiable, Equatable {

    /// Who authored the message.
    enum Role: String, Equatable, CaseIterable {
        case user
        case assistant
    }

    /// Stable, client-generated identity for SwiftUI diffing.
    let id: UUID

    /// Author of the message.
    let role: Role

    /// Message body as it should be displayed.
    ///
    /// Mutable so a streamed assistant reply can be appended to in place without
    /// changing ``id`` and forcing SwiftUI to tear down the row.
    var text: String

    /// When the message was created on device. Display-only; the backend never
    /// sees it.
    let timestamp: Date

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

extension ChatMessage {

    /// A message the person typed.
    static func user(_ text: String, timestamp: Date = Date()) -> ChatMessage {
        ChatMessage(role: .user, text: text, timestamp: timestamp)
    }

    /// A reply from the assistant. Starts empty when a stream is about to fill it.
    static func assistant(_ text: String = "", timestamp: Date = Date()) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, timestamp: timestamp)
    }
}
