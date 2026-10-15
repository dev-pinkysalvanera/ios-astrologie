//
//  ChatStateTests.swift
//  AstrologieTests
//
//  Covers the state enum on its own terms: the derived flags views read
//  (`isBusy`, `error`) and the equality the ViewModel tests assert against. The
//  send/reply transitions live in `ChatViewModelTests` — this file only pins what
//  each state means in isolation.
//

import Foundation
import Testing

@testable import Astrologie

struct ChatStateTests {

    /// One value per case, for the loop in ``onlyFailedCarriesAnError()``.
    ///
    /// Hand-maintained — ``ChatState`` isn't `CaseIterable` because `failed`
    /// carries a payload — so a new case needs adding here too. The compiler
    /// won't remind you.
    private static let allCases: [ChatState] = [
        .idle,
        .sending,
        .streaming,
        .failed(.invalidURL),
    ]

    // MARK: - isBusy

    @Test func inFlightStatesAreBusy() {
        #expect(ChatState.sending.isBusy)
        #expect(ChatState.streaming.isBusy)
    }

    @Test func restingStatesAreNotBusy() {
        #expect(ChatState.idle.isBusy == false)
        #expect(ChatState.failed(.network(.timedOut)).isBusy == false)
    }

    /// `.failed` not being busy is what lets `send()` accept a retry. Worth
    /// pinning separately from the flag itself, because flipping it would break
    /// retry without breaking any transition test.
    @Test func failedIsNotBusySoARetryCanStart() {
        let failed = ChatState.failed(.httpStatus(code: 429, message: "Rate limit exceeded."))

        #expect(failed.isBusy == false)
    }

    // MARK: - error

    @Test func onlyFailedCarriesAnError() {
        for state in Self.allCases where state != .failed(.invalidURL) {
            #expect(state.error == nil)
        }
    }

    @Test func failedHandsBackItsOwnError() {
        let failure = ChatError.httpStatus(code: 502, message: "Upstream unavailable.")

        #expect(ChatState.failed(failure).error == failure)
    }

    @Test func errorPreservesThePayloadRatherThanFlatteningIt() {
        let timedOut = ChatState.failed(.network(.timedOut))
        let offline = ChatState.failed(.network(.notConnectedToInternet))

        // Both are network failures; a view branching on the code needs them
        // distinguishable, not collapsed into "something went wrong".
        #expect(timedOut.error != offline.error)
        #expect(timedOut.error == .network(.timedOut))
    }

    // MARK: - Equality

    @Test func casesAreDistinctFromEachOther() {
        #expect(ChatState.idle != .sending)
        #expect(ChatState.sending != .streaming)
        #expect(ChatState.streaming != .idle)
        #expect(ChatState.idle != .failed(.invalidURL))
    }

    @Test func failedComparesOnItsError() {
        #expect(ChatState.failed(.invalidURL) == .failed(.invalidURL))
        #expect(ChatState.failed(.invalidURL) != .failed(.network(.timedOut)))
        #expect(
            ChatState.failed(.httpStatus(code: 429, message: "Slow down."))
                != .failed(.httpStatus(code: 429, message: nil))
        )
    }

    /// The reason ``ChatError`` keeps plain value payloads instead of boxing the
    /// underlying `Error`: a boxed one would compare by reference and break
    /// `state == .failed(x)` in every test that relies on it.
    @Test func statesAreValueComparableNotIdentityComparable() {
        let left = ChatState.failed(.decodingFailed(description: "missing chunk"))
        let right = ChatState.failed(.decodingFailed(description: "missing chunk"))

        #expect(left == right)
    }
}
