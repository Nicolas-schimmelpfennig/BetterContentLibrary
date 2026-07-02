import Foundation
import Supabase

/// Live cross-device sync: subscribes to the org's postgres changes on `clips`
/// and `schedules` (RLS scopes delivery to the caller's rows) and invokes the
/// matching callback, debounced, so a schedule created on the Mac shows up on
/// the phone without a manual refresh.
///
/// One instance per signed-in session; `start()` on creation of the session's
/// `AppModel`, `stop()` when it goes away (sign-out).
@MainActor
public final class RealtimeSync {
    private let client: SupabaseClient
    private var channel: RealtimeChannelV2?
    private var listeners: [Task<Void, Never>] = []
    private var pendingClips: Task<Void, Never>?
    private var pendingSchedules: Task<Void, Never>?

    /// Called (debounced) after any insert/update/delete on the org's clips.
    public var onClipsChange: (@MainActor () -> Void)?
    /// Called (debounced) after any insert/update/delete on the org's schedules.
    public var onSchedulesChange: (@MainActor () -> Void)?

    public init(client: SupabaseClient = Backend.client) {
        self.client = client
    }

    public func start() {
        guard channel == nil else { return }
        let channel = client.channel("org-db-sync")
        self.channel = channel

        let clipChanges = channel.postgresChange(AnyAction.self, schema: "public", table: "clips")
        let scheduleChanges = channel.postgresChange(AnyAction.self, schema: "public", table: "schedules")

        listeners.append(Task { [weak self] in
            for await _ in clipChanges {
                self?.scheduleClipsCallback()
            }
        })
        listeners.append(Task { [weak self] in
            for await _ in scheduleChanges {
                self?.scheduleSchedulesCallback()
            }
        })
        listeners.append(Task {
            await channel.subscribe()
        })
    }

    public func stop() {
        for task in listeners { task.cancel() }
        listeners.removeAll()
        pendingClips?.cancel()
        pendingSchedules?.cancel()
        if let channel {
            self.channel = nil
            Task { await channel.unsubscribe() }
        }
    }

    /// A mutation burst (create + metadata + status writes) collapses into one
    /// reload ~400 ms after the last change.
    private func scheduleClipsCallback() {
        pendingClips?.cancel()
        pendingClips = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.onClipsChange?()
        }
    }

    private func scheduleSchedulesCallback() {
        pendingSchedules?.cancel()
        pendingSchedules = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.onSchedulesChange?()
        }
    }
}
