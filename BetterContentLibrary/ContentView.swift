//
//  ContentView.swift
//  BetterContentLibrary
//
//  Created by Nicolas Schimmelpfennig on 23/06/2026.
//

import SwiftUI
import BetterContentCore

struct ContentView: View {
    @Environment(AuthService.self) private var auth

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .imageScale(.large)
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("BetterContentLibrary")
                .font(.title.bold())

            if let profile = auth.currentProfile {
                VStack(spacing: 4) {
                    Text("Signed in as \(profile.displayName ?? "—")")
                    Text("Role: \(profile.role.rawValue)")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } else if auth.isLoadingProfile {
                ProgressView()
            }

            Button("Sign Out") {
                Task { try? await auth.signOut() }
            }
            .padding(.top, 8)
        }
        .padding(40)
        .frame(minWidth: 360, minHeight: 280)
    }
}
