//
//  ChatViewModelReportTests.swift
//  AstrologieTests
//
//  Reporting an assistant reply (Week 9 Task 4): only finished assistant replies
//  can be reported, the raw text goes out, success and failure both land in
//  `reportState` for the screen to show, and a failure can be retried.
//

import Foundation
import Testing

@testable import Astrologie

// MARK: - Test doubles

/// Records each report and answers with the next queued outcome, then succeeds.
private actor RecordingReporter: MessageReporting {
    private(set) var reports: [(id: UUID, text: String)] = []
    private var failures: [ChatError]

    init(failures: [ChatError] = []) {
        self.failures = failures
    }

    func reportMessage(id messageID: UUID, text: String) async throws {
        reports.append((messageID, text))
        if !failures.isEmpty { throw failures.removeFirst() }
    }
}

/// Doesn't answer until the test opens it, so `.sending` can be observed.
private actor GatedReporter: MessageReporting {
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private(set) var calls = 0

    func reportMessage(id messageID: UUID, text: String) async throws {
        calls += 1
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

// MARK: - Helpers

@MainActor
private func viewModelWithReply(
    _ reply: String = "## Saturn\n**Big** year.",
    reporter: (any MessageReporting)?
) async -> ChatViewModel {
    let viewModel = ChatViewModel(
        service: MockChatService(.reply(reply)),
        reporter: reporter,
        resetSession: {}
    )
    viewModel.inputText = "Saturn return?"
    await viewModel.send()
    return viewModel
}

// MARK: - Which messages can be reported

@MainActor
struct ChatViewModelCanReportTests {

    @Test func aFinishedAssistantReplyCanBeReported() async throws {
        let viewModel = await viewModelWithReply(reporter: RecordingReporter())

        let reply = try #require(viewModel.messages.last)
        #expect(reply.role == .assistant)
        #expect(viewModel.canReport(reply))
    }

    @Test func theUsersOwnMessageCannotBeReported() async throws {
        let viewModel = await viewModelWithReply(reporter: RecordingReporter())

        let question = try #require(viewModel.messages.first)
        #expect(question.role == .user)
        #expect(!viewModel.canReport(question))
    }

    @Test func nothingCanBeReportedWithoutAReporter() async throws {
        let viewModel = await viewModelWithReply(reporter: nil)

        #expect(!viewModel.canReport(try #require(viewModel.messages.last)))
    }

    @Test func aReplyStillStreamingCannotBeReportedUntilItFinishes() async throws {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let viewModel = ChatViewModel(
            service: MockChatService(.handed(stream)),
            reporter: RecordingReporter(),
            resetSession: {}
        )
        viewModel.inputText = "Saturn return?"
        let send = Task { await viewModel.send() }

        continuation.yield("Saturn ")
        while viewModel.state != .streaming { await Task.yield() }

        let streaming = try #require(viewModel.messages.last)
        #expect(!viewModel.canReport(streaming))

        continuation.yield("returns.")
        continuation.finish()
        await send.value

        #expect(viewModel.canReport(try #require(viewModel.messages.last)))
    }

    @Test func anEarlierReplyCanBeReportedWhileANewOneStreams() async throws {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        let viewModel = ChatViewModel(
            service: MockChatService(.handed(stream)),
            reporter: RecordingReporter(),
            resetSession: {}
        )
        viewModel.messages = [.user("First?"), .assistant("First answer.")]
        let earlier = viewModel.messages[1]

        viewModel.inputText = "Second?"
        let send = Task { await viewModel.send() }
        continuation.yield("Second ")
        while viewModel.state != .streaming { await Task.yield() }

        #expect(viewModel.canReport(earlier))

        continuation.finish()
        await send.value
    }
}

// MARK: - Sending a report

@MainActor
struct ChatViewModelReportTests {

    @Test func reportingSendsTheRawTextAndLandsOnSent() async throws {
        let reporter = RecordingReporter()
        let viewModel = await viewModelWithReply("## Saturn\n**Big** year.", reporter: reporter)
        let reply = try #require(viewModel.messages.last)

        await viewModel.report(reply)

        let reports = await reporter.reports
        #expect(reports.count == 1)
        #expect(reports.first?.id == reply.id)
        // Not the stripped text the bubble shows.
        #expect(reports.first?.text == "## Saturn\n**Big** year.")
        #expect(viewModel.reportState == .sent(reply.id))
    }

    @Test func aFailedReportLandsOnFailedWithTheError() async throws {
        let error = ChatError.httpStatus(code: 502, message: "Failed to store report.")
        let viewModel = await viewModelWithReply(reporter: RecordingReporter(failures: [error]))
        let reply = try #require(viewModel.messages.last)

        await viewModel.report(reply)

        #expect(viewModel.reportState == .failed(reply.id, error))
        #expect(viewModel.messageWithFailedReport == reply)
    }

    @Test func aFailedReportCanBeRetried() async throws {
        let reporter = RecordingReporter(failures: [.network(.timedOut)])
        let viewModel = await viewModelWithReply(reporter: reporter)
        let reply = try #require(viewModel.messages.last)

        await viewModel.report(reply)
        // What the alert's retry button does: read the message, dismiss, resend.
        let retry = try #require(viewModel.messageWithFailedReport)
        viewModel.dismissReportOutcome()
        await viewModel.report(retry)

        #expect(await reporter.reports.count == 2)
        #expect(viewModel.reportState == .sent(reply.id))
    }

    @Test func aReportFailureDoesNotTouchTheSendState() async throws {
        let viewModel = await viewModelWithReply(
            reporter: RecordingReporter(failures: [.network(.timedOut)])
        )

        await viewModel.report(try #require(viewModel.messages.last))

        // The error banner reads `state`; a failed report mustn't show there.
        #expect(viewModel.state == .idle)
    }

    @Test func aSecondReportWaitsForTheFirst() async throws {
        let reporter = GatedReporter()
        let viewModel = await viewModelWithReply(reporter: reporter)
        let reply = try #require(viewModel.messages.last)

        let first = Task { await viewModel.report(reply) }
        while await reporter.calls == 0 { await Task.yield() }

        #expect(viewModel.reportState == .sending(reply.id))
        #expect(!viewModel.canReport(reply))
        await viewModel.report(reply)
        #expect(await reporter.calls == 1)

        await reporter.open()
        await first.value
        #expect(viewModel.reportState == .sent(reply.id))
    }

    @Test func dismissingClearsTheOutcome() async throws {
        let viewModel = await viewModelWithReply(reporter: RecordingReporter())
        await viewModel.report(try #require(viewModel.messages.last))

        viewModel.dismissReportOutcome()

        #expect(viewModel.reportState == .idle)
        #expect(viewModel.messageWithFailedReport == nil)
    }
}

// MARK: - What the screen shows

@MainActor
struct ChatViewReportAlertTests {

    @Test func noAlertWithoutAnOutcome() async {
        let viewModel = await viewModelWithReply(reporter: RecordingReporter())
        let view = ChatView(viewModel: viewModel)

        #expect(view.reportAlertTitle == nil)
        #expect(view.reportAlertMessage == nil)
    }

    @Test func aSentReportIsConfirmed() async throws {
        let viewModel = await viewModelWithReply(reporter: RecordingReporter())
        await viewModel.report(try #require(viewModel.messages.last))
        let view = ChatView(viewModel: viewModel)

        #expect(view.reportAlertTitle == ChatView.reportSentTitle)
        #expect(view.reportAlertMessage == ChatView.reportSentMessage)
    }

    @Test func aFailedReportSaysWhy() async throws {
        let viewModel = await viewModelWithReply(
            reporter: RecordingReporter(failures: [.network(.notConnectedToInternet)])
        )
        await viewModel.report(try #require(viewModel.messages.last))
        let view = ChatView(viewModel: viewModel)

        #expect(view.reportAlertTitle == ChatView.reportFailedTitle)
        #expect(view.reportAlertMessage == ChatError.network(.notConnectedToInternet).errorDescription)
    }
}
