import Foundation

/// Owns the durable side of the upload lifecycle: the single place that turns
/// background-upload outcomes into clip status writes, and the repair pass
/// that fixes whatever a crash or forced quit left behind.
///
/// Register exactly once per process via `activate()`; outcomes that fired
/// earlier (e.g. replayed by the system at launch, before sign-in) are
/// buffered by `BackgroundUploadService` and delivered during registration.
/// Then run `sweepStalled()` once per session: any upload *this device*
/// enqueued that no longer has a live task is marked `failed`, and orphaned
/// staged files are deleted. The sweep is scoped by `PendingUploadStore`'s
/// registry, so it never touches a clip another device is still uploading.
///
/// A registry entry is only released after its status write lands. If the
/// write can't land (e.g. offline at the moment an outcome arrives), the entry
/// survives and the next session's sweep re-resolves the clip — worst case a
/// finished upload is marked `failed`, which the dedupe path in `ClipUploader`
/// recovers from on re-upload. What can no longer happen is a clip stuck in
/// `uploading` forever.
public final class UploadReconciler: @unchecked Sendable {
    public static let shared = UploadReconciler()

    private let clips: ClipsService
    private let store: PendingUploadStore
    private let uploader: BackgroundUploadService
    private let lock = NSLock()
    private var activated = false
    /// Outcomes whose status write is still in flight; the sweep skips these.
    private var resolving: Set<UUID> = []

    init(
        clips: ClipsService = ClipsService(),
        store: PendingUploadStore = .shared,
        uploader: BackgroundUploadService = .shared
    ) {
        self.clips = clips
        self.store = store
        self.uploader = uploader
    }

    /// Registers the terminal-outcome handler (idempotent).
    public func activate() {
        let firstCall = lock.withLock { () -> Bool in
            guard !activated else { return false }
            activated = true
            return true
        }
        guard firstCall else { return }

        uploader.addTerminalObserver { [weak self] outcome in
            guard let self else { return }
            lock.withLock { _ = resolving.insert(outcome.clipId) }
            Task {
                await self.resolve(clipId: outcome.clipId, to: outcome.succeeded ? .ready : .failed)
                self.lock.withLock { _ = self.resolving.remove(outcome.clipId) }
            }
        }
    }

    /// Repairs state from a previous run. Call once per session, after sign-in
    /// (status writes go through RLS) and after `activate()`. Returns whether
    /// anything was marked failed.
    @discardableResult
    public func sweepStalled() async -> Bool {
        let active = await uploader.activeUploadClipIds()
        let busy = lock.withLock { resolving }
        let stalled = store.trackedClipIds.subtracting(active).subtracting(busy)
        for clipId in stalled {
            await resolve(clipId: clipId, to: .failed)
        }
        store.sweepUntrackedFiles()
        return !stalled.isEmpty
    }

    /// Writes the terminal status (with retries) and, only once it lands,
    /// releases the registry entry and staged file.
    private func resolve(clipId: UUID, to status: ClipStatus) async {
        for attempt in 1...3 {
            do {
                try await clips.setStatus(clipId, status)
                store.finish(clipId: clipId)
                return
            } catch {
                if attempt == 3 {
                    // Keep the registry entry: the next session's sweep retries.
                    print("UploadReconciler: couldn't set \(clipId) to \(status.rawValue): \(error)")
                    return
                }
                try? await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
    }
}
