//
//  ContentView.swift
//  BetterContentLibrary
//
//  Created by Nicolas Schimmelpfennig on 23/06/2026.
//

import SwiftUI
import BetterContentCore

/// Authenticated entry point. Waits for the profile (which carries the org id)
/// before building the session-scoped `AppModel`, then shows the main app.
struct ContentView: View {
    @Environment(AuthService.self) private var auth

    var body: some View {
        if let profile = auth.currentProfile {
            MainView(profile: profile)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading your library…").foregroundStyle(.secondary)
            }
            .frame(minWidth: 360, minHeight: 280)
        }
    }
}

/// The three primary sections of the app.
enum AppSection: String, CaseIterable, Identifiable {
    case upload, library, schedule
    var id: Self { self }

    var title: String {
        switch self {
        case .upload: return "Upload"
        case .library: return "Library"
        case .schedule: return "Schedule"
        }
    }

    var systemImage: String {
        switch self {
        case .upload: return "arrow.up.circle"
        case .library: return "square.grid.2x2"
        case .schedule: return "calendar"
        }
    }
}

/// Sidebar shell hosting Upload / Library / Schedule, owning the `AppModel`
/// for the lifetime of the signed-in session.
private struct MainView: View {
    @Environment(AuthService.self) private var auth
    @State private var model: AppModel
    @State private var selection: AppSection = .upload

    init(profile: Profile) {
        _model = State(initialValue: AppModel(profile: profile))
    }

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("BetterContent")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { accountFooter }
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 480)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .upload: UploadView(model: model)
        case .library: LibraryView(model: model)
        case .schedule: ScheduleView(model: model)
        }
    }

    private var accountFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(auth.currentProfile?.displayName ?? "Signed in")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(auth.currentProfile?.role.rawValue.capitalized ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { try? await auth.signOut() }
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("Sign out")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
