//
//  DraftSheet.swift
//  BetterContentLibrary
//
//  Editable, pre-filled metadata form shown after a video is read, before it
//  uploads. Presented by the library's drop/add-file import flow.
//

import SwiftUI
import AppKit
import BetterContentCore

struct DraftSheet: View {
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
