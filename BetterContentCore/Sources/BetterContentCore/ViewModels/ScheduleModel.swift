//
//  ScheduleModel.swift
//  BetterContentCore
//
//  Shared calendar state for the schedule view on both platforms.
//

import Foundation
import Observation

/// Calendar state: the visible month, its schedules, and the clips they
/// reference. Loads the full visible 6-week grid so chips show on the
/// leading/trailing days too.
@MainActor
@Observable
public final class ScheduleModel {
    private let schedules = SchedulesService()
    private let clips = ClipsService()
    private let profiles = ProfilesService()
    private let calendar = Calendar.current
    public let orgId: UUID
    /// The signed-in user, used as the default "notify" target when scheduling.
    public let currentProfileId: UUID

    /// First day of the visible month (midnight).
    public private(set) var month: Date
    public private(set) var items: [Schedule] = []
    public private(set) var clipsById: [UUID: Clip] = [:]
    public private(set) var profilesById: [UUID: Profile] = [:]
    public var errorMessage: String?

    /// Set after the first `load()`, successful or not. Lets the initial
    /// view `.task` skip refetching on every appearance (e.g. a pane being
    /// re-shown) — realtime sync and explicit actions (month navigation,
    /// add/edit/delete, …) all call `load()` directly and stay live.
    public private(set) var hasLoaded = false

    public init(orgId: UUID, currentProfileId: UUID) {
        self.orgId = orgId
        self.currentProfileId = currentProfileId
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        month = Calendar.current.date(from: comps) ?? Date()
    }

    /// Org members, for the "notify whom" picker (name-sorted).
    public var orgMembers: [Profile] {
        profilesById.values.sorted {
            ($0.displayName ?? "").localizedCaseInsensitiveCompare($1.displayName ?? "") == .orderedAscending
        }
    }

    /// Clips eligible to be scheduled (already uploaded).
    public var schedulableClips: [Clip] {
        clipsById.values
            .filter { $0.status == .ready }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public var monthTitle: String {
        month.formatted(.dateTime.month(.wide).year())
    }

    /// The 42 days (6 weeks) covering the visible month, including spill-over.
    public var gridDays: [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -leading, to: month) ?? month
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    public var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    public func isInCurrentMonth(_ day: Date) -> Bool {
        calendar.isDate(day, equalTo: month, toGranularity: .month)
    }

    public func isToday(_ day: Date) -> Bool {
        calendar.isDateInToday(day)
    }

    public func schedules(on day: Date) -> [Schedule] {
        items.filter { calendar.isDate($0.scheduledAt, inSameDayAs: day) }
    }

    public func clip(for schedule: Schedule) -> Clip? {
        clipsById[schedule.clipId]
    }

    /// Display name of whoever uploaded the clip, if known.
    public func uploaderName(for clip: Clip) -> String? {
        guard let id = clip.uploadedBy else { return nil }
        return profilesById[id]?.displayName
    }

    // MARK: Navigation

    public func step(months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) {
            month = next
            Task { await load() }
        }
    }

    public func goToToday() {
        let comps = calendar.dateComponents([.year, .month], from: Date())
        month = calendar.date(from: comps) ?? Date()
        Task { await load() }
    }

    // MARK: Data

    public func load() async {
        defer { hasLoaded = true }
        do {
            let days = gridDays
            guard let start = days.first,
                  let end = calendar.date(byAdding: .day, value: 1, to: days.last ?? month) else { return }
            async let fetchedSchedules = schedules.list(from: start, to: end)
            async let fetchedClips = clips.list()
            async let fetchedProfiles = profiles.listForCurrentOrg()
            items = try await fetchedSchedules
            clipsById = Dictionary(uniqueKeysWithValues: try await fetchedClips.map { ($0.id, $0) })
            profilesById = Dictionary(uniqueKeysWithValues: try await fetchedProfiles.map { ($0.id, $0) })

            // The org-wide clip list is capped, so a schedule can reference a
            // clip that didn't make the cut (old clip, busy library). Fetch the
            // stragglers by id so every calendar chip resolves its clip.
            let missing = Set(items.map(\.clipId)).subtracting(clipsById.keys)
            if !missing.isEmpty {
                for clip in try await clips.list(ids: Array(missing)) {
                    clipsById[clip.id] = clip
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Loads only if nothing has been loaded yet this session. For the view's
    /// initial `.task`, so a pane being hidden and re-shown (or any other
    /// remount) doesn't pay for a network refetch of data already in memory.
    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    public func add(
        clipId: UUID,
        platform: Platform,
        at date: Date,
        caption: String? = nil,
        notes: String?,
        notifyProfileId: UUID?
    ) async {
        do {
            _ = try await schedules.create(
                clipId: clipId, orgId: orgId, platform: platform,
                scheduledAt: date, caption: caption, notes: notes,
                notifyProfileId: notifyProfileId
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rewrites every user-editable field of an existing schedule (the editor's
    /// save on an existing post).
    public func update(
        id: UUID,
        clipId: UUID,
        platform: Platform,
        at date: Date,
        caption: String?,
        notes: String?,
        notifyProfileId: UUID?
    ) async {
        do {
            try await schedules.update(
                id, clipId: clipId, platform: platform, scheduledAt: date,
                caption: caption, notes: notes, notifyProfileId: notifyProfileId
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Marks a schedule posted (records `posted_at`) — the manual "I published
    /// it" confirmation.
    public func markPosted(_ id: UUID) async {
        do {
            try await schedules.markPosted(id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Marks a clip posted when it has no planned schedule to flip: creates a
    /// minimal ad-hoc one ("Other" platform, right now) and marks it posted
    /// in the same beat. Lets the library's "Mark as Posted" work on any
    /// ready clip — not just ones already on the calendar — while keeping
    /// "Posted" tied to a real schedule row instead of a free-floating flag.
    public func markClipPostedAdHoc(clipId: UUID) async {
        do {
            let created = try await schedules.create(clipId: clipId, orgId: orgId, platform: .other, scheduledAt: Date())
            try await schedules.markPosted(created.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reverts a posted schedule back to planned — undoes an accidental
    /// "Mark as Posted" without deleting the record.
    public func reopen(_ id: UUID) async {
        do {
            try await schedules.setStatus(id, .planned)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Skips a schedule without deleting it (gray, struck-through in chips).
    public func skip(_ id: UUID) async {
        do {
            try await schedules.setStatus(id, .skipped)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The next planned post within the coming 24 hours, if any — powers the
    /// iOS "Up next" card.
    public var upNext: Schedule? {
        let now = Date()
        let horizon = now.addingTimeInterval(24 * 3600)
        return items
            .filter { $0.status == .planned && $0.scheduledAt > now.addingTimeInterval(-3600) && $0.scheduledAt <= horizon }
            .min { $0.scheduledAt < $1.scheduledAt }
    }

    /// Moves a schedule to a different day, keeping its time of day.
    public func reschedule(id: UUID, toDay day: Date) async {
        guard let existing = items.first(where: { $0.id == id }) else { return }
        let time = calendar.dateComponents([.hour, .minute], from: existing.scheduledAt)
        var target = calendar.dateComponents([.year, .month, .day], from: day)
        target.hour = time.hour
        target.minute = time.minute
        guard let newDate = calendar.date(from: target) else { return }
        do {
            try await schedules.reschedule(id, to: newDate)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func delete(_ id: UUID) async {
        do {
            try await schedules.delete(id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
