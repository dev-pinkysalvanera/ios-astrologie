//
//  ChatInputBar.swift
//  Astrologie
//
//  The compose bar under the transcript: a field that grows with what's typed and
//  a send button that only lights up when there's something to send and nothing
//  already in flight. Presentational on purpose — it takes a binding, a flag and
//  an action, and never sees the ViewModel. `ChatView` does the wiring.
//

import SwiftUI

/// The field and send button at the bottom of the chat screen.
///
/// Holds no state of its own: ``text`` is a binding into whoever owns the compose
/// field, and ``isBusy`` is read rather than inferred, so the bar can't disagree
/// with the ViewModel about whether a turn is underway.
///
/// The action is `async` rather than a fire-and-forget closure. Sending is an
/// awaitable thing, and keeping that in the type means the wiring can be awaited
/// in a test instead of polled for.
struct ChatInputBar: View {

    /// The compose field's contents, owned by the caller.
    @Binding var text: String

    /// Whether a turn is already underway. Straight from `ChatState.isBusy`.
    let isBusy: Bool

    /// Sends what's in the field.
    let send: () async -> Void

    /// How far the field grows before it starts scrolling its own contents.
    ///
    /// A range rather than a fixed height: one line to start, up to five for a
    /// longer question, and past that the field stops eating the transcript.
    private static let lineLimit = 1...5

    /// Placeholder in the empty field.
    private static let prompt = "Ask the astrologer"

    /// How the send button is announced.
    static let sendLabel = "Send message"

    /// The send button's glyph size. Scales with Dynamic Type so the button
    /// keeps pace with the field beside it instead of shrinking next to it.
    @ScaledMetric(relativeTo: .body) private var sendButtonSize: CGFloat = 30

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // `axis: .vertical` is what makes the field grow downward instead of
            // scrolling a single line sideways; `lineLimit` is what stops it.
            //
            // The placeholder is drawn separately because the system one stays
            // on one line and gets cut off at the larger text sizes. In a ZStack
            // so the field grows to fit it while the field is empty.
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(Self.prompt)
                        .font(.body)
                        .foregroundStyle(Color(uiColor: .placeholderText))
                        .allowsHitTesting(false)
                        // The field carries the prompt as its label instead.
                        .accessibilityHidden(true)
                }
                TextField("", text: $text, axis: .vertical)
                    .lineLimit(Self.lineLimit)
                    .font(.body)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityLabel(Self.prompt)
            }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // A mostly opaque system background rather than a translucent
                // wash: the bar is glass, and the transcript scrolls beneath it,
                // so a see-through field would put typed text over whatever
                // bubble happens to be passing — an accent-filled one included.
                // `.systemBackground` flips with the appearance, so it's
                // near-white under black text in light mode and near-black under
                // white text in dark.
                .background(Self.fieldFill, in: .rect(cornerRadius: 18))
                .overlay {
                    // A hairline so the field's edge survives on glass that's
                    // blurring something close to the field's own colour.
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                }

            Button {
                // A `Button` action is synchronous, so the await has to be handed
                // to a task. Nothing is captured but the closure itself.
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: sendButtonSize))
                    .symbolRenderingMode(.hierarchical)
            }
            .disabled(!canSend)
            // The glyph says nothing out loud, and the disabled state is already
            // announced for us — this only has to name the action.
            .accessibilityLabel(Self.sendLabel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Glass rather than `.bar`: the transcript runs underneath (``ChatView``
        // pins this in a safe-area inset), so the bar shows the conversation
        // moving behind it instead of cutting it off. A `ShapeStyle` background
        // extends through the bottom safe area by default, so the glass reaches
        // past the home indicator without a separate fill.
        .background(.ultraThinMaterial)
    }

    /// The compose field's fill. See the comment at its use in ``body``.
    private static let fieldFill = Color(uiColor: .systemBackground).opacity(0.85)

    /// Whether the send button is live.
    private var canSend: Bool {
        Self.canSend(text: text, isBusy: isBusy)
    }

    /// Whether `text` can be sent while `isBusy` holds.
    ///
    /// Split out from ``body`` so the rule is checkable without rendering, and
    /// static so it can be checked without a binding. It mirrors the guard in
    /// ``ChatViewModel/send()`` deliberately: the ViewModel still refuses a blank
    /// or overlapping send, and this is the same rule made visible — a button
    /// that's already dim beats one that looks live and does nothing.
    ///
    /// Trimmed the same way the ViewModel trims, so a field holding only spaces
    /// counts as empty rather than as something to send.
    static func canSend(text: String, isBusy: Bool) -> Bool {
        guard !isBusy else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Previews

#if DEBUG

/// Drives the bar through `@State` so the field is actually typeable in the
/// preview and the button lights up as text arrives.
private struct ChatInputBarPreview: View {
    let isBusy: Bool
    @State private var text: String

    init(text: String = "", isBusy: Bool = false) {
        self.isBusy = isBusy
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack {
            Spacer()
            ChatInputBar(text: $text, isBusy: isBusy) {}
        }
    }
}

#Preview("Empty") {
    ChatInputBarPreview()
}

#Preview("Typed") {
    ChatInputBarPreview(text: "What's up with Mercury?")
}

#Preview("Typed, dark") {
    ChatInputBarPreview(text: "What's up with Mercury?")
        .preferredColorScheme(.dark)
}

#Preview("Busy") {
    ChatInputBarPreview(text: "What's up with Mercury?", isBusy: true)
}

#Preview("Long") {
    ChatInputBarPreview(
        text: """
        Mercury is retrograde until the fifteenth and I have a contract to sign, \
        a flight to rebook and a text message I regret sending. Where do I start?
        """
    )
}

#endif
