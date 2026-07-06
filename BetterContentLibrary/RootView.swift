//
//  RootView.swift
//  BetterContentLibrary
//

import SwiftUI
import BetterContentCore

/// A `bettercontent://join?code=…` link waiting to be handled.
private struct PendingJoin: Identifiable {
    let id = UUID()
    let code: String
}

/// Switches between the sign-in screen and the authenticated app, and fields
/// invite deep links for the whole window.
struct RootView: View {
    @Environment(AuthService.self) private var auth
    @State private var pendingJoin: PendingJoin?

    var body: some View {
        Group {
            if auth.isAuthenticated {
                ContentView()
            } else {
                LoginView()
            }
        }
        .onOpenURL { url in
            if let code = OrgInviteLink.code(from: url) {
                pendingJoin = PendingJoin(code: code)
            }
        }
        .sheet(item: $pendingJoin) { join in
            if let profile = auth.currentProfile {
                JoinOrgSheet(profile: profile, initialCode: join.code)
            } else {
                VStack(spacing: 12) {
                    Text("Sign in to join an organization")
                        .font(.headline)
                    Text("Once you're signed in, open the invite link again — or paste the code in Settings → Org.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("OK") { pendingJoin = nil }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(32)
                .frame(width: 380)
            }
        }
    }
}
