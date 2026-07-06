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
            // Keyed on the org: joining/leaving one rebuilds the whole session
            // tree (AppModel, realtime channel, both panes) for the new org.
            MainView(profile: profile)
                .id(profile.orgId)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading your library…").foregroundStyle(.secondary)
            }
            .frame(minWidth: 360, minHeight: 280)
        }
    }
}

/// Two-pane shell: library (left) and schedule calendar (right), side by side
/// so clips drag straight from the library onto a day. Owns the `AppModel`
/// for the lifetime of the signed-in session. Either pane can be hidden
/// (toolbar toggles, bare L/S keys, or the View menu), but never both.
///
/// The split is a hand-rolled HStack rather than HSplitView: both panes stay
/// in the hierarchy permanently and only their widths change, so toggling a
/// pane is instant in both directions (nothing is torn down or rebuilt) and
/// every bit of in-pane state survives. HSplitView forced a choice between a
/// rebuild on re-show (slow) or the returning pane squeezed to its minimum.
private struct MainView: View {
    @Environment(AuthService.self) private var auth
    @State private var model: AppModel

    @AppStorage(SettingsKey.showLibraryPane) private var showLibrary = true
    @AppStorage(SettingsKey.showSchedulePane) private var showSchedule = true
    /// Divider position as the library's share of the window width.
    @AppStorage(SettingsKey.mainSplitFraction) private var splitFraction = 0.5

    /// Bare-key L/S pane toggles (Settings-configurable).
    @State private var paneShortcuts = PaneShortcutMonitor()

    private let libraryMin: CGFloat = 520
    private let scheduleMin: CGFloat = 440
    private let dividerWidth: CGFloat = 1

    init(profile: Profile) {
        _model = State(initialValue: AppModel(profile: profile))
    }

    var body: some View {
        GeometryReader { geo in
            let library = libraryWidth(total: geo.size.width)
            HStack(spacing: 0) {
                LibraryView(model: model, isActive: showLibrary)
                    .frame(width: library)
                    .clipped()
                    .opacity(showLibrary ? 1 : 0)
                    .allowsHitTesting(showLibrary)

                if showLibrary && showSchedule {
                    splitDivider(total: geo.size.width)
                }

                ScheduleView(model: model)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .opacity(showSchedule ? 1 : 0)
                    .allowsHitTesting(showSchedule)
            }
            .coordinateSpace(name: "mainSplit")
        }
        .frame(minWidth: showLibrary && showSchedule ? 1000 : 520, minHeight: 700)
        .toolbar {
            paneToggles
            accountMenu
        }
        .onAppear { paneShortcuts.start() }
        .onDisappear {
            paneShortcuts.stop()
            model.tearDown()
        }
        // Backstop for the "never both hidden" rule, wherever the toggle came
        // from (toolbar, key, menu command, stale defaults).
        .onChange(of: showLibrary) { _, visible in
            if !visible && !showSchedule { showSchedule = true }
        }
        .onChange(of: showSchedule) { _, visible in
            if !visible && !showLibrary { showLibrary = true }
        }
    }

    /// The library pane's width for the current visibility + divider state.
    /// The schedule pane takes whatever remains via `maxWidth: .infinity`.
    private func libraryWidth(total: CGFloat) -> CGFloat {
        switch (showLibrary, showSchedule) {
        case (true, true):
            let maxLibrary = max(libraryMin, total - scheduleMin - dividerWidth)
            return min(max(total * splitFraction, libraryMin), maxLibrary)
        case (true, false):
            return total
        default:
            return 0
        }
    }

    /// 1pt divider with a wider invisible grab area for dragging.
    private func splitDivider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: dividerWidth)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("mainSplit"))
                            .onChanged { value in
                                guard total > 0 else { return }
                                let lower = libraryMin / total
                                let upper = max(lower, (total - scheduleMin - dividerWidth) / total)
                                splitFraction = min(max(value.location.x / total, lower), upper)
                            }
                    )
            }
    }

    private var paneToggles: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Toggle(isOn: $showLibrary) {
                    Label("Library", systemImage: "photo.on.rectangle.angled")
                }
                .help("Show or hide the Library (⌘L)")
                Toggle(isOn: $showSchedule) {
                    Label("Schedule", systemImage: "calendar")
                }
                .help("Show or hide the Schedule (⌘S)")
            }
        }
    }

    private var accountMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Text(auth.currentProfile?.displayName ?? "Signed in")
                Text(auth.currentProfile?.role.displayLabel ?? "")
                Divider()
                Button("Sign Out") {
                    Task { try? await auth.signOut() }
                }
            } label: {
                Image(systemName: "person.circle")
            }
            .help("Account")
        }
    }
}
