//
//  ScheduleScreen.swift
//  BetterContentLibrary (iOS)
//
//  Month calendar for assigning clips to post date/times. Tap a day to add; drag
//  a chip to another day to reschedule; long-press a chip to delete.
//

import SwiftUI
import BetterContentCore

struct ScheduleScreen: View {
    let model: AppModel

    @State private var selectedDay: DaySelection?
    @State private var deepLink = DeepLinkCenter.shared

    private var schedule: ScheduleModel { model.schedule }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                weekdayHeader
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(schedule.gridDays, id: \.self) { day in
                            DayCell(day: day, schedule: schedule, onSelect: { selectedDay = DaySelection(date: day) })
                        }
                    }
                    .padding(2)
                }
            }
            .navigationTitle(schedule.monthTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { schedule.step(months: -1) } label: { Image(systemName: "chevron.left") }
                    Button("Today") { schedule.goToToday() }
                    Button { schedule.step(months: 1) } label: { Image(systemName: "chevron.right") }
                }
            }
            .task { await schedule.load() }
            // Open the relevant day's card when a tapped notification deep-links here
            // (covers both cold launch and while running).
            .task(id: deepLink.scheduleDay) {
                if let day = deepLink.scheduleDay {
                    selectedDay = DaySelection(date: day)
                    deepLink.scheduleDay = nil
                }
            }
            .sheet(item: $selectedDay) { selection in
                DayDetailSheet(day: selection.date, model: model)
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 2) {
            ForEach(schedule.weekdaySymbols, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    struct DaySelection: Identifiable {
        let id = UUID()
        let date: Date
    }
}

private struct DayCell: View {
    let day: Date
    let schedule: ScheduleModel
    let onSelect: () -> Void

    private var dayNumber: String { day.formatted(.dateTime.day()) }
    private var inMonth: Bool { schedule.isInCurrentMonth(day) }
    private var isToday: Bool { schedule.isToday(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(dayNumber)
                .font(.caption.weight(isToday ? .bold : .regular))
                .foregroundStyle(numberColor)
                .frame(width: 22, height: 22)
                .background { if isToday { Circle().fill(Color.accentColor) } }

            ForEach(schedule.schedules(on: day)) { sched in
                ScheduleChip(schedule: sched, title: schedule.clip(for: sched)?.title ?? "Clip")
                    .draggable(sched.id.uuidString)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            Task { await schedule.delete(sched.id) }
                        }
                    }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(3)
        .background(inMonth ? Color(.secondarySystemGroupedBackground) : Color(.systemGroupedBackground))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids where UUID(uuidString: id) != nil {
                Task { await schedule.reschedule(id: UUID(uuidString: id)!, toDay: day) }
            }
            return true
        }
    }

    private var numberColor: Color {
        if isToday { return .white }
        return inMonth ? .primary : .secondary
    }
}

private struct ScheduleChip: View {
    let schedule: Schedule
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(PlatformStyle.color(schedule.platform)).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlatformStyle.color(schedule.platform).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct AddScheduleSheet: View {
    let day: Date
    let model: ScheduleModel

    @Environment(\.dismiss) private var dismiss
    @State private var clipId: UUID?
    @State private var platform: Platform = .instagram
    @State private var time: Date
    @State private var notes = ""
    @State private var notifyProfileId: UUID?

    init(day: Date, model: ScheduleModel) {
        self.day = day
        self.model = model
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        comps.hour = 9
        comps.minute = 0
        _time = State(initialValue: Calendar.current.date(from: comps) ?? day)
        _clipId = State(initialValue: model.schedulableClips.first?.id)
        _notifyProfileId = State(initialValue: model.currentProfileId)
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.schedulableClips.isEmpty {
                    ContentUnavailableView(
                        "No clips to schedule",
                        systemImage: "film",
                        description: Text("Upload a video first, then schedule it here.")
                    )
                } else {
                    Form {
                        Picker("Clip", selection: $clipId) {
                            ForEach(model.schedulableClips) { clip in
                                Text(clip.title).tag(Optional(clip.id))
                            }
                        }
                        Picker("Platform", selection: $platform) {
                            ForEach(Platform.allCases, id: \.self) { p in
                                Text(PlatformStyle.name(p)).tag(p)
                            }
                        }
                        Picker("Notify", selection: $notifyProfileId) {
                            Text("No one").tag(UUID?.none)
                            ForEach(model.orgMembers) { member in
                                Text(member.displayName ?? "Member").tag(Optional(member.id))
                            }
                        }
                        DatePicker("Time", selection: $time, displayedComponents: [.hourAndMinute])
                        TextField("Notes (optional)", text: $notes, axis: .vertical)
                    }
                }
            }
            .navigationTitle(day.formatted(.dateTime.weekday().month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Schedule") {
                        if let clipId {
                            let when = combine(day: day, time: time)
                            Task { await model.add(clipId: clipId, platform: platform, at: when, notes: notes.isEmpty ? nil : notes, notifyProfileId: notifyProfileId) }
                        }
                        dismiss()
                    }
                    .disabled(clipId == nil)
                }
            }
        }
    }

    private func combine(day: Date, time: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        let t = cal.dateComponents([.hour, .minute], from: time)
        comps.hour = t.hour
        comps.minute = t.minute
        return cal.date(from: comps) ?? day
    }
}

/// Per-platform colors and display names (iOS copy; SwiftUI `Color` keeps this in
/// the view layer rather than the UI-free core).
enum PlatformStyle {
    static func color(_ platform: Platform) -> Color {
        switch platform {
        case .instagram: return .pink
        case .tiktok: return .cyan
        case .youtube, .youtubeShorts: return .red
        case .x: return .primary
        case .facebook: return .blue
        case .linkedin: return .indigo
        case .other: return .gray
        }
    }

    static func name(_ platform: Platform) -> String {
        switch platform {
        case .instagram: return "Instagram"
        case .tiktok: return "TikTok"
        case .youtube: return "YouTube"
        case .youtubeShorts: return "YouTube Shorts"
        case .x: return "X"
        case .facebook: return "Facebook"
        case .linkedin: return "LinkedIn"
        case .other: return "Other"
        }
    }
}
