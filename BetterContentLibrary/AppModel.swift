//
//  AppModel.swift
//  BetterContentLibrary
//

import AppKit
import Foundation
import Observation
import BetterContentCore

/// Folder-aware library state: the current folder path (breadcrumb), the
/// subfolders and clips within it, with create/move/delete.
@MainActor
@Observable
final class LibraryModel {
    private let clips: ClipsService
    private let folders: FoldersService
    let orgId: UUID

    /// Breadcrumb from root; the last element is the current folder (empty = root).
    private(set) var path: [Folder] = []
    private(set) var subfolders: [Folder] = []
    private(set) var items: [Clip] = []
    private(set) var isLoading = false
    var errorMessage: String?

    var currentFolder: Folder? { path.last }

    init(orgId: UUID, clips: ClipsService = ClipsService(), folders: FoldersService = FoldersService()) {
        self.orgId = orgId
        self.clips = clips
        self.folders = folders
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let subs = folders.list(parent: currentFolder?.id)
            async let cl = clips.list(inFolder: currentFolder?.id)
            subfolders = try await subs
            items = try await cl
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ folder: Folder) async {
        path.append(folder)
        await load()
    }

    /// Jumps to a folder already in the breadcrumb (or root if nil).
    func navigate(to folder: Folder?) async {
        if let folder, let index = path.firstIndex(of: folder) {
            path = Array(path.prefix(index + 1))
        } else {
            path.removeAll()
        }
        await load()
    }

    func createFolder(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await folders.create(name: trimmed, orgId: orgId, parentId: currentFolder?.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func move(clipId: UUID, to folderId: UUID?) async {
        do {
            try await clips.setFolder(clipId, folderId: folderId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteFolder(_ folder: Folder) async {
        do {
            try await folders.delete(folder.id)
            if currentFolder == folder { await navigate(to: path.dropLast().last) }
            else { await load() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Loads and caches clip thumbnails from R2 (memory + on-disk JPEG cache),
/// adapted from VideoTag's ThumbnailStore.
@MainActor
final class ThumbnailLoader {
    private let storage: StorageService
    private let cache = NSCache<NSString, NSImage>()
    private let directory: URL

    init(storage: StorageService = StorageService()) {
        self.storage = storage
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = base.appending(components: "BetterContentLibrary", "Thumbnails")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for clip: Clip) async -> NSImage? {
        guard clip.thumbKey != nil else { return nil }
        let key = clip.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let fileURL = directory.appending(component: "\(clip.id.uuidString).jpg")
        if let data = try? Data(contentsOf: fileURL), let image = NSImage(data: data) {
            cache.setObject(image, forKey: key)
            return image
        }

        guard let data = try? await storage.downloadThumbnail(clipId: clip.id),
              let image = NSImage(data: data) else { return nil }
        try? data.write(to: fileURL)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Session-scoped state for a signed-in user.
@MainActor
@Observable
final class AppModel {
    let profile: Profile
    let library: LibraryModel
    let schedule: ScheduleModel
    let thumbnails = ThumbnailLoader()
    let skim = SkimProvider()

    /// Live upload progress (0...1) keyed by clip id.
    private(set) var uploadProgress: [UUID: Double] = [:]

    private let storage = StorageService()
    private let uploader = ClipUploader()
    private var eventTask: Task<Void, Never>?
    private var pendingFiles: [UUID: URL] = [:]

    private let pendingDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("BetterContentLibrary/PendingUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(profile: Profile) {
        self.profile = profile
        self.library = LibraryModel(orgId: profile.orgId)
        self.schedule = ScheduleModel(orgId: profile.orgId)
        observeUploads()
    }

    func importFile(_ source: URL) async throws -> ClipDraft {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let dest = pendingDir.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: dest)
        return try await uploader.makeDraft(from: dest)
    }

    /// Confirms a draft and starts the background upload, landing it in whatever
    /// folder the library is currently viewing.
    func upload(_ draft: ClipDraft) async {
        do {
            let clip = try await uploader.upload(
                draft,
                orgId: profile.orgId,
                uploadedBy: profile.id,
                folderId: library.currentFolder?.id
            )
            pendingFiles[clip.id] = draft.fileURL
            uploadProgress[clip.id] = 0
            await library.load()
        } catch {
            library.errorMessage = error.localizedDescription
        }
    }

    func discard(_ draft: ClipDraft) {
        try? FileManager.default.removeItem(at: draft.fileURL)
    }

    /// A short-lived presigned URL for streaming a clip's video (preview).
    func streamURL(for clip: Clip) async -> URL? {
        try? await storage.streamURL(clipId: clip.id)
    }

    private func observeUploads() {
        eventTask = Task { [weak self] in
            guard let uploader = self?.uploader else { return }
            for await event in uploader.events() {
                guard let self else { return }
                switch event {
                case let .progress(clipId, fraction):
                    uploadProgress[clipId] = fraction
                case let .finished(clipId, _):
                    uploadProgress[clipId] = nil
                    cleanUpPendingFile(clipId)
                    await library.load()
                case let .failed(clipId, message):
                    uploadProgress[clipId] = nil
                    cleanUpPendingFile(clipId)
                    library.errorMessage = message
                }
            }
        }
    }

    private func cleanUpPendingFile(_ clipId: UUID) {
        if let url = pendingFiles.removeValue(forKey: clipId) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
