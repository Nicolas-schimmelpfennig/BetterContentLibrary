//
//  RootView.swift
//  BetterContentLibrary
//

import SwiftUI
import BetterContentCore

/// Switches between the sign-in screen and the authenticated app.
struct RootView: View {
    @Environment(AuthService.self) private var auth

    var body: some View {
        if auth.isAuthenticated {
            ContentView()
        } else {
            LoginView()
        }
    }
}
