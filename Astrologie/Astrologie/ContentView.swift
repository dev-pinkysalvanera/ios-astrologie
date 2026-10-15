//
//  ContentView.swift
//  Astrologie
//
//  Created by Pinky Salvanera on 8/7/26.
//
//  The app's root. Owns the chat screen's state and hands it to `ChatView`;
//  replaced the `Color.clear` placeholder once there was a real screen to show.
//

import SwiftUI

/// Root view: builds the chat screen's state and shows the transcript.
///
/// The ViewModel lives here, in `@State`, because this is the longest-lived view
/// in the app — surviving redraws of everything below it, which is exactly the
/// lifetime a transcript needs. The concrete ``ChatService`` is named once, here,
/// and nothing downstream learns which conformer it got.
///
/// The service is wired to ``AuthService/shared`` as a closure rather than a token
/// value: this initializer runs synchronously at launch, before the sign-in
/// `AstrologieApp` kicks off has resolved, so anything read here and kept would be
/// no token at all. Asking per send is what lets a first send wait for sign-in
/// instead of answering 401.
struct ContentView: View {

    @State private var viewModel: ChatViewModel = {
        let service = ChatService(
            accessToken: { try await AuthService.shared.accessToken() }
        )
        // The same service reports replies: same endpoint, token and session.
        return ChatViewModel(service: service, reporter: service)
    }()

    var body: some View {
        ChatView(viewModel: viewModel)
    }
}

#Preview {
    ContentView()
}
