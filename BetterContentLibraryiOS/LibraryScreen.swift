//
//  LibraryScreen.swift
//  BetterContentLibrary (iOS)
//
//  The library browser: a grid or list of folders + clips with breadcrumb +
//  back/forward navigation, sort, thumbnails (with drag-skim), preview, rename,
//  move, delete, and regenerate — driven by the shared `AppModel`/`LibraryModel`.
//

import SwiftUI
import BetterContentCore

private enum LibraryLayout: String { case grid, list }

struct LibraryScreen: View {
    let model: AppModel

    @AppStorage("libraryLayoutiOS") private var layoutRaw = LibraryLayout.grid.rawValue
    @AppStorage("librarySortKey") private var sortKeyRaw = LibrarySortKey.dateAdded.rawValue
    @AppStorage("librarySortAsc") private var sortAscending = false

    @State private var previewClip: Clip?
    @State private var renamingEntry: LibraryEntry?
    @State private var renameText = ""
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var pendingClipDeletion: [Clip] = []
    @State private var isConfirmingClipDelete = false
    @State private var pendingFolderDeletion: Folder?

    private var library: LibraryModel { model.library }
    private var layout: LibraryLayout { LibraryLayout(rawValue: layoutRaw) ?? .grid }
    private var sortKey: LibrarySortKey { LibrarySortKey(rawValue: sortKeyRaw) ?? .dateAdded }

    /// Folders first (sorted among themselves), then clips — like the Mac app.
    private var entries: [LibraryEntry] {
        let comparator = sortKey.comparator(order: sortAscending ? .forward : .reverse)
        let folders = library.subfolders.map(LibraryEntry.folder).sorted(using: comparator)
        let clips = library.items.map(LibraryEntry.clip).sorted(using: comparator)
        return folders + clips
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(library.currentFolder?.name ?? "Library")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .safeAreaInset(edge: .top, spacing: 0) { breadcrumbBar }
                .task { await library.load() }
                .onChange(of: library.items) { Task { await model.backfillMissingThumbnails() } }
                .refreshable { await library.load() }
                .fullScreenCover(item: $previewClip) { ClipPreviewView(clip: $0, model: model) }
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
                        Task { await library.createFolder(named: name) }
                    }
                }
                .confirmationDialog(clipDeletePrompt, isPresented: $isConfirmingClipDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        let clips = pendingClipDeletion
                        pendingClipDeletion = []
                        Task { await model.deleteClips(clips) }
                    }
                    Button("Cancel", role: .cancel) { pendingClipDeletion = [] }
                } message: {
                    Text("This permanently removes the video\(pendingClipDeletion.count == 1 ? "" : "s") from the library and storage. This can't be undone.")
                }
                .confirmationDialog(folderDeletePrompt, isPresented: folderDeleteBinding, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        if let folder = pendingFolderDeletion { Task { await library.deleteFolder(folder) } }
                        pendingFolderDeletion = nil
                    }
                    Button("Cancel", role: .cancel) { pendingFolderDeletion = nil }
                } message: {
                    Text("Clips inside move back to the library root. Subfolders are deleted.")
                }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            emptyState
        } else {
            switch layout {
            case .grid: gridView
            case .list: listView
            }
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
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { navigate(library.goBack) } label: { Image(systemName: "chevron.backward") }
                .disabled(!library.canGoBack)
            Button { navigate(library.goForward) } label: { Image(systemName: "chevron.forward") }
                .disabled(!library.canGoForward)
        }
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
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            Button { isCreatingFolder = true } label: { Image(systemName: "folder.badge.plus") }
        }
    }

    // MARK: Breadcrumb

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb(title: "Library", folder: nil)
                ForEach(library.path) { folder in
                    Image(systemName: "chevron.compact.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                    crumb(title: folder.name, folder: folder)
                }
                if library.isLoading { ProgressView().controlSize(.mini).padding(.leading, 4) }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func crumb(title: String, folder: Folder?) -> some View {
        Button {
            navigate { await library.navigate(to: folder) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: folder == nil ? "house" : "folder").imageScale(.small)
                Text(title).lineLimit(1)
            }
            .font(.subheadline)
        }
        .buttonStyle(.plain)
        .foregroundStyle(folder == library.currentFolder ? .primary : .secondary)
        .dropDestination(for: String.self) { ids, _ in
            moveDropped(ids, to: folder?.id); return true
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry) -> some View {
        switch entry {
        case .folder(let folder):
            Button { navigate { await library.open(folder) } } label: { Label("Open", systemImage: "folder") }
            Button { beginRename(entry) } label: { Label("Rename", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { pendingFolderDeletion = folder } label: {
                Label("Delete", systemImage: "trash")
            }
        case .clip(let clip):
            Button { previewClip = clip } label: { Label("Preview", systemImage: "play") }
                .disabled(!clip.isPlayable)
            Button { beginRename(entry) } label: { Label("Rename", systemImage: "pencil") }
            Button { Task { await model.regenerateThumbnail(for: clip) } } label: {
                Label("Regenerate Thumbnail", systemImage: "arrow.clockwise")
            }
            .disabled(!clip.isPlayable || model.regenerating.contains(clip.id))
            Menu {
                Button("Library (root)") { Task { await library.move(clipId: clip.id, to: nil) } }
                ForEach(library.subfolders) { folder in
                    Button(folder.name) { Task { await library.move(clipId: clip.id, to: folder.id) } }
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

    // MARK: Actions

    private func open(_ entry: LibraryEntry) {
        switch entry {
        case .folder(let folder): navigate { await library.open(folder) }
        case .clip(let clip): if clip.isPlayable { previewClip = clip }
        }
    }

    /// Runs a navigation action (so callers don't each spell out the Task).
    private func navigate(_ action: @escaping () async -> Void) {
        Task { await action() }
    }

    private func moveDropped(_ ids: [String], to folderId: UUID?) {
        for raw in ids where UUID(uuidString: raw) != nil {
            Task { await library.move(clipId: UUID(uuidString: raw)!, to: folderId) }
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
            Task { await library.renameFolder(folder.id, to: trimmed) }
        case .clip(let clip) where trimmed != clip.title:
            Task { await library.renameClip(clip.id, to: trimmed) }
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
                .overlay(alignment: .bottomTrailing) { durationBadge }
                .overlay(alignment: .bottom) { progressBar }
                .overlay { regenOverlay }
            nameRow
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
        HStack(spacing: 5) {
            if let clip = entry.clip { StatusDot(status: clip.status) }
            Text(entry.name).font(.callout).lineLimit(1).truncationMode(.middle)
        }
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
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
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

// MARK: - Status dot

private struct StatusDot: View {
    let status: ClipStatus

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private var color: Color {
        switch status {
        case .ingesting: return .orange
        case .uploading: return .blue
        case .ready: return .green
        case .failed: return .red
        }
    }
}
