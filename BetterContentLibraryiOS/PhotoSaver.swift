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
                return "Allow photo library access in Settings to save videos."
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
}
