//
//  RootView.swift
//  BetterContentLibrary (iOS)
//

import SwiftUI
import BetterContentCore

/// Switches between sign-in and the authenticated tab app. Once authenticated,
/// waits for the profile (which carries the org id) before building `AppModel`.
struct RootView: View {
    @Environment(AuthService.self) private var auth

    var body: some View {
        if auth.isAuthenticated {
            if let profile = auth.currentProfile {
                MainTabView(profile: profile)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading your library…").foregroundStyle(.secondary)
                }
            }
        } else {
            LoginView()
        }
    }
}
