//
//  ContentView.swift
//  BetterContentLibrary
//
//  The signed-in shell (design 1c–1d): custom-styled sidebar with the main
//  sections, Pipeline smart filters (with live counts), root folders, and the
//  account footer; detail hosts Upload / Library / Schedule.
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
                Text("Loading your library…").foregroundStyle(BCLTheme.textSecondary)
            }
            .frame(minWidth: 360, minHeight: 280)
            .background(BCLTheme.content)
        }
    }
}

/// The three primary sections of the app.
enum AppSection: String, CaseIterable, Identifiable {
    case library, schedule, upload
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
        case .upload: return "tray.and.arrow.up"
        case .library: return "square.grid.2x2"
        case .schedule: return "calendar"
        }
    }
}

/// Sidebar shell hosting Library / Schedule / Upload, owning the `AppModel`
/// for the lifetime of the signed-in session.
private struct MainView: View {
    @Environment(AuthService.self) private var auth
    @State private var model: AppModel
    @State private var selection: AppSection = .library
    /// Active Pipeline smart filter (ready = "Needs scheduling"); nil = browse.
    @State private var pipelineFilter: ClipDisplayStatus?

    init(profile: Profile) {
        _model = State(initialValue: AppModel(profile: profile))
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 214)
        } detail: {
            detail
                .frame(minWidth: 560, minHeight: 480)
                .background(BCLTheme.content)
        }
        .onDisappear { model.tearDown() }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .upload: UploadView(model: model)
        case .library: LibraryView(model: model, pipelineFilter: $pipelineFilter)
        case .schedule: ScheduleView(model: model)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(AppSection.allCases) { section in
                        sectionRow(section)
                    }

                    sidebarLabel("PIPELINE")
                    pipelineRow(.ready, title: "Needs scheduling")
                    pipelineRow(.scheduled, title: "Scheduled")
                    pipelineRow(.posted, title: "Posted")

                    if !rootFolders.isEmpty {
                        sidebarLabel("FOLDERS")
                        ForEach(rootFolders) { folder in
                            folderRow(folder)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)
            accountFooter
        }
        .background(BCLTheme.sidebar)
        .toolbar(removing: .sidebarToggle)
    }

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark(size: 20)
            Text(auth.currentProfile?.displayName ?? "BCL")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(BCLTheme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func sidebarLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(BCLTheme.textPrimary.opacity(0.35))
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 5)
    }

    private func sectionRow(_ section: AppSection) -> some View {
        let isActive = selection == section && pipelineFilter == nil
        return Button {
            pipelineFilter = nil
            selection = section
        } label: {
            HStack(spacing: 7) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? BCLTheme.accent : BCLTheme.textPrimary.opacity(0.5))
                    .frame(width: 16)
                Text(section.title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? BCLTheme.textPrimary : BCLTheme.textPrimary.opacity(0.8))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                isActive ? Color.white.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pipelineRow(_ status: ClipDisplayStatus, title: String) -> some View {
        let isActive = selection == .library && pipelineFilter == status
        let count = model.library.clips(withDisplayStatus: status).count
        return Button {
            selection = .library
            pipelineFilter = status
        } label: {
            HStack(spacing: 7) {
                StatusDot(status)
                    .padding(.horizontal, 3)
                Text(title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? BCLTheme.textPrimary : BCLTheme.textPrimary.opacity(0.8))
                Spacer(minLength: 0)
                if count > 0, status != .posted {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(BCLTheme.textLabel)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                isActive ? Color.white.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Root folders when browsing at the top level (the library keeps deeper
    /// navigation in its own path bar).
    private var rootFolders: [Folder] {
        model.library.path.isEmpty ? model.library.subfolders : []
    }

    private func folderRow(_ folder: Folder) -> some View {
        Button {
            pipelineFilter = nil
            selection = .library
            Task { await model.library.open(folder) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(BCLTheme.textPrimary.opacity(0.5))
                    .frame(width: 16)
                Text(folder.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(BCLTheme.textPrimary.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var accountFooter: some View {
        HStack(spacing: 8) {
            Text(initials)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(BCLTheme.textPrimary)
                .frame(width: 22, height: 22)
                .background(Color(hex: 0x3A3A44), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(auth.currentProfile?.displayName ?? "Signed in")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(BCLTheme.textPrimary.opacity(0.75))
                    .lineLimit(1)
                Text(auth.currentProfile?.role.rawValue.capitalized ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(BCLTheme.textLabel)
            }
            Spacer()
            Button {
                Task { try? await auth.signOut() }
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(BCLTheme.textPrimary.opacity(0.45))
            }
            .buttonStyle(.borderless)
            .help("Sign out")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { BCLTheme.hairline.frame(height: 1) }
    }

    private var initials: String {
        let name = auth.currentProfile?.displayName ?? "?"
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }
}
