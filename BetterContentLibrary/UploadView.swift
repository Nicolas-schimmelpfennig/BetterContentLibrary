//
//  UploadView.swift
//  BetterContentLibrary
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BetterContentCore

/// Drag-and-drop (or pick) a video, review the auto-filled metadata, then upload.
struct UploadView: View {
    let model: AppModel

    @State private var isTargeted = false
    @State private var isPreparing = false
    @State private var queue: [ClipDraft] = []
    @State private var errorMessage: String?
    @State private var isChoosingFile = false

    var body: some View {
        dropZone
            .navigationTitle("Upload")
            .padding(40)
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

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: isPreparing ? "hourglass" : "square.and.arrow.down.on.square")
                .font(.system(size: 52))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .symbolEffect(.pulse, isActive: isPreparing)

            Text(isPreparing ? "Reading video…" : "Drag a video here")
                .font(.title2.weight(.medium))
            Text("MP4, MOV, or M4V")
                .foregroundStyle(.secondary)

            Button("Choose File…") { isChoosingFile = true }
                .controlSize(.large)
                .disabled(isPreparing)

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.accentColor.opacity(0.06) : .clear)
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            prepare(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    // Presents a sheet for the first queued draft.
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
        guard !videoURLs.isEmpty else { return }
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

/// Editable, pre-filled metadata form shown after a video is read.
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
        VStack(spacing: 0) {
            HStack {
                Text("Add Video").font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            HStack(alignment: .top, spacing: 20) {
                thumbnail
                form
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                Button("Upload") {
                    var edited = draft
                    edited.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    edited.orientation = orientation
                    edited.capturedAt = capturedAt
                    onUpload(edited)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 560)
    }

    private var thumbnail: some View {
        Group {
            if let data = draft.thumbnailJPEG, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                    .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary))
            }
        }
        .frame(width: 200, height: 200 * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var form: some View {
        Form {
            TextField("Title", text: $title)

            Picker("Orientation", selection: $orientation) {
                ForEach(ClipOrientation.allCases, id: \.self) { o in
                    Text(o.rawValue.capitalized).tag(o)
                }
            }

            DatePicker("Creation date", selection: $capturedAt, displayedComponents: [.date, .hourAndMinute])

            LabeledContent("Duration", value: Self.durationText(draft.durationS))
            LabeledContent("Dimensions", value: "\(draft.width) × \(draft.height)")
            if let size = draft.fileSize {
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
            }
        }
        .formStyle(.columns)
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
