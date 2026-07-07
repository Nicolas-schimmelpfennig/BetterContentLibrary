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
    /// Every folder in the org (all nesting levels), name-sorted — the source
    /// for `moveDestinations`, so a clip can be moved anywhere, not just into
    /// the current folder's children.
    public private(set) var allFolders: [Folder] = []
    public private(set) var items: [Clip] = []
    /// Schedules per clip (org-wide), for deriving each clip's status tag
    /// (uploading / scheduled / posted / …) in the library.
    public private(set) var schedulesByClip: [UUID: [Schedule]] = [:]
    public private(set) var isLoading = false
    public var errorMessage: String?

    /// Set after the first `load()`, successful or not. Lets the initial
    /// view `.task` skip refetching on every appearance (e.g. a pane being
    /// re-shown) — realtime sync and explicit actions (navigate, create,
    /// delete, refresh button, …) all call `load()` directly and stay live.
    public private(set) var hasLoaded = false

    public var currentFolder: Folder? { path.last }

    /// Every folder in the org flattened depth-first (name-sorted at each level)
    /// with its nesting depth and full path from the root (e.g. "Marketing / Q3").
    /// This is the destination list for a "Move to" menu: it spans the whole org,
    /// and the path disambiguates same-named folders under different parents.
    public var moveDestinations: [FolderDestination] {
        var childrenByParent: [UUID?: [Folder]] = [:]
        for folder in allFolders {
            childrenByParent[folder.parentId, default: []].append(folder)
        }
        var result: [FolderDestination] = []
        func walk(parent: UUID?, depth: Int, prefix: String) {
            for folder in childrenByParent[parent] ?? [] {
                let path = prefix.isEmpty ? folder.name : "\(prefix) / \(folder.name)"
                result.append(FolderDestination(folder: folder, depth: depth, path: path))
                walk(parent: folder.id, depth: depth + 1, prefix: path)
            }
        }
        walk(parent: nil, depth: 0, prefix: "")
        return result
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
        defer { isLoading = false; hasLoaded = true }
        do {
            async let subs = folders.list(parent: currentFolder?.id)
            async let all = folders.listAll(orgId: orgId)
            async let cl = clips.list(inFolder: currentFolder?.id)
            async let sch = schedules.listAll()
            // Await everything, then publish in one synchronous burst. Assigning
            // as each fetch lands would briefly leave the new folder's subfolders
            // paired with the previous folder's clips (or vice versa) — a window
            // that can read as empty and flash the "Nothing here yet" state.
            let (newSubfolders, newAllFolders, newItems, newSchedules) =
                try await (subs, all, cl, sch)
            subfolders = newSubfolders
            allFolders = newAllFolders
            items = newItems
            schedulesByClip = Dictionary(grouping: newSchedules, by: \.clipId)
        } catch is CancellationError {
            // A superseded load — e.g. pull-to-refresh interrupted, or a newer
            // navigation started before this finished. Not a real failure, and
            // surfacing it pops a "Swift.CancellationError" alert; keep state.
        } catch let error as URLError where error.code == .cancelled {
            // Same thing when the cancellation comes up from the network layer.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Loads only if nothing has been loaded yet this session. For the view's
    /// initial `.task`, so a pane being hidden and re-shown (or any other
    /// remount) doesn't pay for a network refetch of data already in memory.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    /// The lifecycle tag a clip shows in the library: its transfer state
    /// merged with what its schedules say (scheduled / posted).
    public func displayStatus(for clip: Clip) -> ClipDisplayStatus {
        .derive(clip: clip, schedules: schedulesByClip[clip.id] ?? [])
    }

    public func open(_ folder: Folder) async {
        go(to: path + [folder])
        await load()
    }

    /// Points the shared session state at `breadcrumb` (its last folder, or root
    /// when empty) and reloads. The iOS browser is a native NavigationStack where
    /// each level loads its own clips — so parents keep their contents during the
    /// interactive back-swipe — and this keeps the shared model (uploads, status
    /// badges, move destinations, realtime) in step with the folder on screen.
    /// Unlike `navigate`/`open`, it sets the path outright without touching the
    /// browser-style history, which the iOS stack doesn't use.
    public func focus(on breadcrumb: [Folder]) async {
        path = breadcrumb
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

/// A folder presented as a "Move to" destination: the folder plus its nesting
/// depth and full path from the root, so destinations across the whole org are
/// distinguishable in a flat menu.
public struct FolderDestination: Identifiable, Sendable, Hashable {
    public let folder: Folder
    public let depth: Int
    public let path: String
    public var id: UUID { folder.id }
    public var name: String { folder.name }
}
