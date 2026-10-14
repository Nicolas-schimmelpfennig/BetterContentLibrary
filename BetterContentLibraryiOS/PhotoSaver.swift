//
//  PhotoSaver.swift
//  BetterContentLibrary (iOS)
//
//  Saves a downloaded video file into the user's photo library (add-only access).
//

import Photos
import Foundation

enum PhotoSaver {
    enum SaveError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Allow photo library access in Settings to save videos and thumbnails."
            }
        }
    }

    /// Requests add-only photo permission and saves the video at `url` to the
    /// camera roll. Throws if permission is denied or the save fails.
    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SaveError.notAuthorized
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    /// Saves image bytes to the camera roll as-is (a PNG stays a PNG), for a
    /// scheduled post's cover.
    static func saveImage(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SaveError.notAuthorized
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }
}
