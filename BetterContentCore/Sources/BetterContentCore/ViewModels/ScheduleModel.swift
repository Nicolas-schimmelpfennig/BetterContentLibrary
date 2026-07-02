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

    public func add(clipId: UUID, platform: Platform, at date: Date, notes: String?, notifyProfileId: UUID?) async {
        do {
            _ = try await schedules.create(
                clipId: clipId, orgId: orgId, platform: platform,
                scheduledAt: date, notes: notes, notifyProfileId: notifyProfileId
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
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
