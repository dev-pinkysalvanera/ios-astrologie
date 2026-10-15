//
//  TypingIndicator.swift
//  Astrologie
//
//  Three dots in an assistant-styled bubble, shown while a reply is in flight but
//  nothing of it has arrived. A short reply can land in tens of milliseconds, so
//  this is often on screen only briefly; on a slow one it's the only sign the tap
//  did anything. Whether it shows is `ChatState.showsTypingIndicator`'s call —
//  this view only knows how to look.
//

import SwiftUI

/// The "astrologer is typing" bubble.
///
/// Animates by pulsing each dot in turn. With Reduce Motion on, the dots sit
/// still at full strength instead: the bubble still says "a reply is coming",
/// it just doesn't move to say it.
struct TypingIndicator: View {

    /// What VoiceOver reads for the whole bubble. The dots carry no meaning when
    /// spoken, so the bubble is one element with this label instead.
    static let accessibilityLabel = "Astrologer is typing"

    /// Number of dots.
    private static let dotCount = 3

    /// Diameter of each dot. Scales with Dynamic Type alongside the bubbles.
    @ScaledMetric(relativeTo: .body) private var dotSize: CGFloat = 8

    /// One full pulse cycle across all dots.
    private static let cycle: Double = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            dots
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                // Same fill and shape as an assistant bubble, so it reads as the
                // reply that's about to appear in this spot.
                .background(ChatMessage.Role.assistant.bubbleFill, in: .rect(cornerRadius: 18))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel)
        .accessibilityIdentifier("typingIndicator")
    }

    @ViewBuilder
    private var dots: some View {
        if reduceMotion {
            HStack(spacing: dotSize * 0.6) {
                ForEach(0..<Self.dotCount, id: \.self) { _ in
                    dot(opacity: 0.6)
                }
            }
        } else {
            // A timeline rather than a repeating `withAnimation`: the phase is a
            // pure function of the clock, so there's no animation state to start,
            // stop, or leak when the view leaves.
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: dotSize * 0.6) {
                    ForEach(0..<Self.dotCount, id: \.self) { index in
                        dot(opacity: Self.opacity(at: time, dot: index))
                    }
                }
            }
        }
    }

    private func dot(opacity: Double) -> some View {
        Circle()
            .fill(ChatMessage.Role.assistant.bubbleForeground)
            .frame(width: dotSize, height: dotSize)
            .opacity(opacity)
    }

    /// Opacity of dot `index` at `time`: a sine pulse between 0.3 and 1, each dot
    /// offset by a third of a cycle so the pulse travels left to right.
    static func opacity(at time: TimeInterval, dot index: Int) -> Double {
        let phase = (time / cycle - Double(index) / Double(dotCount)) * 2 * .pi
        return 0.65 + 0.35 * sin(phase)
    }
}

// MARK: - Previews

#Preview("Typing") {
    TypingIndicator()
        .padding()
}
