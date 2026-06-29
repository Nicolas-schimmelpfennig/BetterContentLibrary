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

                Image(systemName: isPreparing ? "hourglass" : "square.and.arrow.up.on.square")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: isPreparing)

                Text(isPreparing ? "Reading video…" : "Add a video")
                    .font(.title2.weight(.medium))
                Text("Upload from your photo library or Files.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    PhotosPicker(selection: $photoItems, matching: .videos, photoLibrary: .shared()) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        isChoosingFile = true
                    } label: {
                        Label("Files", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(isPreparing)
                .padding(.horizontal, 40)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Spacer()
            }
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

private struct DraftSheet: View {
    @State private var title: String
    @State private var orientation: ClipOrientation
    @State private var capturedAt: Date

    private let draft: ClipDraft
    private let onUpload: (ClipDraft) -> Void
    private let onCancel: () -> Void

    init(draft: ClipDraft, onUpload: @escaping (ClipDraft) -> Void, onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onUpload = onUpload
        self.onCancel = onCancel
        _title = State(initialValue: draft.title)
        _orientation = State(initialValue: draft.orientation)
        _capturedAt = State(initialValue: draft.capturedAt ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    poster
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                }

                Section {
                    TextField("Title", text: $title)
                    Picker("Orientation", selection: $orientation) {
                        ForEach(ClipOrientation.allCases, id: \.self) { o in
                            Text(o.rawValue.capitalized).tag(o)
                        }
                    }
                    DatePicker("Creation date", selection: $capturedAt, displayedComponents: [.date, .hourAndMinute])
                }

                Section {
                    LabeledContent("Duration", value: Self.durationText(draft.durationS))
                    LabeledContent("Dimensions", value: "\(draft.width) × \(draft.height)")
                    if let size = draft.fileSize {
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
            }
            .navigationTitle("Add Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Upload") {
                        var edited = draft
                        edited.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        edited.orientation = orientation
                        edited.capturedAt = capturedAt
                        onUpload(edited)
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let data = draft.thumbnailJPEG, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
