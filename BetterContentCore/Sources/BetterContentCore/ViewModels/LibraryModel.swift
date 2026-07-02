//
//  LibraryModel.swift
//  BetterContentCore
//
//  Shared, platform-agnostic library state, used by both the macOS and iOS apps.
//

import Foundation
import Observation

/// Folder-aware library state: the current folder path (breadcrumb), the
/// subfolders and clips within it, with create/move/delete and Finder-style
/// back/forward history.
@MainActor
@Observable
public final class LibraryModel {
    private let clips: ClipsService
    private let folders: FoldersService
    private let schedules = SchedulesService()
    public let orgId: UUID

    /// Breadcrumb from root; the last element is the current folder (empty = root).
    public private(set) var path: [Folder] = []
    public private(set) var subfolders: [Folder] = []
    public private(set) var items: [Clip] = []
    /// The whole org's clips (across folders), newest first — powers the
    /// Pipeline smart filters and their sidebar counts.
    public private(set) var allClips: [Clip] = []
    /// The org's schedules grouped by clip, for deriving display status.
    public private(set) var schedulesByClip: [UUID: [Schedule]] = [:]
    public private(set) var isLoading = false
    public var errorMessage: String?

    public var currentFolder: Folder? { path.last }

    /// The badge state for a clip: transfer status merged with schedule-derived
    /// presentation states (scheduled/posted).
    public func displayStatus(for clip: Clip) -> ClipDisplayStatus {
        ClipDisplayStatus.derive(clip: clip, schedules: schedulesByClip[clip.id] ?? [])
    }

    /// Org-wide clips whose display status matches — the Pipeline smart lists
    /// ("Needs scheduling" = ready, Scheduled, Posted).
    public func clips(withDisplayStatus status: ClipDisplayStatus) -> [Clip] {
        allClips.filter { displayStatus(for: $0) == status }
    }

    /// Finder/Safari-style location history. Each entry is a full breadcrumb path;
    /// the current `path` is not in either stack.
    private var backStack: [[Folder]] = []
    private var forwardStack: [[Folder]] = []
    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    public init(orgId: UUID, clips: ClipsService = ClipsService(), folders: FoldersService = FoldersService()) {
        self.orgId = orgId
        self.clips = clips
        self.folders = folders
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let subs = folders.list(parent: currentFolder?.id)
            async let cl = clips.list(inFolder: currentFolder?.id)
            async let all = clips.list()
            async let sch = schedules.listAll()
            subfolders = try await subs
            items = try await cl
            allClips = try await all
            schedulesByClip = Dictionary(grouping: try await sch, by: \.clipId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func open(_ folder: Folder) async {
        go(to: path + [folder])
        await load()
    }

    /// Jumps to a folder already in the breadcrumb (or root if nil).
    public func navigate(to folder: Folder?) async {
        if let folder, let index = path.firstIndex(of: folder) {
            go(to: Array(path.prefix(index + 1)))
        } else {
            go(to: [])
        }
        await load()
    }

    /// Goes back one location in history.
    public func goBack() async {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        path = previous
        await load()
    }

    /// Goes forward one location in history.
    public func goForward() async {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        path = next
        await load()
    }

    /// Records the current location on the back stack and moves to `newPath`,
    /// clearing the forward stack — standard browser behavior.
    private func go(to newPath: [Folder]) {
        guard newPath != path else { return }
        backStack.append(path)
        forwardStack.removeAll()
        path = newPath
    }

    public func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await folders.create(name: trimmed, orgId: orgId, parentId: currentFolder?.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func move(clipId: UUID, to folderId: UUID?) async {
        do {
            try await clips.setFolder(clipId, folderId: folderId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteFolder(_ folder: Folder) async {
        do {
            try await folders.delete(folder.id)
            // Drop any history that would navigate back into the now-gone folder.
            backStack.removeAll { $0.contains(folder) }
            forwardStack.removeAll { $0.contains(folder) }
            if path.contains(folder) {
                path = Array(path.prefix(while: { $0 != folder }))
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func renameClip(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await clips.setTitle(id, trimmed)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func renameFolder(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await folders.rename(id, name: trimmed)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
