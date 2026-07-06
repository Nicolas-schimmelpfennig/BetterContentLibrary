//
//  MainTabView.swift
//  BetterContentLibrary (iOS)
//
//  The signed-in shell: a bottom tab bar hosting Library / Upload / Schedule /
//  Settings, owning the session `AppModel` for its lifetime.
//

import SwiftUI
import BetterContentCore

struct MainTabView: View {
    private enum Tab { case library, upload, schedule, settings }

    private let profile: Profile
    @State private var model: AppModel
    @State private var selectedTab: Tab = .library
    @State private var deepLink = DeepLinkCenter.shared

    init(profile: Profile) {
        self.profile = profile
        _model = State(initialValue: AppModel(profile: profile))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryScreen(model: model)
                .tabItem { Label("Library", systemImage: "square.grid.2x2") }
                .tag(Tab.library)
            UploadScreen(model: model)
                .tabItem { Label("Upload", systemImage: "arrow.up.circle") }
                .tag(Tab.upload)
            ScheduleScreen(model: model)
                .tabItem { Label("Schedule", systemImage: "calendar") }
                .tag(Tab.schedule)
            SettingsScreen(model: model, profile: profile)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .task {
            PushManager.shared.activate(for: profile)
            if deepLink.scheduleDay != nil { selectedTab = .schedule }
        }
        .onChange(of: deepLink.scheduleDay) { _, day in
            if day != nil { selectedTab = .schedule }
        }
        // An invite link opens the join flow right over whatever tab is up.
        .sheet(isPresented: joinSheetBinding, onDismiss: { deepLink.joinCode = nil }) {
            JoinOrgScreen(profile: profile, initialCode: deepLink.joinCode ?? "")
        }
        .onDisappear { model.tearDown() }
    }

    private var joinSheetBinding: Binding<Bool> {
        Binding(
            get: { deepLink.joinCode != nil },
            set: { if !$0 { deepLink.joinCode = nil } }
        )
    }
}
