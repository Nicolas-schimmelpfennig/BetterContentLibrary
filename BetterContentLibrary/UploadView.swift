//
//  UploadView.swift
//  BetterContentLibrary
//
//  Manual ingest (design 1c, drag-and-drop as the hero while the watched
//  folder stays shelved): drop-zone with distinct idle / drag-over / reading /
//  error states, a recent-imports list reusing the library row anatomy, and
//  the draft review sheet.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BetterContentCore

struct UploadView: View {
    let model: AppModel

    @State private var isTargeted = false
    @State private var isPreparing = false
    @State private var queue: [ClipDraft] = []
    @State private var errorMessage: String?
    @State private var isChoosingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dropZone
            recentImports
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BCLTheme.content)
        .navigationTitle("Upload")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isChoosingFile = true
                } label: {
                    Text("Choose File…")
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(isPreparing)
                .help("Choose a video file (⌘O)")
            }
        }
        .task { await model.library.load() }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result { prepare(urls) }
        }
        .sheet(item: bindingToFirstDraft) { draft in
            DraftSheet(
                draft: draft,
                onUpload: { edited in
                    Task { await model.upload(edited) }
                    advance()
                },
                onCancel: {
                    model.discard(draft)
                    advance()
                }
            )
        }
    }

    // MARK: Drop zone (idle · drag-over · reading · error)

    private var dropZone: some View {
        ZStack {
            if isTargeted {
                RoundedRectangle(cornerRadius: BCLTheme.radiusSheet)
                    .fill(BCLTheme.accent.opacity(0.09))
                RoundedRectangle(cornerRadius: BCLTheme.radiusSheet)
                    .strokeBorder(BCLTheme.accent, lineWidth: 2)
                Text("Release to import")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(BCLTheme.accentText)
            } else if isPreparing {
                dashedBorder(BCLTheme.textPrimary.opacity(0.22))
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading file — extracting thumbnail & metadata…")
                        .font(.system(size: 13))
                        .foregroundStyle(BCLTheme.textPrimary.opacity(0.7))
                }
            } else if let errorMessage {
                RoundedRectangle(cornerRadius: BCLTheme.radiusSheet)
                    .fill(BCLTheme.error.opacity(0.06))
                dashedBorder(BCLTheme.error.opacity(0.55))
                VStack(spacing: 3) {
                    Text(errorMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BCLTheme.errorText)
                    Text("Export as MP4, MOV or M4V and try again")
                        .font(.system(size: 11.5))
                        .foregroundStyle(BCLTheme.textSecondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            } else {
                dashedBorder(BCLTheme.textPrimary.opacity(0.22))
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(BCLTheme.textPrimary.opacity(0.4))
                    Text("Drag a video here")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(BCLTheme.textPrimary)
                    Text("MP4, MOV or M4V · goes straight to a draft for review")
                        .font(.system(size: 12))
                        .foregroundStyle(BCLTheme.textLabel)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            prepare(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private func dashedBorder(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: BCLTheme.radiusSheet)
            .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
    }

    // MARK: Recent imports

    private var recentClips: [Clip] {
        Array(model.library.allClips.prefix(5))
    }

    @ViewBuilder
    private var recentImports: some View {
        if !recentClips.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("RECENT IMPORTS")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(BCLTheme.textPrimary.opacity(0.4))

                VStack(spacing: 0) {
                    ForEach(Array(recentClips.enumerated()), id: \.element.id) { index, clip in
                        if index > 0 { BCLTheme.hairline.frame(height: 1) }
                        ImportRow(
                            clip: clip,
                            displayStatus: model.library.displayStatus(for: clip),
                            progress: model.uploadProgress[clip.id],
                            loader: model.thumbnails
                        )
                    }
                }
                .background(Color(hex: 0x1F1F25))
                .clipShape(RoundedRectangle(cornerRadius: BCLTheme.radiusCard))
                .overlay(
                    RoundedRectangle(cornerRadius: BCLTheme.radiusCard)
                        .strokeBorder(BCLTheme.hairline, lineWidth: 1)
                )
            }
        }
    }

    // MARK: Draft queue plumbing

    private var bindingToFirstDraft: Binding<ClipDraft?> {
        Binding(
            get: { queue.first },
            set: { newValue in if newValue == nil { advance() } }
        )
    }

    private func advance() {
        if !queue.isEmpty { queue.removeFirst() }
    }

    private func prepare(_ urls: [URL]) {
        let videoURLs = urls.filter { isVideo($0) }
        guard !videoURLs.isEmpty else {
            if let name = urls.first?.lastPathComponent {
                errorMessage = "“\(name)” isn’t a supported format"
            }
            return
        }
        isPreparing = true
        errorMessage = nil
        Task {
            defer { isPreparing = false }
            for url in videoURLs {
                do {
                    let draft = try await model.importFile(url)
                    queue.append(draft)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }
}

// MARK: - Recent-import row (library list-row anatomy)

private struct ImportRow: View {
    let clip: Clip
    let displayStatus: ClipDisplayStatus
    let progress: Double?
    let loader: ThumbnailLoader

    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            thumbWell
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BCLTheme.textPrimary)
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(BCLTheme.textPrimary.opacity(0.4))
            }
            Spacer(minLength: 8)
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(BCLTheme.accent)
                    .frame(width: 38, alignment: .trailing)
            } else {
                StatusChip(displayStatus, compact: true)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .task(id: clip.updatedAt) { thumb = await loader.image(for: clip) }
    }

    private var thumbWell: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BCLTheme.radiusBadge)
                .fill(BCLTheme.well)
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(2)
            }
        }
        .frame(width: 42, height: 28)
    }

    private var meta: String {
        [
            BCLFormat.duration(clip.durationS),
            BCLFormat.fileSize(clip.fileSize),
            BCLFormat.dimensions(clip)
        ].joined(separator: " · ")
    }
}

// MARK: - Draft sheet (design 1c)

/// Review sheet after a video is read: auto-extracted metadata is read-only
/// mono; only the title is editable (folder comes from the library's current
/// location, tags ship later).
private struct DraftSheet: View {
    @State private var title: String

    private let draft: ClipDraft
    private let onUpload: (ClipDraft) -> Void
    private let onCancel: () -> Void

    init(draft: ClipDraft, onUpload: @escaping (ClipDraft) -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onUpload = onUpload
        self.onCancel = onCancel
        _title = State(initialValue: draft.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("New Clip")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BCLTheme.textPrimary)
                Spacer()
                Text(draft.fileURL.lastPathComponent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(BCLTheme.textPrimary.opacity(0.35))
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            HStack(alignment: .top, spacing: 16) {
                thumbnail
                form
            }
            .padding(18)

            BCLTheme.hairline.frame(height: 1)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(BCLTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(BCLTheme.control, in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
                    .keyboardShortcut(.cancelAction)
                Button {
                    var edited = draft
                    edited.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    onUpload(edited)
                } label: {
                    Text("Upload")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(BCLTheme.accent, in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(width: 520)
        .background(BCLTheme.raised)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BCLTheme.radiusCard)
                .fill(BCLTheme.well)
                .overlay(
                    RoundedRectangle(cornerRadius: BCLTheme.radiusCard)
                        .strokeBorder(BCLTheme.hairline, lineWidth: 1)
                )
            if let data = draft.thumbnailJPEG, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: BCLTheme.radiusBadge))
                    .padding(6)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 28))
                    .foregroundStyle(BCLTheme.textTertiary)
            }
        }
        .frame(width: 150, height: 200)
        .overlay(alignment: .bottomTrailing) {
            Text(BCLFormat.duration(draft.durationS))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: BCLTheme.radiusBadge))
                .padding(6)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TITLE")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(BCLTheme.textLabel)
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(BCLTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
                    .overlay(RoundedRectangle(cornerRadius: BCLTheme.radiusControl).strokeBorder(BCLTheme.border, lineWidth: 1))
            }

            metaGrid
        }
        .frame(maxWidth: .infinity)
    }

    private var metaGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
            metaCell("DURATION", BCLFormat.duration(draft.durationS), mono: true)
            metaCell("SIZE", BCLFormat.fileSize(draft.fileSize), mono: true)
            metaCell("DIMENSIONS", "\(draft.width)×\(draft.height)", mono: true)
            metaCell("ORIENTATION", draft.orientation.rawValue.capitalized, mono: false)
        }
        .padding(11)
        .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(BCLTheme.hairline, lineWidth: 1))
    }

    private func metaCell(_ label: String, _ value: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(BCLTheme.textPrimary.opacity(0.4))
            Text(value)
                .font(.system(size: 11.5, design: mono ? .monospaced : .default))
                .foregroundStyle(BCLTheme.textPrimary)
        }
    }
}
