//
//  ChatBubble.swift
//  Astrologie
//
//  One row of the transcript. Reads a `ChatMessage` and nothing else: the styling
//  switch is on `ChatMessage.Role`, not on `ChatState`, so a bubble looks the same
//  whether its text is finished or still growing from a stream. That's deliberate
//  — a reply being appended to in place must not restyle itself mid-flight.
//

import SwiftUI

/// A single message rendered as a chat bubble.
///
/// The view is a pure function of its ``message``: same value in, same pixels out.
/// It holds no state, observes nothing, and knows nothing about sending — which is
/// what lets the message list hand it a row that a stream is still filling and get
/// a stable-looking bubble back.
struct ChatBubble: View {

    /// The message to render.
    let message: ChatMessage

    /// Space kept clear on the bubble's open side.
    ///
    /// A minimum rather than a fixed width, so a short message stays short and a
    /// long one grows until it hits this gutter. Keeping the far edge visible is
    /// what makes the alignment read as "who said it" at a glance.
    private static let gutter: CGFloat = 56

    var body: some View {
        HStack(spacing: 0) {
            if message.role.isTrailingAligned {
                Spacer(minLength: Self.gutter)
            }

            Text(Self.displayText(for: message))
                // `.body` rather than a point size: the bubble grows with the
                // reader's type setting instead of clipping at the larger sizes.
                .font(.body)
                .foregroundStyle(message.role.bubbleForeground)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.role.bubbleFill, in: .rect(cornerRadius: 18))

            if !message.role.isTrailingAligned {
                Spacer(minLength: Self.gutter)
            }
        }
        // One element per message, read as one sentence. Without this the speaker
        // and the text are separate stops in VoiceOver, and the shape and
        // alignment that carry authorship visually carry nothing at all.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(for: message))
    }

    /// The spoken form of a bubble: who said it, then what they said.
    ///
    /// Split out from ``body`` so the wording is checkable without rendering a
    /// view — the alignment and fill are the only other things that say who is
    /// talking, and neither survives being read aloud.
    static func accessibilityLabel(for message: ChatMessage) -> String {
        "\(message.role.speakerDescription): \(displayText(for: message))"
    }

    /// The text the bubble shows, derived fresh from ``ChatMessage/text``.
    ///
    /// Assistant replies go through ``MarkdownStripper`` as a backstop for
    /// markdown the model wasn't meant to write. It runs on the whole message
    /// each render, so a marker split across stream chunks is still caught. The
    /// person's own messages are shown exactly as typed. `message.text` itself is
    /// never changed, so a report sends what the model actually produced.
    static func displayText(for message: ChatMessage) -> String {
        switch message.role {
        case .assistant: MarkdownStripper.plainText(message.text)
        case .user: message.text
        }
    }
}

// MARK: - Role styling

extension ChatMessage.Role {

    /// Whether the bubble hugs the trailing edge.
    ///
    /// The person's own messages sit on the trailing side, the astrologer's on the
    /// leading side — the convention every chat app has trained people to read.
    /// Expressed as a flag rather than an `Alignment` because the layout uses it to
    /// pick which side gets the spacer.
    var isTrailingAligned: Bool {
        switch self {
        case .user: true
        case .assistant: false
        }
    }

    /// Background of the bubble.
    ///
    /// The accent colour for the person, a neutral wash for the astrologer. The
    /// neutral one is derived from `.secondary` rather than a hard-coded grey so it
    /// follows light and dark mode without a second asset.
    var bubbleFill: Color {
        switch self {
        case .user: Color.accentColor
        case .assistant: Color.secondary.opacity(0.18)
        }
    }

    /// Text colour, paired with ``bubbleFill`` for contrast.
    ///
    /// `.primary` on the neutral fill keeps the astrologer's replies legible in
    /// either appearance; the accent fill is dark enough in both to take white.
    var bubbleForeground: Color {
        switch self {
        case .user: Color.white
        case .assistant: Color.primary
        }
    }

    /// How the speaker is announced to assistive technology.
    var speakerDescription: String {
        switch self {
        case .user: "You said"
        case .assistant: "Astrologer said"
        }
    }
}

// MARK: - Previews

#Preview("Bubbles") {
    ScrollView {
        VStack(spacing: 12) {
            ChatBubble(message: .user("What's up with Mercury?"))
            ChatBubble(
                message: .assistant(
                    """
                    Mercury is retrograde until the 15th, which is a fine excuse \
                    to reread anything before you sign it.
                    """
                )
            )
            ChatBubble(message: .user("Noted."))
        }
        .padding()
    }
}
