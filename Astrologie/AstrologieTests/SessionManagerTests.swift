//
//  SessionManagerTests.swift
//  AstrologieTests
//
//  Covers the one-launch-one-session contract (Week 10 Task 4): an id is minted
//  on first read, reads are idempotent, a reset mints a new one, and a fresh
//  manager — the app-relaunch case — starts a new session rather than picking
//  the old one back up.
//

import Foundation
import Testing

@testable import Astrologie

/// Hands out "id-0", "id-1", … so each mint is distinguishable.
private final class IDSequence: @unchecked Sendable {
    private var count = 0

    func next() -> String {
        defer { count += 1 }
        return "id-\(count)"
    }
}

struct SessionManagerTests {

    @Test func firstReadGeneratesAnID() {
        let manager = SessionManager(generateID: { "generated-id" })

        #expect(manager.sessionID == "generated-id")
    }

    @Test func generatedIDIsAUUIDByDefault() {
        let manager = SessionManager()

        #expect(UUID(uuidString: manager.sessionID) != nil)
    }

    @Test func repeatedReadsReturnTheSameID() {
        let ids = IDSequence()
        let manager = SessionManager(generateID: ids.next)

        let first = manager.sessionID
        let second = manager.sessionID

        #expect(first == "id-0")
        #expect(second == first)
    }

    /// The relaunch case: a new process gets a new manager, and with nothing
    /// persisted it mints a new id, so the backend's turn count starts fresh along
    /// with the empty transcript.
    @Test func aFreshManagerStartsANewSession() {
        let ids = IDSequence()

        let firstLaunch = SessionManager(generateID: ids.next)
        let secondLaunch = SessionManager(generateID: ids.next)

        #expect(firstLaunch.sessionID == "id-0")
        #expect(secondLaunch.sessionID == "id-1")
    }

    @Test func resetMintsADifferentID() {
        let ids = IDSequence()
        let manager = SessionManager(generateID: ids.next)
        let before = manager.sessionID

        let returned = manager.resetSession()

        #expect(returned != before)
        #expect(manager.sessionID == returned)
    }

    @Test func resetWorksEvenWithoutAPriorRead() {
        let manager = SessionManager(generateID: { "only-id" })

        #expect(manager.resetSession() == "only-id")
        #expect(manager.sessionID == "only-id")
    }
}
