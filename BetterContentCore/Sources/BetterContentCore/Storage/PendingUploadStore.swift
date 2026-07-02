import Foundation

/// The on-disk staging area for files queued for background upload, plus a
/// durable registry of which clip each staged file belongs to.
///
/// Files are copied here before upload so the background session has stable
/// bytes it can access. The registry (a JSON sidecar in the same directory)
/// survives relaunch, which gives the launch sweep two things the old
/// in-memory map couldn't: a device-scoped list of uploads *this* device
/// enqueued (so it never touches clips another device is still uploading),
/// and the mapping needed to delete a staged file once its transfer ends.
public final class PendingUploadStore: @unchecked Sendable {
    public static let shared = PendingUploadStore()

    public let directory: URL
    private let registryURL: URL
    private let lock = NSLock()
    /// Clip id -> staged file name. Guarded by `lock`, mirrored to disk.
    private var registry: [UUID: String]

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? base.appendingPathComponent("BetterContentLibrary/PendingUploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        registryURL = self.directory.appendingPathComponent("in-flight.json")
        registry = (try? JSONDecoder().decode([UUID: String].self, from: Data(contentsOf: registryURL))) ?? [:]
    }

    /// Copies a user-picked file into the staging area and returns the copy.
    public func stage(_ source: URL) throws -> URL {
        let dest = directory.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    /// Records that `fileURL` is being uploaded for `clipId`. Call right before
    /// the upload is enqueued; the entry survives relaunch.
    public func track(clipId: UUID, fileURL: URL) {
        lock.withLock {
            registry[clipId] = fileURL.lastPathComponent
            persistLocked()
        }
    }

    /// Forgets a terminal upload and deletes its staged file.
    public func finish(clipId: UUID) {
        let name: String? = lock.withLock {
            let removed = registry.removeValue(forKey: clipId)
            if removed != nil { persistLocked() }
            return removed
        }
        if let name {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Clip ids this device enqueued that haven't reached a terminal state.
    public var trackedClipIds: Set<UUID> {
        lock.withLock { Set(registry.keys) }
    }

    /// Deletes staged files that belong to no tracked upload — drafts orphaned
    /// by a crash mid-review, or leftovers from before tracking existed.
    public func sweepUntrackedFiles() {
        let keep: Set<String> = lock.withLock { Set(registry.values) }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where !keep.contains(name) && name != registryURL.lastPathComponent {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func persistLocked() {
        try? JSONEncoder().encode(registry).write(to: registryURL, options: .atomic)
    }
}
