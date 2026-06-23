//
//  ScheduleModel.swift
//  BetterContentLibrary
//

import Foundation
import Observation
import BetterContentCore

/// Calendar state: the visible month, its schedules, and the clips they
/// reference. Loads the full visible 6-week grid so chips show on the
/// leading/trailing days too.
@MainActor
@Observable
final class ScheduleModel {
    private let schedules = SchedulesService()
    private let clips = ClipsService()
    private let calendar = Calendar.current
    let orgId: UUID

    /// First day of the visible month (midnight).
    private(set) var month: Date
    private(set) var items: [Schedule] = []
    private(set) var clipsById: [UUID: Clip] = [:]
    var errorMessage: String?

    init(orgId: UUID) {
        self.orgId = orgId
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        month = Calendar.current.date(from: comps) ?? Date()
    }

    /// Clips eligible to be scheduled (already uploaded).
    var schedulableClips: [Clip] {
        clipsById.values
            .filter { $0.status != .ingesting && $0.status != .uploading }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var monthTitle: String {
        month.formatted(.dateTime.month(.wide).year())
    }

    /// The 42 days (6 weeks) covering the visible month, including spill-over.
    var gridDays: [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -leading, to: month) ?? month
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    func isInCurrentMonth(_ day: Date) -> Bool {
        calendar.isDate(day, equalTo: month, toGranularity: .month)
    }

    func isToday(_ day: Date) -> Bool {
        calendar.isDateInToday(day)
    }

    func schedules(on day: Date) -> [Schedule] {
        items.filter { calendar.isDate($0.scheduledAt, inSameDayAs: day) }
    }

    func clip(for schedule: Schedule) -> Clip? {
        clipsById[schedule.clipId]
    }

    // MARK: Navigation

    func step(months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) {
            month = next
            Task { await load() }
        }
    }

    func goToToday() {
        let comps = calendar.dateComponents([.year, .month], from: Date())
        month = calendar.date(from: comps) ?? Date()
        Task { await load() }
    }

    // MARK: Data

    func load() async {
        do {
            let days = gridDays
            guard let start = days.first,
                  let end = calendar.date(byAdding: .day, value: 1, to: days.last ?? month) else { return }
            async let fetchedSchedules = schedules.list(from: start, to: end)
            async let fetchedClips = clips.list()
            items = try await fetchedSchedules
            clipsById = Dictionary(uniqueKeysWithValues: try await fetchedClips.map { ($0.id, $0) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func add(clipId: UUID, platform: Platform, at date: Date, notes: String?) async {
        do {
            _ = try await schedules.create(
                clipId: clipId, orgId: orgId, platform: platform, scheduledAt: date, notes: notes
            )
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves a schedule to a different day, keeping its time of day.
    func reschedule(id: UUID, toDay day: Date) async {
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

    func delete(_ id: UUID) async {
        do {
            try await schedules.delete(id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
