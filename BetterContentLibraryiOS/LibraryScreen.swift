//
//  LibraryScreen.swift
//  BetterContentLibrary (iOS)
//
//  The library browser: a native NavigationStack that pushes one screen per
//  folder — so iOS owns the interactive back-swipe and the animated pop, exactly
//  like Files.app. Each level (`FolderLevelView`) loads its own folders + clips,
//  so a parent keeps its contents on screen while you swipe back to it. Grid or
//  list, sort, thumbnails (with drag-skim), preview, rename, move, delete, and
//  regenerate — driven by the shared `AppModel`/`LibraryModel`.
//

import SwiftUI
import BetterContentCore

private enum LibraryLayout: String { case grid, list }

struct LibraryScreen: View {
    let model: AppModel

    /// The pushed folders, root → current. Empty = library root. Driving the
    /// NavigationStack with this is what gives us the native push/pop + swipe.
    @State private var path: [Folder] = []

    var body: some View {
        NavigationStack(path: $path) {
            FolderLevelView(folder: nil, model: model, path: $path)
                .navigationDestination(for: Folder.self) { folder in
                    FolderLevelView(folder: folder, model: model, path: $path)
                }
        }
    }
}

// MARK: - One folder level

/// A single level of the browser: the contents of `folder` (nil = root). It owns
/// its own `subfolders`/`clips` so that, mid back-swipe, the revealed parent
/// shows *its* contents rather than the child's. Cross-cutting state that's
/// genuinely session-wide — status badges (from org schedules), move
/// destinations, upload targeting, realtime — still lives on the shared model,
/// which `activate()` keeps pointed at whichever level is on top.
private struct FolderLevelView: View {
    let folder: Folder?
    let model: AppModel
    @Binding var path: [Folder]

    @AppStorage("libraryLayoutiOS") private var layoutRaw = LibraryLayout.grid.rawValue
    @AppStorage("librarySortKey") private var sortKeyRaw = LibrarySortKey.dateAdded.rawValue
    @AppStorage("librarySortAsc") private var sortAscending = false

    // This level's own contents.
    @State private var subfolders: [Folder] = []
    @State private var clips: [Clip] = []
    @State private var isLoading = false
    @State private var hasLoaded = false

    @State private var previewClip: Clip?
    @State private var renamingEntry: LibraryEntry?
    @State private var renameText = ""
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var pendingClipDeletion: [Clip] = []
    @State private var isConfirmingClipDelete = false
    @State private var pendingFolderDeletion: Folder?

    /// Narrows this level to clips whose status tag matches (session-scoped).
    @State private var statusFilter: ClipDisplayStatus?

    private let folders = FoldersService()
    private let clipsService = ClipsService()

    private var library: LibraryModel { model.library }
    private var layout: LibraryLayout { LibraryLayout(rawValue: layoutRaw) ?? .grid }
    private var sortKey: LibrarySortKey { LibrarySortKey(rawValue: sortKeyRaw) ?? .dateAdded }

    /// This level is the one on top of the stack (root counts when nothing is
    /// pushed). Only the top level drives the shared model and shows alerts.
    private var isActive: Bool { folder == path.last }

    /// Folders first (sorted among themselves), then clips — like the Mac app.
    /// A status filter narrows the clips; folders stay visible for navigation.
    private var entries: [LibraryEntry] {
        let comparator = sortKey.comparator(order: sortAscending ? .forward : .reverse)
        let folderEntries = subfolders.map(LibraryEntry.folder).sorted(using: comparator)
        var clipItems = clips
        if let statusFilter {
            clipItems = clipItems.filter { library.displayStatus(for: $0) == statusFilter }
        }
        let clipEntries = clipItems.map(LibraryEntry.clip).sorted(using: comparator)
        return folderEntries + clipEntries
    }

    var body: some View {
        content
            .navigationTitle(folder?.name ?? "Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .task { await loadIfNeeded() }
            // Whenever this level becomes the top one (push, or a pop back to it),
            // point the shared model here so uploads, status, and move targets track it.
            .task(id: isActive) { if isActive { await activate() } }
            // Realtime/other-device changes reload the shared model; mirror that
            // into this level's own lists (and backfill any missing posters).
            .onChange(of: library.items) {
                guard isActive else { return }
                Task { await load(); await model.backfillMissingThumbnails() }
            }
            .refreshable { await load() }
            .fullScreenCover(item: $previewClip) { ClipPreviewView(clip: $0, model: model) }
            // Upload/limit outcomes land in library.errorMessage (refused uploads,
            // auto-removed clips, failed deletes) — surface them on the top level only.
            .alert("Library", isPresented: libraryMessageBinding) {
                Button("OK") { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "")
            }
            .alert("Rename", isPresented: renameAlertBinding) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renamingEntry = nil }
                Button("Save") { commitRename() }
            }
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Name", text: $newFolderName)
                Button("Cancel", role: .cancel) { newFolderName = "" }
                Button("Create") {
                    let name = newFolderName
                    newFolderName = ""
                    Task { await library.createFolder(named: name); await load() }
                }
            }
            .confirmationDialog(clipDeletePrompt, isPresented: $isConfirmingClipDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    let clipsToDelete = pendingClipDeletion
                    pendingClipDeletion = []
                    Task { await model.deleteClips(clipsToDelete); await load() }
                }
                Button("Cancel", role: .cancel) { pendingClipDeletion = [] }
            } message: {
                Text("This permanently removes the video\(pendingClipDeletion.count == 1 ? "" : "s") from the library and storage. This can't be undone.")
            }
            .confirmationDialog(folderDeletePrompt, isPresented: folderDeleteBinding, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let folder = pendingFolderDeletion {
                        Task { await library.deleteFolder(folder); await load() }
                    }
                    pendingFolderDeletion = nil
                }
                Button("Cancel", role: .cancel) { pendingFolderDeletion = nil }
            } message: {
                Text("Clips inside move back to the library root. Subfolders are deleted.")
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !entries.isEmpty {
            switch layout {
            case .grid: gridView
            case .list: listView
            }
        } else if isLoading || !hasLoaded {
            // Empty while (or before) loading means a cold load or a folder still
            // resolving — show a spinner rather than flashing the empty state.
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 12)],
                spacing: 16
            ) {
                ForEach(entries) { entry in
                    cell(for: entry)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func cell(for entry: LibraryEntry) -> some View {
        let base = LibraryGridCell(entry: entry, model: model)
            .contentShape(Rectangle())
            .onTapGesture { open(entry) }
            .contextMenu { contextMenu(for: entry) }

        switch entry {
        case .folder(let folder):
            base.dropDestination(for: String.self) { ids, _ in
                moveDropped(ids, to: folder.id); return true
            }
        case .clip(let clip):
            base.draggable(clip.id.uuidString)
        }
    }

    private var listView: some View {
        List {
            ForEach(entries) { entry in
                LibraryRow(entry: entry, model: model)
                    .contentShape(Rectangle())
                    .onTapGesture { open(entry) }
                    .contextMenu { contextMenu(for: entry) }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { requestDelete(entry) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button { beginRename(entry) } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "square.grid.2x2")
        } description: {
            Text("Upload a video, or create a folder to organize your clips.")
        } actions: {
            Button("New Folder") { isCreatingFolder = true }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // No back/forward buttons: the NavigationStack supplies the native back
        // button (and the left-edge swipe) automatically.
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Layout", selection: layoutBinding) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                    Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
                }
                Divider()
                Picker("Sort By", selection: sortKeyBinding) {
                    ForEach(LibrarySortKey.menuCases) { Text($0.label).tag($0) }
                }
                Picker("Order", selection: $sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                Divider()
                Menu {
                    Picker("Filter by Status", selection: $statusFilter) {
                        Text("All Statuses").tag(ClipDisplayStatus?.none)
                        ForEach(ClipDisplayStatus.libraryFilterCases, id: \.self) { status in
                            Label {
                                Text(status.label)
                            } icon: {
                                Image.statusDot(status.color)
                            }
                            .tag(Optional(status))
                        }
                    }
                } label: {
                    Label("Status", systemImage: statusFilter == nil ? "tag" : "tag.fill")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            Button { isCreatingFolder = true } label: { Image(systemName: "folder.badge.plus") }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry) -> some View {
        switch entry {
        case .folder(let folder):
            Button { open(entry) } label: { Label("Open", systemImage: "folder") }
            Button { beginRename(entry) } label: { Label("Rename", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { pendingFolderDeletion = folder } label: {
                Label("Delete", systemImage: "trash")
            }
        case .clip(let clip):
            Button { previewClip = clip } label: { Label("Preview", systemImage: "play") }
                .disabled(!clip.isPlayable)
            let status = library.displayStatus(for: clip)
            if status == .scheduled || status == .ready {
                Button { Task { await model.markPosted([clip]); await load() } } label: {
                    Label("Mark as Posted", systemImage: "checkmark.circle")
                }
            }
            if status == .posted {
                Button { Task { await model.reopen([clip]); await load() } } label: {
                    Label("Reopen", systemImage: "arrow.uturn.backward.circle")
                }
            }
            Button { beginRename(entry) } label: { Label("Rename", systemImage: "pencil") }
            Button { Task { await model.regenerateThumbnail(for: clip); await load() } } label: {
                Label("Regenerate Thumbnail", systemImage: "arrow.clockwise")
            }
            .disabled(!clip.isPlayable || model.regenerating.contains(clip.id))
            Menu {
                Button("Library (root)") { move(clip, to: nil) }
                let destinations = library.moveDestinations
                if !destinations.isEmpty {
                    Divider()
                    ForEach(destinations) { dest in
                        Button(dest.path) { move(clip, to: dest.folder.id) }
                    }
                }
            } label: {
                Label("Move to", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) { requestDelete(clip) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: Loading

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    /// Loads this level's own folders + clips. Both fetches are awaited before
    /// publishing so the list never renders half-updated.
    private func load() async {
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            async let subs = folders.list(parent: folder?.id)
            async let cl = clipsService.list(inFolder: folder?.id)
            let (newSubfolders, newClips) = try await (subs, cl)
            subfolders = newSubfolders
            clips = newClips
        } catch is CancellationError {
            // Superseded refresh/navigation — not a real failure.
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            library.errorMessage = error.localizedDescription
        }
    }

    /// Runs when this level reaches the top of the stack: sync the shared model
    /// to it (so uploads land here and org-wide status/move data refresh) and
    /// backfill any missing posters.
    private func activate() async {
        await library.focus(on: path)
        await model.backfillMissingThumbnails()
    }

    // MARK: Actions

    private func open(_ entry: LibraryEntry) {
        switch entry {
        case .folder(let folder): path.append(folder)   // native push
        case .clip(let clip): if clip.isPlayable { previewClip = clip }
        }
    }

    private func move(_ clip: Clip, to folderId: UUID?) {
        Task { await library.move(clipId: clip.id, to: folderId); await load() }
    }

    private func moveDropped(_ ids: [String], to folderId: UUID?) {
        let uuids = ids.compactMap(UUID.init)
        guard !uuids.isEmpty else { return }
        Task {
            for id in uuids { await library.move(clipId: id, to: folderId) }
            await load()
        }
    }

    private func requestDelete(_ entry: LibraryEntry) {
        switch entry {
        case .folder(let folder): pendingFolderDeletion = folder
        case .clip(let clip): requestDelete(clip)
        }
    }

    private func requestDelete(_ clip: Clip) {
        pendingClipDeletion = [clip]
        isConfirmingClipDelete = true
    }

    private func beginRename(_ entry: LibraryEntry) {
        renameText = entry.name
        renamingEntry = entry
    }

    private func commitRename() {
        guard let entry = renamingEntry else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingEntry = nil
        guard !trimmed.isEmpty else { return }
        switch entry {
        case .folder(let folder) where trimmed != folder.name:
            Task { await library.renameFolder(folder.id, to: trimmed); await load() }
        case .clip(let clip) where trimmed != clip.title:
            Task { await library.renameClip(clip.id, to: trimmed); await load() }
        default:
            break
        }
    }

    // MARK: Bindings

    private var layoutBinding: Binding<LibraryLayout> {
        Binding { layout } set: { layoutRaw = $0.rawValue }
    }
    private var sortKeyBinding: Binding<LibrarySortKey> {
        Binding { sortKey } set: { sortKeyRaw = $0.rawValue }
    }
    private var renameAlertBinding: Binding<Bool> {
        Binding { renamingEntry != nil } set: { if !$0 { renamingEntry = nil } }
    }
    private var libraryMessageBinding: Binding<Bool> {
        Binding { isActive && library.errorMessage != nil } set: { if !$0 { library.errorMessage = nil } }
    }
    private var folderDeleteBinding: Binding<Bool> {
        Binding { pendingFolderDeletion != nil } set: { if !$0 { pendingFolderDeletion = nil } }
    }
    private var clipDeletePrompt: String {
        pendingClipDeletion.count == 1
            ? "Delete “\(pendingClipDeletion.first?.title ?? "")”?"
            : "Delete \(pendingClipDeletion.count) videos?"
    }
    private var folderDeletePrompt: String {
        "Delete “\(pendingFolderDeletion?.name ?? "")”?"
    }
}

// MARK: - Grid cell

private struct LibraryGridCell: View {
    let entry: LibraryEntry
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) { statusBadge }
                .overlay(alignment: .bottomTrailing) { durationBadge }
                .overlay(alignment: .bottom) { progressBar }
                .overlay { regenOverlay }
            nameRow
        }
    }

    /// The clip's status tag (Uploading / Scheduled / Posted / …) as a small
    /// capsule on the thumbnail, styled like the duration badge.
    @ViewBuilder
    private var statusBadge: some View {
        if let clip = entry.clip {
            let status = model.library.displayStatus(for: clip)
            HStack(spacing: 4) {
                Circle().fill(status.color).frame(width: 6, height: 6)
                Text(status.label)
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.black.opacity(0.65), in: Capsule())
            .foregroundStyle(.white)
            .padding(5)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch entry {
        case .folder:
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: "folder.fill").font(.system(size: 40)).foregroundStyle(.tint)
            }
        case .clip(let clip):
            ClipThumbnailView(clip: clip, loader: model.thumbnails, skim: model.skim, skimEnabled: clip.isPlayable)
                .opacity(clip.isPlayable ? 1 : 0.5)
        }
    }

    private var nameRow: some View {
        Text(entry.name)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var durationBadge: some View {
        if let duration = entry.clip?.durationFormatted {
            Text(duration)
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(5)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let clip = entry.clip, let progress = model.uploadProgress[clip.id] {
            ProgressView(value: progress).padding(.horizontal, 8).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var regenOverlay: some View {
        if let clip = entry.clip, model.regenerating.contains(clip.id) {
            ZStack {
                Color.black.opacity(0.4)
                ProgressView().controlSize(.small).tint(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - List row

private struct LibraryRow: View {
    let entry: LibraryEntry
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 56, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                HStack(spacing: 4) {
                    if let clip = entry.clip {
                        let status = model.library.displayStatus(for: clip)
                        Text(status.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(status.color)
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let clip = entry.clip, model.regenerating.contains(clip.id) {
                ProgressView().controlSize(.small)
            } else if entry.isFolder {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch entry {
        case .folder:
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                Image(systemName: "folder.fill").foregroundStyle(.tint)
            }
        case .clip(let clip):
            ClipThumbnailView(clip: clip, loader: model.thumbnails, skim: model.skim, skimEnabled: false)
        }
    }

    private var subtitle: String {
        switch entry {
        case .folder:
            return "Folder"
        case .clip(let clip):
            return [clip.durationFormatted, clip.resolutionFormatted]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
    }
}
