//
//  AstrologieApp.swift
//  Astrologie
//
//  Created by Pinky Salvanera on 8/7/26.
//

import SwiftUI

@main
struct AstrologieApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { await signIn() }
        }
    }

    /// Establishes the app's Supabase identity as the first screen appears.
    ///
    /// Here rather than at the first send so the token is usually ready before
    /// anyone types: sign-in is a round trip, and the backend answers 401 without
    /// a bearer token. On a fresh install this mints the anonymous user; on every
    /// later launch it reuses the persisted one.
    ///
    /// Not a precondition for sending: ``ChatService`` awaits the token per
    /// request, so someone who types before this finishes waits rather than
    /// getting a 401. This call just means they usually don't have to wait at all.
    ///
    /// - Note: A failure is deliberately not surfaced yet. There is nowhere to
    ///   show it from here, and the next send retries sign-in and reports the
    ///   failure through the existing error banner. Giving a failed sign-in its own
    ///   wording is separate work.
    private func signIn() async {
        _ = try? await AuthService.shared.signIn()
    }
}
