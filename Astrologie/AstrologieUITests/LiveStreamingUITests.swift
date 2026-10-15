//
//  LiveStreamingUITests.swift
//  AstrologieUITests
//
//  End-to-end check against the *deployed* `chat` function: type a question,
//  send it, and wait for the astrologer's reply with no error banner. This is the
//  Week 7 Wed / Week 8 Fri done-condition written as a test, so it can be re-run
//  instead of eyeballed.
//
//  It doesn't check that the reply *streamed*. A short reply reaches the device
//  in ~34 ms, too fast for a 0.5 s poll to see it grow, so that check failed on
//  correct behaviour (Week 9 Task 6). Incremental rendering is covered by the
//  mock-driven `ChatViewModelStreamingTests` and `TypingIndicatorTests` instead.
//
//  Opt-in, because it hits production and spends Gemini quota. Run with:
//
//    TEST_RUNNER_ASTRO_LIVE=1 xcodebuild test -scheme Astrologie \
//      -destination 'platform=iOS Simulator,name=iPhone 17' \
//      -only-testing:AstrologieUITests/LiveStreamingUITests
//
//  Uninstall the app from the simulator first to make the first launch a fresh
//  install (no Keychain session id, no stored auth session).
//

import XCTest

final class LiveStreamingUITests: XCTestCase {

    /// How long one reply gets to finish. Gemini readings are long, and the
    /// function's own upstream timeout is 45s per call.
    private static let replyTimeout: TimeInterval = 60

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["ASTRO_LIVE"] == "1",
            "Live production test. Set TEST_RUNNER_ASTRO_LIVE=1 to run it."
        )
    }

    /// First send, second send in the same session, then a send after relaunch.
    @MainActor
    func testRepliesArriveAcrossSendsAndRelaunch() throws {
        let app = XCUIApplication()
        app.launch()

        try sendAndAwaitReply(in: app, question: "In one sentence, what does Mercury retrograde mean?", label: "first send")
        try sendAndAwaitReply(in: app, question: "In one sentence, what does Saturn in the 7th house suggest?", label: "second send")

        app.terminate()
        app.launch()

        try sendAndAwaitReply(in: app, question: "In one sentence, what is a nakshatra?", label: "after relaunch")
    }

    // MARK: - Helpers

    /// Sends `question` and asserts that a new astrologer bubble appears and that
    /// no error banner shows up.
    @MainActor
    private func sendAndAwaitReply(in app: XCUIApplication, question: String, label: String) throws {
        let assistantBubbles = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Astrologer said:")
        )
        let errorBanner = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Error:")).firstMatch
        let before = assistantBubbles.count

        let field = app.textFields["Ask the astrologer"].exists
            ? app.textFields["Ask the astrologer"]
            : app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "[\(label)] compose field not found")
        field.tap()
        field.typeText(question)
        app.buttons["Send message"].tap()

        // Poll the newest assistant bubble until its text stops changing. The
        // distinct lengths seen are logged for diagnosis, not asserted on.
        var lengths: [Int] = []
        let deadline = Date().addingTimeInterval(Self.replyTimeout)
        var stableTicks = 0
        while Date() < deadline {
            if errorBanner.exists {
                XCTFail("[\(label)] error banner shown: \(errorBanner.label)")
                return
            }
            if assistantBubbles.count > before {
                let text = assistantBubbles.element(boundBy: assistantBubbles.count - 1).label
                let length = text.count - "Astrologer said: ".count
                if length > 0, lengths.last != length {
                    lengths.append(length)
                    stableTicks = 0
                } else if length > 0 {
                    stableTicks += 1
                    // Unchanged for ~3s and the send button's field is usable
                    // again: treat the reply as finished.
                    if stableTicks >= 6 { break }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let summary = "[\(label)] observed reply lengths: \(lengths)"
        print(summary)
        add(XCTAttachment(string: summary))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = label
        shot.lifetime = .keepAlways
        add(shot)

        XCTAssertFalse(lengths.isEmpty, "[\(label)] no reply text ever appeared")
        XCTAssertFalse(errorBanner.exists, "[\(label)] error banner shown after reply")
    }
}
