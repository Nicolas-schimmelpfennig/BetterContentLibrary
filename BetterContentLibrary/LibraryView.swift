//
//  LibraryView.swift
//  BetterContentLibrary
//

import SwiftUI
import AppKit
import AVKit
import BetterContentCore

/// Frame.io-style library: a breadcrumb path, a grid of folders and clips,
/// folder creation, and drag-a-clip-onto-a-folder to move it.
struct LibraryView: View {
    let model: AppModel

    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var previewClip: Clip?

    private var library: LibraryModel { model.library }
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            content
        }
        .navigationTitle(library.currentFolder?.name ?? "Library")
        .toolbar {
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
        .task { await library.load() }
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
    }

    // MARK: Breadcrumb

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            crumb(title: "Library", folder: nil)
            ForEach(library.path) { folder in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                crumb(title: folder.name, folder: folder)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func crumb(title: String, folder: Folder?) -> some View {
        Button(title) { Task { await library.navigate(to: folder) } }
            .buttonStyle(.plain)
            .fontWeight(folder == library.currentFolder ? .semibold : .regular)
            .foregroundStyle(folder == library.currentFolder ? .primary : .secondary)
            // Dropping a clip on a crumb moves it into that folder (or root).
            .dropDestination(for: String.self) { ids, _ in
                moveClips(ids, to: folder?.id); return true
            }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if library.subfolders.isEmpty && library.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.subfolders) { folder in
                        FolderTile(folder: folder)
                            .onTapGesture(count: 2) { Task { await library.open(folder) } }
                            .dropDestination(for: String.self) { ids, _ in
                                moveClips(ids, to: folder.id); return true
                            }
                            .contextMenu {
                                Button("Open") { Task { await library.open(folder) } }
                                Button("Delete", role: .destructive) {
                                    Task { await library.deleteFolder(folder) }
                                }
                            }
                    }
                    ForEach(library.items) { clip in
                        ClipCard(
                            clip: clip,
                            progress: model.uploadProgress[clip.id],
                            loader: model.thumbnails,
                            skim: model.skim
                        )
                        .draggable(clip.id.uuidString)
                        .onTapGesture(count: 2) { openPreview(clip) }
                        .contextMenu {
                            Button("Preview") { openPreview(clip) }
                                .disabled(!clip.isPlayable)
                            moveMenu(for: clip)
                        }
                    }
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func moveMenu(for clip: Clip) -> some View {
        Menu("Move to") {
            Button("Library (root)") { Task { await library.move(clipId: clip.id, to: nil) } }
            if !library.subfolders.isEmpty {
                Divider()
                ForEach(library.subfolders) { folder in
                    Button(folder.name) { Task { await library.move(clipId: clip.id, to: folder.id) } }
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

    private func moveClips(_ ids: [String], to folderId: UUID?) {
        for id in ids {
            if let uuid = UUID(uuidString: id) {
                Task { await library.move(clipId: uuid, to: folderId) }
            }
        }
    }

    private func openPreview(_ clip: Clip) {
        guard clip.isPlayable else { return }
        previewClip = clip
    }
}

private extension Clip {
    /// A playable clip has finished uploading, so its video exists in R2.
    var isPlayable: Bool { status != .ingesting && status != .uploading }
}

// MARK: - Tiles

private struct FolderTile: View {
    let folder: Folder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(
                    Image(systemName: "folder.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                )
            Text(folder.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text("Folder").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}

private struct ClipCard: View {
    let clip: Clip
    let progress: Double?
    let loader: ThumbnailLoader
    let skim: SkimProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClipThumbnail(clip: clip, loader: loader, skim: skim, skimEnabled: clip.isPlayable)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressView(value: progress)
                            .padding(.horizontal, 8).padding(.bottom, 8)
                    }
                }

            Text(clip.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            HStack(spacing: 6) {
                StatusBadge(status: clip.status)
                if let duration = clip.durationS {
                    Text(Self.durationText(duration))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Poster thumbnail that hover-scrubs (skims) through the video, with a playhead.
private struct ClipThumbnail: View {
    let clip: Clip
    let loader: ThumbnailLoader
    let skim: SkimProvider
    let skimEnabled: Bool

    @State private var poster: NSImage?
    @State private var skimImage: NSImage?
    @State private var hoverFraction: Double?
    @State private var width: CGFloat = 0

    private var displayImage: NSImage? { skimImage ?? poster }

    private var skimKey: Int? {
        guard skimEnabled, let fraction = hoverFraction, (clip.durationS ?? 0) > 0 else { return nil }
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
                    .font(.system(size: 28))
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
            guard skimEnabled, width > 0 else { return }
            switch phase {
            case .active(let location):
                hoverFraction = min(max(location.x / width, 0), 1)
            case .ended:
                hoverFraction = nil
                skimImage = nil
            }
        }
        .task(id: clip.id) { poster = await loader.image(for: clip) }
        // Keep the previous skim frame on a nil result to avoid flashing the poster.
        .task(id: skimKey) {
            guard let key = skimKey else { return }
            if let frame = await skim.frame(for: clip, key: key) { skimImage = frame }
        }
    }

    @ViewBuilder
    private var playhead: some View {
        if skimEnabled, let fraction = hoverFraction, width > 0 {
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

struct StatusBadge: View {
    let status: ClipStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
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
