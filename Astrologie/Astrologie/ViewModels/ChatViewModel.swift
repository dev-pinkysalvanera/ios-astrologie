//
//  ChatViewModel.swift
//  Astrologie
//
//  State for the chat screen. Owns the transcript and the compose field, sends
//  through the injected service, and grows the reply into the transcript as it
//  arrives. Progress through a send is modeled by a single `ChatState` value
//  rather than a set of independent flags.
//

import Foundation
import Observation

/// Observable state behind the chat screen.
///
/// `@MainActor` because everything here is view state: SwiftUI reads it during
/// layout, so it has no business living anywhere but the main actor. The service
/// it talks to is `Sendable` with a `nonisolated` send method, so the network
/// work happens off the main actor while every mutation below stays on it.
///
/// The service arrives through ``ChatServiceProtocol`` rather than a concrete
/// type, and there is deliberately no default: the caller decides whether this
/// ViewModel is driven by the real client or by a stub, and the ViewModel never
/// learns which.
@Observable
@MainActor
final class ChatViewModel {

    /// The transcript, oldest first. Drives the message list.
    var messages: [ChatMessage] = []

    /// Text currently in the compose field.
    var inputText: String = ""

    /// Where the screen is in the send/reply cycle.
    ///
    /// The one source of truth for progress and failure. Because ``ChatState``'s
    /// cases are exclusive, "waiting" and "failed" can't both hold — a send moves
    /// this value from `.idle` to `.sending` and then to either `.idle` or
    /// `.failed`, and views read that instead of combining flags.
    ///
    /// Private setter: transitions belong to ``send()``. Callers observe the
    /// state, they don't author it.
    private(set) var state: ChatState = .idle

    /// The seam to the backend. Held as an existential so any conformer fits.
    let service: any ChatServiceProtocol

    /// Sends reports, or `nil` where reporting isn't offered (previews, most
    /// tests). Without one, ``canReport(_:)`` is false for every message, so the
    /// action never appears rather than appearing and failing.
    private let reporter: (any MessageReporting)?

    /// Where the latest report is: in flight, sent, or failed.
    ///
    /// Separate from ``state`` on purpose. Reporting a past reply doesn't touch
    /// the send cycle: a report can go out while a new reply is streaming, and a
    /// failed report mustn't show up as a failed send in the error banner.
    private(set) var reportState: ReportState = .idle

    /// Mints and persists a new session id, called when the person taps the
    /// turn-limit banner's way forward.
    ///
    /// A closure rather than a held `SessionManager` for the same reason
    /// ``ChatService`` takes ``sessionID`` as one: it's the one piece of
    /// `SessionManager`'s surface this type needs, and a test can substitute its
    /// own without standing up a Keychain-backed instance. Defaults to the shared
    /// manager's reset so production callers don't have to know it exists.
    private let resetSession: @Sendable () -> Void

    /// - Parameters:
    ///   - service: The service used to send messages. Injected by the protocol
    ///     so tests and previews can supply their own conformer.
    ///   - reporter: Sends reports of assistant replies. `nil`, the default,
    ///     means the screen doesn't offer reporting.
    ///   - resetSession: Starts a new backend session, used by
    ///     ``startNewConversation()``. Defaults to ``SessionManager/shared``'s
    ///     reset.
    init(
        service: any ChatServiceProtocol,
        reporter: (any MessageReporting)? = nil,
        resetSession: @escaping @Sendable () -> Void = { SessionManager.shared.resetSession() }
    ) {
        self.service = service
        self.reporter = reporter
        self.resetSession = resetSession
    }

    // MARK: - Sending

    /// Sends the compose field's contents and grows the reply into the transcript
    /// as it arrives.
    ///
    /// Optimistic: the user's message goes into ``messages`` and the field is
    /// cleared before the request leaves, so the transcript reacts on the same
    /// turn of the run loop as the tap. Iterating the service's stream suspends
    /// without holding the main actor; every resumption appends one piece of the
    /// reply and hands SwiftUI a change to render, which is what makes the reply
    /// appear token by token rather than all at once.
    ///
    /// The assistant row is created empty on the *first* piece — not up front —
    /// and its ``ChatMessage/text`` is appended to in place afterwards, so its
    /// ``ChatMessage/id`` never changes and SwiftUI keeps the same row. Waiting
    /// for that first piece is what keeps `.sending` meaningful: while it holds,
    /// nothing of the reply exists yet, so there's no empty bubble on screen.
    ///
    /// ``state`` walks `.sending` → `.streaming` → `.idle`, with any failure
    /// landing in `.failed` instead. Entering `.sending` also clears a previous
    /// `.failed`, so a retry never shows the last attempt's error. Note the state
    /// is *replaced*, not restored: there's no `defer` resetting it, because
    /// success and failure land on different cases and a blanket reset would
    /// discard the error.
    ///
    /// A failure part-way through keeps whatever already arrived — a truncated
    /// reply stays visible under the error rather than vanishing, the same way the
    /// user's message is never rolled back.
    ///
    /// The compose field, though, comes back: a failure restores `inputText` to
    /// the question that was sent, so the person doesn't have to retype it to try
    /// again. Only the field is restored — the transcript keeps the user message
    /// it already appended, same as before.
    ///
    /// A blank field is a no-op, and so is a second call while a turn is already
    /// in flight — the ViewModel models one turn at a time.
    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !state.isBusy else { return }

        messages.append(.user(text))
        inputText = ""
        state = .sending

        do {
            // The row being filled, once there is one. Carried as an id rather
            // than an index because an offset held across a suspension point is
            // only as trustworthy as everyone else's use of `messages`.
            var replyID: ChatMessage.ID?

            for try await piece in service.streamMessage(text) {
                replyID = appending(piece, toReplyWith: replyID)
            }
            state = .idle
        } catch {
            state = .failed(ChatError(from: error))
            inputText = text
        }
    }

    // MARK: - Turn limit escape hatch

    /// Starts a new backend session after the turn limit is reached, so a 403
    /// dead end has somewhere to go.
    ///
    /// Mints a new session id through ``resetSession`` — the backend's turn
    /// counter is keyed on that id with no expiry of its own, so a fresh one is
    /// the only way past it — clears the transcript, and returns the screen to
    /// `.idle`.
    ///
    /// The transcript goes because the button promises a new conversation, and
    /// Gemini never sees earlier messages anyway, so keeping them on screen only
    /// suggested a continuity that wasn't there (Week 10 Task 4). The compose
    /// field keeps the question the failed send restored, ready to send again.
    ///
    /// Only meaningful while ``state`` holds ``ChatError/isTurnLimitReached``; the
    /// banner is the only caller and only offers this action for that failure. A
    /// call mid-turn would pull the transcript out from under a reply that's still
    /// arriving, so it's ignored while ``ChatState/isBusy``.
    func startNewConversation() {
        guard !state.isBusy else { return }

        resetSession()
        messages = []
        reportState = .idle
        if case .failed = state {
            state = .idle
        }
    }

    // MARK: - Reporting

    /// Whether `message` can be reported right now.
    ///
    /// Only an assistant reply, only once it's finished — the reply still
    /// streaming in is the last message while ``state`` is `.streaming`, and a
    /// report of half a reply would record text the person never saw in full —
    /// and only one report at a time.
    func canReport(_ message: ChatMessage) -> Bool {
        guard reporter != nil, message.role == .assistant, !message.text.isEmpty else {
            return false
        }
        if case .sending = reportState { return false }
        let isStreaming = state == .streaming && message.id == messages.last?.id
        return !isStreaming
    }

    /// Reports `message`, landing ``reportState`` on `.sent` or `.failed`.
    ///
    /// Sends the raw ``ChatMessage/text``, not what the bubble displays, so the
    /// report holds exactly what the model produced. A call that ``canReport(_:)``
    /// would refuse is a no-op.
    func report(_ message: ChatMessage) async {
        guard canReport(message), let reporter else { return }

        reportState = .sending(message.id)
        do {
            try await reporter.reportMessage(id: message.id, text: message.text)
            reportState = .sent(message.id)
        } catch {
            reportState = .failed(message.id, ChatError(from: error))
        }
    }

    /// The message whose report just failed, ready to hand back to
    /// ``report(_:)`` for a retry. `nil` unless ``reportState`` is `.failed`.
    ///
    /// Read synchronously by the retry button, before the alert's dismissal
    /// clears the failure: the retry itself runs a moment later, by which time
    /// ``reportState`` is `.idle` again.
    var messageWithFailedReport: ChatMessage? {
        guard case let .failed(id, _) = reportState else { return nil }
        return messages.first { $0.id == id }
    }

    /// Clears a sent or failed outcome once the person has seen it. Leaves a
    /// report that's still in flight alone.
    func dismissReportOutcome() {
        switch reportState {
        case .sent, .failed:
            reportState = .idle
        case .idle, .sending:
            break
        }
    }

    /// Appends one piece of a streamed reply, starting the assistant row if this
    /// is the first piece.
    ///
    /// - Parameters:
    ///   - piece: The text to append, exactly as the service handed it over.
    ///   - replyID: The row being filled, or `nil` before the first piece.
    /// - Returns: The row's id, ready to pass back in for the next piece.
    private func appending(_ piece: String, toReplyWith replyID: ChatMessage.ID?) -> ChatMessage.ID {
        guard let replyID, let index = messages.firstIndex(where: { $0.id == replyID }) else {
            // Empty first, then filled in place — the same two steps every later
            // piece takes, so the row is never rebuilt and its id never moves.
            let reply = ChatMessage.assistant()
            messages.append(reply)
            // The reply has started arriving, so this is no longer a wait.
            state = .streaming
            messages[messages.count - 1].text += piece
            return reply.id
        }

        messages[index].text += piece
        return replyID
    }
}

// MARK: - Report state

/// Where a report of an assistant reply is. Each case after `idle` carries the
/// ``ChatMessage/id`` of the reply it's about.
nonisolated enum ReportState: Equatable {
    /// No report in flight, and no outcome waiting to be shown.
    case idle

    /// The report is on its way.
    case sending(UUID)

    /// The backend stored the report. Shown to the person as a confirmation.
    case sent(UUID)

    /// The report didn't go through. Shown with a way to try again, because a
    /// failure that's silent looks exactly like a success.
    case failed(UUID, ChatError)
}

// MARK: - Error normalization

private extension ChatError {

    /// Folds anything thrown by a service into a ``ChatError``.
    ///
    /// Conformers are documented to throw ``ChatError`` and the real client does,
    /// but the protocol can't enforce it (Swift has no typed throws here that the
    /// existential would preserve), so a stray `URLError` keeps its code and
    /// anything else lands on an unlabeled network failure rather than crashing
    /// the send.
    init(from error: Error) {
        switch error {
        case let chatError as ChatError:
            self = chatError
        case let urlError as URLError:
            self = .network(urlError.code)
        default:
            self = .network(.unknown)
        }
    }
}
