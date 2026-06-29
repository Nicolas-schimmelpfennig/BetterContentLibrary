//
//  LibraryView.swift
//  BetterContentLibrary
//
//  The library browser. Ported from VideoTag's ClipBrowserView / ClipGridView:
//  a thumbnail grid with hover-skimming and Finder-style selection, plus a
//  native NSTableView list, driven by a shared BrowserKeyController. Added for
//  BetterContentLibrary: folders, a breadcrumb path bar, and drag/menu move.
//

import SwiftUI
import AppKit
import AVKit
import BetterContentCore

enum LibraryViewMode: String { case icon, list }

/// Collapses the browser's key-controller wiring into one modifier (keeps
/// `body` a single short expression the type-checker can handle quickly).
private struct BrowserKeyWiring: ViewModifier {
    let controller: BrowserKeyController
    let isGrid: Bool
    let isPreviewing: Bool
    let onArrow: () -> Void
    let onSelectAll: () -> Void
    let onSpace: () -> Void

    func body(content: Content) -> some View {
        content
            .browserKeys(controller)
            .onAppear { controller.isGridMode = isGrid }
            .onChange(of: isGrid) { _, new in controller.isGridMode = new }
            .onChange(of: isPreviewing) { _, new in controller.isPreviewing = new }
            .onChange(of: controller.arrowTick) { onArrow() }
            .onChange(of: controller.selectAllTick) { onSelectAll() }
            .onChange(of: controller.spaceTick) { onSpace() }
    }
}

struct LibraryView: View {
    let model: AppModel

    @AppStorage("libraryViewMode") private var viewMode: LibraryViewMode = .icon
    @AppStorage("librarySortKey") private var sortKeyRaw = LibrarySortKey.dateAdded.rawValue
    @AppStorage("librarySortAsc") private var sortAscending = false

    @State private var selection: Set<String> = []
    @State private var anchorID: String?
    @State private var columnCount = 1
    @State private var lastClickID: String?
    @State private var lastClickTime = Date.distantPast

    @State private var renamingID: String?
    @State private var renameText = ""
    @FocusState private var renameFieldFocused: Bool

    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var previewClip: Clip?

    @State private var pendingDeletion: [Clip] = []
    @State private var isConfirmingDelete = false

    @StateObject private var keyController = BrowserKeyController()

    private var library: LibraryModel { model.library }
    private let spacing: CGFloat = 16
    private let targetItemWidth: CGFloat = 240

    // MARK: Sorted, folders-first items

    private var sortKey: LibrarySortKey { LibrarySortKey(rawValue: sortKeyRaw) ?? .dateAdded }

    private var comparators: [KeyPathComparator<LibraryEntry>] {
        [sortKey.comparator(order: sortAscending ? .forward : .reverse)]
    }

    /// Folders first (sorted among themselves), then clips — Finder's
    /// "keep folders on top", regardless of the chosen sort.
    private var items: [LibraryEntry] {
        let folders = library.subfolders.map(LibraryEntry.folder).sorted(using: comparators)
        let clips = library.items.map(LibraryEntry.clip).sorted(using: comparators)
        return folders + clips
    }

    var body: some View {
        shell.modifier(BrowserKeyWiring(
            controller: keyController,
            isGrid: viewMode == .icon,
            isPreviewing: previewClip != nil,
            onArrow: moveSelectionForArrow,
            onSelectAll: selectAll,
            onSpace: previewPrimary
        ))
    }

    private var shell: some View {
        VStack(spacing: 0) {
            content
            Divider()
            pathBar
        }
        .navigationTitle(library.currentFolder?.name ?? "Library")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .task { await library.load() }
        // Fill in any missing posters once the current folder's clips are loaded
        // (covers the initial load and every folder navigation).
        .onChange(of: library.items) { Task { await model.backfillMissingThumbnails() } }
        .sheet(item: $previewClip) { clip in
            ClipPreviewView(clip: clip, model: model)
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
        .confirmationDialog(deletePrompt, isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let clips = pendingDeletion
                pendingDeletion = []
                selection.removeAll(); anchorID = nil
                Task { await model.deleteClips(clips) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("This permanently removes the video\(pendingDeletion.count == 1 ? "" : "s") from the library and storage. This can't be undone.")
        }
    }

    private var deletePrompt: String {
        if pendingDeletion.count == 1 {
            return "Delete “\(pendingDeletion.first?.title ?? "")”?"
        }
        return "Delete \(pendingDeletion.count) videos?"
    }

    private var subtitle: String {
        let folders = library.subfolders.count
        let clips = library.items.count
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        parts.append("\(clips) item\(clips == 1 ? "" : "s")")
        if !selection.isEmpty { parts.append("\(selection.count) selected") }
        return parts.joined(separator: ", ")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button { navigateHistory(library.goBack) } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!library.canGoBack)
                .help("Back")
                .keyboardShortcut("[", modifiers: .command)

                Button { navigateHistory(library.goForward) } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!library.canGoForward)
                .help("Forward")
                .keyboardShortcut("]", modifiers: .command)
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItem {
            Picker("View", selection: $viewMode) {
                Image(systemName: "square.grid.2x2").tag(LibraryViewMode.icon)
                Image(systemName: "list.bullet").tag(LibraryViewMode.list)
            }
            .pickerStyle(.segmented)
            .help("Switch between icon and list views")
        }
        ToolbarItem {
            Menu {
                Picker("Sort By", selection: sortKeyBinding) {
                    ForEach(LibrarySortKey.menuCases) { key in
                        Text(key.label).tag(key)
                    }
                }
                Divider()
                Picker("Order", selection: $sortAscending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort items")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { isCreatingFolder = true } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New Folder")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await library.load() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(library.isLoading)
            .help("Refresh")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            emptyState
        } else {
            switch viewMode {
            case .icon: gridView
            case .list: listView
            }
        }
    }

    // MARK: Grid (ported from VideoTag's ClipGridView)

    private var gridView: some View {
        GeometryReader { geo in
            let cols = columnCount(for: geo.size.width)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(minimum: 160, maximum: 320), spacing: spacing),
                            count: cols
                        ),
                        spacing: spacing
                    ) {
                        ForEach(items) { item in
                            gridCell(item).id(item.id)
                        }
                    }
                    .padding()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    keyController.detailHasFocus = true
                    cancelRename()
                    selection = []
                    anchorID = nil
                }
                .onChange(of: anchorID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .onAppear { columnCount = cols }
            .onChange(of: cols) { _, new in columnCount = new }
        }
    }

    @ViewBuilder
    private func gridCell(_ item: LibraryEntry) -> some View {
        let cell = GridCell(
            item: item,
            isSelected: selection.contains(item.id),
            isRenaming: renamingID == item.id,
            progress: item.clip.flatMap { model.uploadProgress[$0.id] },
            isRegenerating: item.clip.map { model.regenerating.contains($0.id) } ?? false,
            renameText: $renameText,
            fieldFocused: $renameFieldFocused,
            loader: model.thumbnails,
            skim: model.skim,
            commitRename: commitRename,
            cancelRename: cancelRename
        )
        .onTapGesture { handleTap(on: item) }
        .contextMenu { contextMenu(for: item) }

        switch item {
        case .folder(let folder):
            cell.dropDestination(for: String.self) { ids, _ in
                moveDropped(ids, to: folder.id); return true
            }
        case .clip(let clip):
            cell.draggable(clip.id.uuidString)
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        let usable = max(width - 2 * spacing, targetItemWidth)
        return max(1, Int((usable + spacing) / (targetItemWidth + spacing)))
    }

    // MARK: List (NSTableView)

    private var listView: some View {
        LibraryTableView(
            items: items,
            subfolders: library.subfolders,
            regenerating: model.regenerating,
            selection: $selection,
            sortOrder: sortOrderBinding,
            onOpen: open,
            onRename: { item, name in commitRename(item: item, newName: name) },
            onMove: moveDropped,
            onPreview: { previewClip = $0 },
            onRegenerate: { clips in Task { await model.regenerateThumbnails(for: clips) } },
            onDeleteFolder: { folder in Task { await library.deleteFolder(folder) } },
            onDeleteClips: { clips in requestDelete(clips) }
        )
    }

    private var sortOrderBinding: Binding<[KeyPathComparator<LibraryEntry>]> {
        Binding {
            comparators
        } set: { newValue in
            guard let first = newValue.first else { return }
            sortKeyRaw = LibrarySortKey(keyPath: first.keyPath).rawValue
            sortAscending = (first.order == .forward)
        }
    }

    // MARK: Path bar (bottom, Finder-style)

    private var pathBar: some View {
        HStack(spacing: 4) {
            crumb(title: "Library", folder: nil)
            ForEach(library.path) { folder in
                Image(systemName: "chevron.compact.right")
                    .font(.caption2).foregroundStyle(.tertiary)
                crumb(title: folder.name, folder: folder)
            }
            Spacer()
            if library.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    private func crumb(title: String, folder: Folder?) -> some View {
        Button {
            cancelRename()
            selection.removeAll(); anchorID = nil
            Task { await library.navigate(to: folder) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: folder == nil ? "house" : "folder").imageScale(.small)
                Text(title)
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(folder == library.currentFolder ? .primary : .secondary)
        .dropDestination(for: String.self) { ids, _ in
            moveDropped(ids, to: folder?.id); return true
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for item: LibraryEntry) -> some View {
        switch item {
        case .folder(let folder):
            Button("Open") { open(item) }
            Button("Rename") { beginRename(item) }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await library.deleteFolder(folder) }
            }
        case .clip(let clip):
            Button("Preview") { previewClip = clip }
                .disabled(!clip.isPlayable)
            Button("Rename") { beginRename(item) }
            Button(regenerateTitle) {
                let clips = regenerateTargets(for: clip)
                Task { await model.regenerateThumbnails(for: clips) }
            }
            .disabled(!clip.isPlayable || model.regenerating.contains(clip.id))
            Divider()
            moveMenu(for: clip)
            Divider()
            Button(deleteTitle(for: clip), role: .destructive) {
                requestDelete(deleteTargets(for: clip))
            }
        }
    }

    private var regenerateTitle: String {
        selectedClips.count > 1 ? "Regenerate \(selectedClips.count) Thumbnails" : "Regenerate Thumbnail"
    }

    private func regenerateTargets(for clip: Clip) -> [Clip] {
        selectedClips.contains(where: { $0.id == clip.id }) ? selectedClips : [clip]
    }

    @ViewBuilder
    private func moveMenu(for clip: Clip) -> some View {
        Menu("Move to") {
            Button("Library (root)") { moveDropped([clip.id.uuidString], to: nil) }
            if !library.subfolders.isEmpty {
                Divider()
                ForEach(library.subfolders) { folder in
                    Button(folder.name) { moveDropped([clip.id.uuidString], to: folder.id) }
                }
            }
        }
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

    // MARK: Selection & actions (ported from VideoTag's ClipGridView)

    private var selectedClips: [Clip] {
        items.compactMap(\.clip).filter { selection.contains("clip-\($0.id.uuidString)") }
    }

    private var primaryID: String? {
        if let anchorID, selection.contains(anchorID) { return anchorID }
        return items.first { selection.contains($0.id) }?.id
    }

    private func handleTap(on item: LibraryEntry) {
        keyController.detailHasFocus = true
        guard renamingID == nil else { return }
        let id = item.id
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchorID = id
            lastClickID = nil
            return
        }
        if modifiers.contains(.shift) {
            extendSelection(to: id)
            lastClickID = nil
            return
        }

        // Plain click: double-click opens; otherwise select only this item.
        let now = Date()
        if lastClickID == id, now.timeIntervalSince(lastClickTime) < NSEvent.doubleClickInterval {
            open(item)
        } else {
            selection = [id]
            anchorID = id
        }
        lastClickID = id
        lastClickTime = now
    }

    private func extendSelection(to id: String) {
        guard let anchor = anchorID,
              let a = items.firstIndex(where: { $0.id == anchor }),
              let b = items.firstIndex(where: { $0.id == id }) else {
            selection = [id]; anchorID = id; return
        }
        let range = a <= b ? a...b : b...a
        selection = Set(items[range].map(\.id))
    }

    private func selectAll() {
        selection = Set(items.map(\.id))
        anchorID = items.first?.id
    }

    private func open(_ item: LibraryEntry) {
        switch item {
        case .folder(let folder):
            cancelRename()
            selection.removeAll(); anchorID = nil; lastClickID = nil
            Task { await library.open(folder) }
        case .clip(let clip):
            guard clip.isPlayable else { return }
            previewClip = clip
        }
    }

    private func previewPrimary() {
        guard let id = primaryID, let item = items.first(where: { $0.id == id }),
              let clip = item.clip, clip.isPlayable else { return }
        previewClip = clip
    }

    // MARK: History navigation (back/forward)

    private func navigateHistory(_ action: @escaping () async -> Void) {
        cancelRename()
        selection.removeAll(); anchorID = nil; lastClickID = nil
        Task { await action() }
    }

    // MARK: Delete

    /// Clips a delete applies to: the whole clip selection if `clip` is part of
    /// it, otherwise just `clip` (mirrors `regenerateTargets`).
    private func deleteTargets(for clip: Clip) -> [Clip] {
        selectedClips.contains(where: { $0.id == clip.id }) ? selectedClips : [clip]
    }

    private func requestDelete(_ clips: [Clip]) {
        guard !clips.isEmpty else { return }
        pendingDeletion = clips
        isConfirmingDelete = true
    }

    private func deleteTitle(for clip: Clip) -> String {
        let count = deleteTargets(for: clip).count
        return count > 1 ? "Delete \(count) Videos" : "Delete"
    }

    // MARK: Arrow navigation (ported from VideoTag)

    private func moveSelectionForArrow() {
        guard let direction = keyController.pendingDirection, !items.isEmpty else { return }
        guard let current = items.firstIndex(where: { $0.id == primaryID }) else {
            select(only: items.first); return
        }
        let cols = max(1, columnCount)
        let next: Int
        switch direction {
        case .left: next = max(0, current - 1)
        case .right: next = min(items.count - 1, current + 1)
        case .up: next = current - cols >= 0 ? current - cols : current
        case .down: next = current + cols < items.count ? current + cols : current
        }
        select(only: items[next])
    }

    private func select(only item: LibraryEntry?) {
        guard let item else { return }
        selection = [item.id]
        anchorID = item.id
    }

    // MARK: Move

    /// Moves clips into `folderId` (nil = root). `ids` are raw clip UUID strings
    /// (the grid drag payload). If any dragged clip is part of the current
    /// selection, the whole selection moves — Finder-style.
    private func moveDropped(_ ids: [String], to folderId: UUID?) {
        let draggedTokens = Set(ids.map { "clip-\($0)" })
        let rawIDs = draggedTokens.isDisjoint(with: selection)
            ? ids
            : selectedClips.map(\.id.uuidString)
        for raw in rawIDs {
            if let uuid = UUID(uuidString: raw) {
                Task { await library.move(clipId: uuid, to: folderId) }
            }
        }
    }

    // MARK: Rename

    private func beginRename(_ item: LibraryEntry) {
        selection = [item.id]
        anchorID = item.id
        renameText = item.name
        renamingID = item.id
        renameFieldFocused = true
    }

    /// Commit for the inline grid rename field.
    private func commitRename() {
        guard let id = renamingID, let item = items.first(where: { $0.id == id }) else { return }
        commitRename(item: item, newName: renameText)
        renamingID = nil
    }

    /// Commit a rename for a specific item (also used by the list view).
    private func commitRename(item: LibraryEntry, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch item {
        case .folder(let folder):
            if !trimmed.isEmpty, trimmed != folder.name {
                Task { await library.renameFolder(folder.id, to: trimmed) }
            }
        case .clip(let clip):
            if !trimmed.isEmpty, trimmed != clip.title {
                Task { await library.renameClip(clip.id, to: trimmed) }
            }
        }
    }

    private func cancelRename() {
        renamingID = nil
    }

    // MARK: Sort menu <-> comparator bridging

    private var sortKeyBinding: Binding<LibrarySortKey> {
        Binding { sortKey } set: { sortKeyRaw = $0.rawValue }
    }

}

// MARK: - Grid cell (ported from VideoTag's ClipCardView)

private struct GridCell: View {
    let item: LibraryEntry
    let isSelected: Bool
    let isRenaming: Bool
    let progress: Double?
    let isRegenerating: Bool
    @Binding var renameText: String
    var fieldFocused: FocusState<Bool>.Binding
    let loader: ThumbnailLoader
    let skim: SkimProvider
    let commitRename: () -> Void
    let cancelRename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) { durationBadge }
                .overlay(alignment: .bottom) { progressBar }
                .overlay { regenOverlay }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }
            nameRow
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item {
        case .folder:
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                Image(systemName: "folder.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
            }
        case .clip(let clip):
            ClipThumbnail(clip: clip, loader: loader, skim: skim, skimEnabled: clip.isPlayable)
                .opacity(clip.isPlayable ? 1 : 0.5)
        }
    }

    @ViewBuilder
    private var nameRow: some View {
        if isRenaming {
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .focused(fieldFocused)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
        } else {
            HStack(spacing: 5) {
                if let clip = item.clip { statusDot(clip.status) }
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var durationBadge: some View {
        if let duration = item.clip?.durationFormatted {
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
        if let progress {
            ProgressView(value: progress)
                .padding(.horizontal, 8).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var regenOverlay: some View {
        if isRegenerating {
            ZStack {
                Color.black.opacity(0.4)
                ProgressView().controlSize(.small).tint(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func statusDot(_ status: ClipStatus) -> some View {
        Circle()
            .fill(Self.color(for: status))
            .frame(width: 7, height: 7)
            .help(status.rawValue.capitalized)
    }

    private static func color(for status: ClipStatus) -> Color {
        switch status {
        case .ingesting: return .orange
        case .uploading: return .blue
        case .ready: return .green
        case .scheduled: return .purple
        case .downloaded: return .teal
        case .posted: return .gray
        }
    }
}

// MARK: - Skimming thumbnail (ported from VideoTag's ClipThumbnailView)

/// Poster thumbnail that hover-scrubs (skims) through the video, with a playhead.
private struct ClipThumbnail: View {
    let clip: Clip
    let loader: ThumbnailLoader
    let skim: SkimProvider
    let skimEnabled: Bool

    @AppStorage(SettingsKey.videoSkimming) private var skimmingEnabled = true

    @State private var poster: NSImage?
    @State private var skimImage: NSImage?
    @State private var hoverFraction: Double?
    @State private var width: CGFloat = 0

    /// Honors both the per-clip gate (playable) and the global Settings toggle.
    private var canSkim: Bool { skimEnabled && skimmingEnabled }

    private var displayImage: NSImage? { skimImage ?? poster }

    private var skimKey: Int? {
        guard canSkim, let fraction = hoverFraction, (clip.durationS ?? 0) > 0 else { return nil }
        return SkimProvider.key(for: fraction)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let displayImage {
                Image(nsImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: orientationIcon)
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in width = new }
            }
        }
        .overlay(alignment: .leading) { playhead }
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard canSkim, width > 0 else { return }
            switch phase {
            case .active(let location):
                hoverFraction = min(max(location.x / width, 0), 1)
            case .ended:
                hoverFraction = nil
                skimImage = nil
            }
        }
        // Re-load the poster whenever the clip changes — including after a
        // thumbnail is regenerated, which bumps `updatedAt`.
        .task(id: clip.updatedAt) { poster = await loader.image(for: clip) }
        // Keep the previous skim frame on a nil result to avoid flashing the poster.
        .task(id: skimKey) {
            guard let key = skimKey else { return }
            if let frame = await skim.frame(for: clip, key: key) { skimImage = frame }
        }
    }

    @ViewBuilder
    private var playhead: some View {
        if canSkim, let fraction = hoverFraction, width > 0 {
            Rectangle()
                .fill(.white)
                .frame(width: 1.5)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .offset(x: fraction * (width - 1.5))
        }
    }

    private var orientationIcon: String {
        switch clip.orientation {
        case .vertical: return "rectangle.portrait"
        case .horizontal: return "rectangle"
        case .square: return "square"
        case nil: return "film"
        }
    }
}

// MARK: - Full-size preview

/// Full-size video preview backed by a presigned R2 stream URL.
private struct ClipPreviewView: View {
    let clip: Clip
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(clip.title).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if failed {
                    Label("Couldn't load video", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: 760, height: 760 * 9 / 16)
        }
        .task {
            if let url = await model.streamURL(for: clip) {
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            } else {
                failed = true
            }
        }
        .onDisappear { player?.pause() }
    }
}
