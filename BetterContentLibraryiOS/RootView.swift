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
        Group {
            if auth.isAuthenticated {
                if let profile = auth.currentProfile {
                    // Keyed on the org: joining/leaving one rebuilds the whole
                    // session tree (AppModel, realtime, tabs) for the new org.
                    MainTabView(profile: profile)
                        .id(profile.orgId)
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
        .onOpenURL { url in
            if let code = OrgInviteLink.code(from: url) {
                DeepLinkCenter.shared.joinCode = code
            }
        }
    }
}
