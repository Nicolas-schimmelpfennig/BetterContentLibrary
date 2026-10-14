//
//  CoverFormSection.swift
//  BetterContentLibrary (iOS)
//
//  The schedule form's "Thumbnail" slot: pick the post's custom cover from
//  Photos or Files, preview it, replace or remove it. Edits are staged in a
//  `CoverChange` and applied by the form's save.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import BetterContentCore

struct CoverFormSection: View {
    let model: ScheduleModel
    /// The post being edited, if any — its current cover is the starting point.
    let existing: Schedule?
    @Binding var change: CoverChange

    @State private var photoItem: PhotosPickerItem?
    @State private var importing = false
    @State private var existingImage: UIImage?
    @State private var loadingExisting = false
    @State private var errorMessage: String?

    private var preview: UIImage? {
        switch change {
        case .set(let image): return UIImage(data: image.data)
        case .removed: return nil
        case .unchanged: return existingImage
        }
    }

    var body: some View {
        Section {
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } else if loadingExisting {
                HStack { Spacer(); ProgressView(); Spacer() }
            }

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(preview == nil ? "Choose from Photos" : "Replace from Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                importing = true
            } label: {
                Label(preview == nil ? "Choose from Files" : "Replace from Files", systemImage: "folder")
            }
            if preview != nil {
                Button("Remove Thumbnail", role: .destructive) {
                    change = existing?.hasCover == true ? .removed : .unchanged
                    if existing?.hasCover != true { existingImage = nil }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Thumbnail")
        } footer: {
            Text("Optional — the post's custom cover (JPEG or PNG). It's kept with the post and downloads alongside the video.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.jpeg, .png, .image]) { result in
            switch result {
            case .success(let url): stage { try CoverImage(contentsOf: url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CoverImage.ImportError.notAnImage
                    }
                    stage { try CoverImage(data: data) }
                } catch {
                    errorMessage = error.localizedDescription
                }
                photoItem = nil
            }
        }
        .task {
            guard let existing, existing.hasCover, existingImage == nil else { return }
            loadingExisting = true
            existingImage = await model.coverImage(for: existing)
            loadingExisting = false
        }
    }

    private func stage(_ make: () throws -> CoverImage) {
        do {
            change = .set(try make())
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
