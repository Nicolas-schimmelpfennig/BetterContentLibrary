//
//  UploadScreen.swift
//  BetterContentLibrary (iOS)
//
//  Pick a video from the photo library or Files, review the auto-filled
//  metadata, then upload. Reuses the shared import/upload pipeline; the
//  background uploader continues even if the app is suspended.
//

import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import BetterContentCore

/// A video transferred out of the Photos picker, copied to an app-owned temp
/// file so the shared importer can read it.
private struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(received.file.lastPathComponent)")
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: received.file, to: temp)
            return PickedVideo(url: temp)
        }
    }
}

struct UploadScreen: View {
    let model: AppModel

    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isChoosingFile = false
    @State private var isPreparing = false
    @State private var queue: [ClipDraft] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: isPreparing ? "hourglass" : "tray.and.arrow.up")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(isPreparing ? BCLTheme.accent : BCLTheme.textPrimary.opacity(0.4))
                    .symbolEffect(.pulse, isActive: isPreparing)

                VStack(spacing: 5) {
                    Text(isPreparing ? "Reading video…" : "Add a video")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(BCLTheme.textPrimary)
                    Text("Upload from your photo library or Files.")
                        .font(.system(size: 13))
                        .foregroundStyle(BCLTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    PhotosPicker(selection: $photoItems, matching: .videos, photoLibrary: .shared()) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(BCLTheme.accent, in: RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)

                    Button {
                        isChoosingFile = true
                    } label: {
                        Label("Files", systemImage: "folder")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(BCLTheme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(BCLTheme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .disabled(isPreparing)
                .padding(.horizontal, 40)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(BCLTheme.errorText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()

                Text("Most uploads happen on the Mac — this is the on-the-go fallback.")
                    .font(.system(size: 11))
                    .foregroundStyle(BCLTheme.textPrimary.opacity(0.3))
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
            .background(BCLTheme.well)
            .navigationTitle("Upload")
            .fileImporter(
                isPresented: $isChoosingFile,
                allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result { prepare(fileURLs: urls) }
            }
            .onChange(of: photoItems) { _, items in prepare(photoItems: items) }
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
    }

    // MARK: Queue plumbing

    private var bindingToFirstDraft: Binding<ClipDraft?> {
        Binding(get: { queue.first }, set: { if $0 == nil { advance() } })
    }

    private func advance() {
        if !queue.isEmpty { queue.removeFirst() }
    }

    private func prepare(photoItems items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isPreparing = true
        errorMessage = nil
        Task {
            defer { isPreparing = false; photoItems = [] }
            for item in items {
                do {
                    guard let video = try await item.loadTransferable(type: PickedVideo.self) else { continue }
                    let draft = try await model.importFile(video.url)
                    queue.append(draft)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func prepare(fileURLs urls: [URL]) {
        guard !urls.isEmpty else { return }
        isPreparing = true
        errorMessage = nil
        Task {
            defer { isPreparing = false }
            for url in urls {
                do {
                    let draft = try await model.importFile(url)
                    queue.append(draft)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Draft review sheet

/// Compact confirm (design 1n): thumbnail + editable title; the auto-extracted
/// metadata rides along read-only in mono.
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
        NavigationStack {
            VStack(spacing: 16) {
                poster
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)

                TextField("Title", text: $title)
                    .font(.system(size: 15))
                    .foregroundStyle(BCLTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BCLTheme.border, lineWidth: 1))

                Text(meta)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(BCLTheme.textSecondary)

                Spacer()
            }
            .padding(16)
            .background(BCLTheme.well)
            .navigationTitle("New Clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") {
                        var edited = draft
                        edited.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onUpload(edited)
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var meta: String {
        var parts = [BCLFormat.duration(draft.durationS), "\(draft.width)×\(draft.height)"]
        if let size = draft.fileSize { parts.append(BCLFormat.fileSize(size)) }
        parts.append(draft.orientation.rawValue.capitalized)
        return parts.joined(separator: " · ")
    }

    private var poster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: BCLTheme.radiusSheet).fill(BCLTheme.content)
            if let data = draft.thumbnailJPEG, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: BCLTheme.radiusCard))
                    .padding(8)
            } else {
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundStyle(BCLTheme.textTertiary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: BCLTheme.radiusSheet).strokeBorder(BCLTheme.hairline, lineWidth: 1))
    }
}
