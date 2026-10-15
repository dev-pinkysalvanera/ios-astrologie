//
//  ChatView.swift
//  Astrologie
//
//  The chat screen: the transcript from `ChatViewModel.messages`, one `ChatBubble`
//  per message, in a `ScrollView` wrapped in a `ScrollViewReader` so the newest
//  message stays in view, with the compose bar pinned underneath it. This file is
//  where the list and the bar are joined to the ViewModel — `ChatBubble` and
//  `ChatInputBar` are both written against values and never see it.
//
//  It is also where `ChatState.failed` becomes visible. The ViewModel has always
//  parked failures there, but nothing read them, so a failed send looked like the
//  app shrugging: the person's message appeared, the button came back to life, and
//  no reply ever arrived.
//

import SwiftUI

/// Shows the conversation held by a ``ChatViewModel``.
///
/// The ViewModel arrives from outside rather than being made here: this view is
/// one of several things that will read the same transcript, and whoever owns the
/// screen owns its state. It is held as a `let` because ``ChatViewModel`` is
/// `@Observable` — the reference never changes, and SwiftUI tracks the properties
/// this body actually reads, so appending to `messages` (or growing one message's
/// text) is enough to redraw without a binding.
struct ChatView: View {

    /// State behind the screen. Owned by the caller.
    let viewModel: ChatViewModel

    /// How long the scroll takes when a new message arrives.
    private static let scrollDuration: Double = 0.25

    /// The appearance in effect, so the nav bar's text can follow it rather than
    /// whatever happens to be scrolling beneath the glass.
    @Environment(\.colorScheme) private var colorScheme

    /// Title in the navigation bar.
    static let title = "Astrologie"

    var body: some View {
        NavigationStack {
            transcript
                .background(backdrop)
                // An inset rather than a `VStack` row: the transcript scrolls on
                // underneath, so the glass bar has the conversation to blur
                // instead of sitting on a blank strip. The inset also pushes the
                // scroll view's bottom edge up by the bar's height, so a
                // `.bottom`-anchored scroll still lands the newest line above the
                // bar rather than behind it.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // No spacing, and a divider instead: the bar carries its own
                    // background, so a gap here would show the transcript through
                    // between the two.
                    VStack(spacing: 0) {
                        // Above the divider, so it reads as belonging to the turn
                        // that just failed — the last thing under the message the
                        // person sent — while the divider stays directly against
                        // the bar. Sitting outside the `ScrollView` also keeps it
                        // clear of the auto-scroll machinery: the anchor watches
                        // `messages`, which an error doesn't touch, so showing or
                        // hiding this can't drag the list around.
                        errorBanner
                        Divider()
                        inputBar
                    }
                }
                .navigationTitle(Self.title)
                .navigationBarTitleDisplayMode(.inline)
                // The same glass as the compose bar, shown even at rest so the
                // top and bottom of the screen read as one pair of surfaces
                // rather than one bar that appears only once content scrolls
                // under it.
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                // Pinned to the current appearance. Left alone, the bar adapts
                // its title to whatever is under the glass, and an accent bubble
                // scrolled beneath it flips a light-mode title to white on a
                // lilac blur — about 3:1. Black on that blur is well clear.
                .toolbarColorScheme(colorScheme, for: .navigationBar)
        }
        .alert(reportAlertTitle ?? "", isPresented: reportAlertBinding) {
            reportAlertActions
        } message: {
            Text(reportAlertMessage ?? "")
        }
        // Keyed on the state itself, not on a flag of the view's own, so the
        // haptic can only follow a transition that actually happened. Which one
        // plays is ``ChatHaptic``'s call; this only turns it into feedback.
        .sensoryFeedback(trigger: viewModel.state) { old, new in
            ChatHaptic.forTransition(from: old, to: new).map(Self.sensoryFeedback(for:))
        }
        // VoiceOver only reads what has focus, so a view appearing elsewhere on
        // screen is silent unless it's announced. Keyed on the state for the
        // same reason as the haptic.
        .onChange(of: viewModel.state) { old, new in
            guard let announcement = Self.accessibilityAnnouncement(from: old, to: new) else {
                return
            }
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    // MARK: - VoiceOver announcements

    /// What VoiceOver should say for moving from `old` to `new`, or `nil`.
    ///
    /// - Entering `.sending`: the typing indicator appeared. It's an animation,
    ///   so without this a VoiceOver user gets no sign a reply is on its way.
    /// - Entering `.failed`: the error banner appeared, read the same way as the
    ///   banner itself. A cancelled send isn't announced, matching the haptic.
    /// - Everything else is silent. The reply's own bubble is there to read.
    ///
    /// Not private, so the rule is checkable without VoiceOver running.
    static func accessibilityAnnouncement(from old: ChatState, to new: ChatState) -> String? {
        guard old != new else { return nil }

        switch new {
        case .sending:
            return TypingIndicator.accessibilityLabel
        case .failed(.network(.cancelled)):
            return nil
        case let .failed(error):
            guard let description = error.errorDescription else { return nil }
            return accessibilityLabel(forError: description)
        case .idle, .streaming:
            return nil
        }
    }

    // MARK: - Backdrop

    /// What the transcript sits on, and what the glass bars blur.
    ///
    /// The system background with a faint accent wash fading down from the top,
    /// so the screen has a colour of its own without putting anything busy behind
    /// the text. Kept faint on purpose: the assistant bubble is a translucent
    /// wash over this, and `.primary` text on it has to stay legible in both
    /// appearances. Built from semantic colours, so it follows dark mode without
    /// a second asset.
    private var backdrop: some View {
        Color(uiColor: .systemBackground)
            .overlay {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.10), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .ignoresSafeArea()
    }

    // MARK: - Empty state

    /// Heading of the empty state.
    static let emptyStateTitle = "Ask the stars"

    /// The line under ``emptyStateTitle``.
    static let emptyStateMessage = "Ask about your sign, a transit, or what the week has in store."

    /// Whether the empty state is on screen.
    ///
    /// Only for a transcript with nothing in it and nothing on its way: once a
    /// send starts, the person's message is already in `messages`, and the
    /// typing indicator check is belt and braces so the two can never share the
    /// screen. Not private, so it's checkable without rendering, like
    /// ``showsTypingIndicator``.
    var showsEmptyState: Bool {
        viewModel.messages.isEmpty && !showsTypingIndicator
    }

    /// Shown in place of an empty transcript, so a first launch opens on an
    /// invitation rather than a blank screen with a text field at the bottom.
    ///
    /// `ContentUnavailableView` rather than a hand-rolled stack: it uses text
    /// styles throughout, so it scales with Dynamic Type, and it's already one
    /// sensible VoiceOver stop.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(Self.emptyStateTitle, systemImage: "moon.stars")
        } description: {
            Text(Self.emptyStateMessage)
        }
    }

    // MARK: - Haptics

    /// The system feedback behind each ``ChatHaptic``.
    ///
    /// Send is a light physical tap; completion and failure use the system's
    /// notification patterns, which are distinct from the tap and from each
    /// other. Not private, so the mapping is checkable without a device.
    static func sensoryFeedback(for haptic: ChatHaptic) -> SensoryFeedback {
        switch haptic {
        case .send:
            return .impact(weight: .light)
        case .replyCompleted:
            return .success
        case .failed:
            return .error
        }
    }

    // MARK: - Transcript

    /// Scroll target for the typing indicator. It isn't a message, so it has no
    /// ``ChatMessage/id`` of its own.
    private static let typingIndicatorID = "typingIndicator"

    /// Whether the typing indicator is on screen.
    ///
    /// Read straight off ``ChatState/showsTypingIndicator`` — no flag of the
    /// view's own — so it can't outlive `.sending` or sit beside the error
    /// banner. Not private, so it's checkable without rendering, like
    /// ``errorMessage``.
    var showsTypingIndicator: Bool {
        viewModel.state.showsTypingIndicator
    }

    /// The scrolling list of bubbles.
    private var transcript: some View {
        // The reader wraps the `ScrollView` rather than sitting inside it: the
        // proxy has to be in scope where the change is observed, and that
        // observation belongs to the whole list, not to any one row.
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy so a long transcript only builds the rows on screen. Rows are
                // keyed by `ChatMessage.id`, which is minted once and never changes, so
                // a streamed reply lands as an update to an existing row instead of a
                // teardown and rebuild.
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        ChatBubble(message: message)
                            // The same id the scroll target names. Stated
                            // explicitly so the row stays reachable by
                            // `scrollTo` even though `ForEach` already knows it.
                            .id(message.id)
                            // Long-press for sighted users. An empty menu (any
                            // message that can't be reported) shows nothing.
                            .contextMenu {
                                if viewModel.canReport(message) {
                                    reportButton(for: message)
                                }
                            } preview: {
                                reportPreview(for: message)
                            }
                            // The same action as a VoiceOver custom action, so it
                            // doesn't depend on a gesture.
                            .accessibilityActions {
                                if viewModel.canReport(message) {
                                    reportButton(for: message)
                                }
                            }
                    }

                    // After the last message, where the reply is about to
                    // appear. Gone the moment the first piece lands and the
                    // real bubble takes its place.
                    if showsTypingIndicator {
                        TypingIndicator()
                            .id(Self.typingIndicatorID)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            // Dragging the transcript down is the natural way to get the keyboard
            // out of the way to reread a reply.
            .scrollDismissesKeyboard(.interactively)
            // An overlay rather than a row inside the list, so it centres in the
            // visible area instead of sitting at the top of an empty stack.
            .overlay {
                if showsEmptyState {
                    emptyState
                        .transition(.opacity)
                }
            }
            // The indicator sits below the newest message, so the message-driven
            // scroll alone would leave it just off the bottom edge.
            .onChange(of: showsTypingIndicator) { _, isShowing in
                guard isShowing else { return }
                scrollToBottom(of: Self.typingIndicatorID, animated: true, using: proxy)
            }
            // Watching a derived value, not `messages` itself: a token appended to
            // the last reply changes neither the array's count nor any id, so
            // observing the collection would miss a reply growing mid-stream.
            .onChange(of: ScrollAnchor(for: viewModel.messages), initial: true) { previous, current in
                scroll(to: current, from: previous, using: proxy)
            }
        }
    }

    /// Brings the newest message back into view.
    ///
    /// Animated when a different message becomes the newest — that's a row
    /// arriving, and the motion is what shows it landing. Not animated while the
    /// same row grows: a stream lands many pieces a second, and each one would
    /// start its own animation over the last, which reads as a stutter rather
    /// than a scroll.
    ///
    /// While the typing indicator is up it's the last row, below the question
    /// that was just sent, so that's the target instead. A send adds both in
    /// one update, and two scrolls to different rows fought each other.
    private func scroll(to current: ScrollAnchor, from previous: ScrollAnchor, using proxy: ScrollViewProxy) {
        guard let id = current.id else { return }

        let target: AnyHashable = showsTypingIndicator ? Self.typingIndicatorID : id
        scrollToBottom(
            of: target,
            animated: ScrollAnchor.animatesScroll(from: previous, to: current),
            using: proxy
        )
    }

    /// Scrolls so the bottom of `target` sits at the bottom of the transcript.
    ///
    /// Anchored at the bottom so the *end* of a growing reply is what stays on
    /// screen; anchoring at the top would park a long reply's first line and let
    /// the rest run off the bottom edge.
    ///
    /// Deferred to the next main-queue turn. The row being scrolled to was
    /// usually inserted or resized in this same update, and the `LazyVStack`
    /// hasn't laid it out yet, so scrolling now lands short: the question half
    /// under the compose bar, the typing indicator and a burst reply off screen
    /// (Week 9 Task 6). Once laid out, the row's real frame is there to scroll to.
    private func scrollToBottom(of target: AnyHashable, animated: Bool, using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: Self.scrollDuration)) {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(target, anchor: .bottom)
            }
        }
    }

    // MARK: - Failure

    /// Icon carrying the "something went wrong" reading before a word is read.
    private static let errorIcon = "exclamationmark.triangle.fill"

    /// How the failure is introduced to assistive technology.
    ///
    /// The colour and the glyph are the only things that say *error* visually, and
    /// neither survives being read aloud, so the word is stated instead — the same
    /// trick ``ChatBubble`` uses to name the speaker it can only show by
    /// alignment.
    static let errorAccessibilityPrefix = "Error"

    /// The failure to show, or `nil` when there isn't one.
    ///
    /// Taken from ``ChatState/error`` and ``ChatError/errorDescription`` rather
    /// than switching over the state again here: the state already knows which
    /// cases hold a failure, and the error already knows how to describe itself
    /// for a client audience. Writing either rule a second time in the view layer
    /// is how the two drift apart.
    ///
    /// Not private, so the wording can be checked without rendering — the same
    /// seam ``inputBar`` opens for the compose bar.
    var errorMessage: String? {
        viewModel.state.error?.errorDescription
    }

    /// Whether the current failure is the 403 that means the conversation hit its
    /// turn limit, and so is the one case ``errorBanner`` offers a way past rather
    /// than leaving the compose bar as the only retry.
    ///
    /// Not private, for the same reason ``errorMessage`` isn't: checkable without
    /// rendering.
    var isTurnLimitReached: Bool {
        viewModel.state.error?.isTurnLimitReached ?? false
    }

    /// Label for the turn-limit banner's action.
    private static let newConversationLabel = "Start new conversation"

    /// The error line between the transcript and the compose bar.
    ///
    /// Nothing at all in every state but ``ChatState/failed(_:)`` — an empty
    /// reserved slot would put a permanent gap above the bar, and the failure is
    /// meant to be noticed by appearing.
    ///
    /// No retry button for most failures, by design: ``ChatViewModel/send()``
    /// clears `.failed` on its next run, so the compose bar *is* the retry, and a
    /// second control offering the same thing would need to answer what happens to
    /// the text the person has since typed. The turn limit is the one failure that
    /// retry can't clear — the backend rejects every send against this session
    /// id — so it's the one case the banner grows a button for, calling
    /// ``ChatViewModel/startNewConversation()`` to mint a session the next send can
    /// actually use.
    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.errorIcon)
                        .foregroundStyle(.red)

                    // `.primary` on the wash rather than red-on-red: the tint
                    // carries the meaning, the text only has to stay readable in
                    // both appearances. `.callout` keeps it quieter than a bubble
                    // while still scaling with the reader's type setting.
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                // One element read as one sentence, for the same reason a bubble
                // is: otherwise the glyph and the message are separate stops and
                // the glyph says nothing. Week 7's accessibility pass is where a
                // spoken announcement on arrival belongs; this is only here to
                // make sure the failure isn't silent.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.accessibilityLabel(forError: errorMessage))

                if isTurnLimitReached {
                    // Prominent rather than plain: white on the accent fill holds
                    // up in both appearances, where accent-coloured text on a red
                    // wash over dark glass does not.
                    Button(Self.newConversationLabel) {
                        viewModel.startNewConversation()
                    }
                    .font(.callout.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // Derived from `.red` rather than a fixed colour, so the wash follows
            // light and dark mode the way the bubbles' neutral fill does. Laid
            // over the same glass as the bar, because the banner now sits above
            // a transcript that scrolls beneath it: a bare wash would let a
            // passing bubble show straight through behind the text.
            .background(Color.red.opacity(0.12))
            .background(.ultraThinMaterial)
        }
    }

    /// The spoken form of the error line: that it *is* an error, then what it says.
    ///
    /// Split out from ``errorBanner`` so the wording is checkable without
    /// rendering.
    static func accessibilityLabel(forError message: String) -> String {
        "\(errorAccessibilityPrefix): \(message)"
    }

    // MARK: - Reporting

    /// Label of the report action, in the context menu and as a VoiceOver action.
    static let reportLabel = "Report Message"

    /// Title of the confirmation once a report is stored.
    static let reportSentTitle = "Report Sent"

    /// Body of the confirmation.
    static let reportSentMessage = "Thanks. We'll review this reply."

    /// Title of the alert when a report fails.
    static let reportFailedTitle = "Couldn't Send Report"

    /// The failed-report alert's retry button.
    static let retryReportLabel = "Try Again"

    /// Most lines of a reply the context menu's preview shows.
    private static let reportPreviewLineLimit = 6

    /// Width of the context menu's preview.
    private static let reportPreviewWidth: CGFloat = 320

    /// The preview above the report menu: the start of the reply, not all of it.
    ///
    /// Left to the system, the preview is the whole bubble. A long reading is
    /// taller than the screen, so it gets shrunk into a thin column that runs
    /// behind the menu, worst at the large accessibility sizes. A few lines at
    /// a fixed width is enough to show which reply is being reported.
    private func reportPreview(for message: ChatMessage) -> some View {
        Text(ChatBubble.displayText(for: message))
            .font(.body)
            .lineLimit(Self.reportPreviewLineLimit)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: Self.reportPreviewWidth, alignment: .leading)
    }

    /// The action that reports `message`.
    private func reportButton(for message: ChatMessage) -> some View {
        Button(Self.reportLabel, systemImage: "flag") {
            Task { await viewModel.report(message) }
        }
    }

    /// Title of the alert for the current report outcome, or `nil` when there's
    /// nothing to show. Not private, so it's checkable without rendering.
    var reportAlertTitle: String? {
        switch viewModel.reportState {
        case .sent: Self.reportSentTitle
        case .failed: Self.reportFailedTitle
        case .idle, .sending: nil
        }
    }

    /// Body of that alert: the thanks on success, the reason on failure.
    var reportAlertMessage: String? {
        switch viewModel.reportState {
        case .sent: Self.reportSentMessage
        case let .failed(_, error): error.errorDescription
        case .idle, .sending: nil
        }
    }

    /// Presents the alert while there's an outcome, and clears it on dismissal.
    private var reportAlertBinding: Binding<Bool> {
        Binding {
            reportAlertTitle != nil
        } set: { isPresented in
            if !isPresented { viewModel.dismissReportOutcome() }
        }
    }

    /// An alert rather than a toast for both outcomes: it's announced by
    /// VoiceOver without extra work, and a failure needs a button anyway.
    @ViewBuilder
    private var reportAlertActions: some View {
        if let message = viewModel.messageWithFailedReport {
            // `message` is read now, before dismissal clears the failure, so the
            // retry still knows what to send.
            Button(Self.retryReportLabel) {
                Task { await viewModel.report(message) }
            }
            Button("Cancel", role: .cancel) {}
        } else {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Compose bar

    /// The compose bar, wired to the ViewModel.
    ///
    /// Built here rather than inline in ``body`` so the wiring is one named thing
    /// that can be picked up and exercised without rendering: typing into the
    /// returned bar writes through to ``ChatViewModel/inputText``, and its action
    /// runs the real ``ChatViewModel/send()``.
    ///
    /// The busy flag comes from ``ChatState/isBusy`` rather than from a separate
    /// boolean, so the button and the ViewModel's own guard can't drift apart.
    var inputBar: ChatInputBar {
        ChatInputBar(text: inputTextBinding, isBusy: viewModel.state.isBusy) {
            await viewModel.send()
        }
    }

    /// Two-way access to the compose field.
    ///
    /// Written out rather than taken from `@Bindable` because the ViewModel
    /// arrives as a plain `let` — the reference never changes, and this is the one
    /// property the view writes back to.
    private var inputTextBinding: Binding<String> {
        Binding { viewModel.inputText } set: { viewModel.inputText = $0 }
    }
}

// MARK: - Scroll anchor

extension ChatView {

    /// What auto-scroll watches: which message is newest, and how much of it
    /// there is so far.
    ///
    /// The second half is the point. A streamed reply is appended to *in place*,
    /// keeping its ``ChatMessage/id`` so SwiftUI reuses the row — which means the
    /// transcript's count and its identities both hold still while the text
    /// grows. Carrying the text here makes that growth a change `onChange` can
    /// see. The text is carried whole rather than as a length because a `String`
    /// copy shares storage (so this costs a reference, not a walk of the
    /// characters) and because a length can't tell a rewrite from a no-op.
    struct ScrollAnchor: Equatable {

        /// The newest message, or `nil` on an empty transcript.
        let id: ChatMessage.ID?

        /// That message's text as it currently stands.
        let text: String

        /// - Parameter messages: The transcript, oldest first.
        init(for messages: [ChatMessage]) {
            id = messages.last?.id
            text = messages.last?.text ?? ""
        }

        /// Whether moving from `previous` to `current` should animate.
        ///
        /// A change of newest message is a new row; anything else is the same row
        /// growing. Split out from the view so the distinction is checkable
        /// without rendering — it's the difference between a scroll that reads as
        /// motion and one that reads as a stutter.
        static func animatesScroll(from previous: ScrollAnchor, to current: ScrollAnchor) -> Bool {
            previous.id != current.id
        }
    }
}

// MARK: - Previews

#if DEBUG

/// Stands in for the network in previews.
///
/// Conforms with the buffered method only and inherits the protocol's streaming
/// default, so a preview never reaches for a URL session. Nothing in this file
/// calls it yet — it exists because ``ChatViewModel`` has no default service, by
/// design: the caller always says where replies come from.
private struct PreviewChatService: ChatServiceProtocol {
    nonisolated func sendMessage(_ message: String) async throws -> String {
        "Mercury is retrograde. Reread anything before you sign it."
    }
}

/// A ViewModel holding a canned transcript, so the preview shows a conversation
/// rather than an empty screen.
@MainActor
private func previewViewModel() -> ChatViewModel {
    let viewModel = ChatViewModel(service: PreviewChatService())
    viewModel.messages = [
        .user("What's up with Mercury?"),
        .assistant(
            """
            Mercury is retrograde until the 15th, which is a fine excuse to \
            reread anything before you sign it.
            """
        ),
        .user("And Venus?"),
        .assistant("Venus is direct and in no mood for subtlety."),
    ]
    return viewModel
}

#Preview("Conversation") {
    ChatView(viewModel: previewViewModel())
}

#Preview("Conversation, dark") {
    ChatView(viewModel: previewViewModel())
        .preferredColorScheme(.dark)
}

#Preview("Empty") {
    ChatView(viewModel: ChatViewModel(service: PreviewChatService()))
}

#Preview("Empty, dark") {
    ChatView(viewModel: ChatViewModel(service: PreviewChatService()))
        .preferredColorScheme(.dark)
}

/// Fails every send with a rejected token, so the preview shows the banner's
/// session copy rather than the handler's own wording for the wire.
private struct FailingChatService: ChatServiceProtocol {
    nonisolated func sendMessage(_ message: String) async throws -> String {
        throw ChatError.httpStatus(
            code: ChatError.unauthorizedStatusCode,
            message: "Missing authorization header"
        )
    }
}

/// The failure as the person meets it: their message in the transcript, the
/// reason underneath it, and the bar live again so the next attempt is just
/// typing.
///
/// Driven through a real ``ChatViewModel/send()`` rather than by assigning the
/// state, because ``ChatViewModel/state`` has a private setter — transitions
/// belong to the send, and a preview is no reason to widen that.
#Preview("Failed send") {
    @Previewable @State var viewModel = ChatViewModel(service: FailingChatService())

    ChatView(viewModel: viewModel)
        .task {
            viewModel.inputText = "What's up with Mercury?"
            await viewModel.send()
        }
}

/// Fails every send with the turn-limit 403, so the preview shows the banner's
/// escape hatch rather than a dead end.
private struct TurnLimitChatService: ChatServiceProtocol {
    nonisolated func sendMessage(_ message: String) async throws -> String {
        throw ChatError.httpStatus(
            code: ChatError.turnLimitStatusCode,
            message: "Conversation limit reached. Please start a new thread."
        )
    }
}

/// The turn limit as the person meets it: the backend's own wording, and a
/// button that gets them past it instead of leaving the compose bar to fail the
/// same way again.
#Preview("Turn limit reached") {
    @Previewable @State var viewModel = ChatViewModel(service: TurnLimitChatService())

    ChatView(viewModel: viewModel)
        .task {
            viewModel.inputText = "What's up with Mercury?"
            await viewModel.send()
        }
}

#Preview("Turn limit reached, dark") {
    @Previewable @State var viewModel = ChatViewModel(service: TurnLimitChatService())

    ChatView(viewModel: viewModel)
        .preferredColorScheme(.dark)
        .task {
            viewModel.inputText = "What's up with Mercury?"
            await viewModel.send()
        }
}

/// A transcript taller than the screen with a reply still arriving, which is the
/// only way to see auto-scroll do anything: on a short conversation there is
/// nothing to scroll.
@MainActor
private func streamingPreviewViewModel() -> ChatViewModel {
    let viewModel = ChatViewModel(service: PreviewChatService())
    viewModel.messages = (1...12).flatMap { turn in
        [ChatMessage.user("Question \(turn)?"), .assistant("Answer \(turn).")]
    }
    viewModel.messages.append(.assistant())
    return viewModel
}

#Preview("Streaming") {
    @Previewable @State var viewModel = streamingPreviewViewModel()

    ChatView(viewModel: viewModel)
        .task {
            // Lands one word at a time, the way the real stream does, so the last
            // line should stay pinned to the bottom edge as it grows.
            for word in "Mercury is retrograde until the fifteenth, so reread anything before you sign it.".split(separator: " ") {
                try? await Task.sleep(for: .milliseconds(250))
                viewModel.messages[viewModel.messages.count - 1].text += "\(word) "
            }
        }
}

#endif
