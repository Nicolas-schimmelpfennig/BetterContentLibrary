//
//  StorageRouter.swift
//  BetterContentCore
//
//  Resolves which `StorageBackend` serves a given clip (by its recorded
//  provider) and which one receives NEW uploads (the Settings choice).
//  One instance per session, owned by `AppModel` and injected everywhere
//  bytes move.
//

import Foundation

public struct StorageRouter: Sendable {
    private let r2: R2Backend
    private let iCloud: ICloudBackend

    public init(r2: R2Backend = R2Backend(), iCloud: ICloudBackend = ICloudBackend()) {
        self.r2 = r2
        self.iCloud = iCloud
    }

    /// The provider NEW uploads should go to — the Settings choice, falling
    /// back to R2 for unset or not-yet-implemented values (Google Drive's
    /// backend doesn't exist yet, so it can't be reached even if the raw
    /// value sneaks into defaults).
    public var currentProvider: StorageProvider {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.storageProvider) ?? ""
        let provider = StorageProvider(rawValue: raw) ?? .r2
        return provider == .googleDrive ? .r2 : provider
    }

    public func backend(for provider: StorageProvider) -> any StorageBackend {
        switch provider {
        case .r2: return r2
        case .iCloudDrive: return iCloud
        case .googleDrive: return r2 // unreachable for clips: nothing writes 'gdrive' yet
        }
    }

    public func backend(for clip: Clip) -> any StorageBackend {
        backend(for: clip.storageProvider)
    }

    /// The backend new uploads go to right now.
    public var current: any StorageBackend {
        backend(for: currentProvider)
    }
}
