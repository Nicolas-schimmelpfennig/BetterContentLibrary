//
//  ScheduleView.swift
//  BetterContentLibrary
//

import SwiftUI
import BetterContentCore

/// Month calendar for assigning clips to post date/times. Drag a chip to another
/// day to reschedule; click a day's "+" to add.
struct ScheduleView: View {
    let model: AppModel

    @State private var addTarget: AddTarget?

    private var schedule: ScheduleModel { model.schedule }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            weekdayHeader
            calendarGrid
        }
        .navigationTitle("Schedule")
        .task { await schedule.load() }
        .sheet(item: $addTarget) { target in
            AddScheduleSheet(day: target.day, model: schedule)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(schedule.monthTitle).font(.title2.bold())
            Spacer()
            Button("Today") { schedule.goToToday() }
            Button { schedule.step(months: -1) } label: { Image(systemName: "chevron.left") }
            Button { schedule.step(months: 1) } label: { Image(systemName: "chevron.right") }
        }
        .padding()
    }

    private var weekdayHeader: some View {
        HStack(spacing: 1) {
            ForEach(schedule.weekdaySymbols, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var calendarGrid: some View {
        LazyVGrid(columns: columns, spacing: 1) {
            ForEach(schedule.gridDays, id: \.self) { day in
                DayCell(
                    day: day,
                    model: schedule,
                    onAdd: { addTarget = AddTarget(day: day) }
                )
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.12))
    }

    struct AddTarget: Identifiable {
        let id = UUID()
        let day: Date
    }
}

private struct DayCell: View {
    let day: Date
    let model: ScheduleModel
    let onAdd: () -> Void

    @State private var isHovering = false

    private var dayNumber: String { day.formatted(.dateTime.day()) }
    private var inMonth: Bool { model.isInCurrentMonth(day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(dayNumber)
                    .font(.caption.weight(model.isToday(day) ? .bold : .regular))
                    .foregroundStyle(numberColor)
                    .frame(minWidth: 18, minHeight: 18)
                    .background {
                        if model.isToday(day) { Circle().fill(Color.accentColor) }
                    }
                Spacer()
                if isHovering {
                    Button(action: onAdd) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                }
            }

            ForEach(model.schedules(on: day)) { sched in
                ScheduleChip(schedule: sched, title: model.clip(for: sched)?.title ?? "Clip")
                    .draggable(sched.id.uuidString)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            Task { await model.delete(sched.id) }
                        }
                    }
            }

            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(height: 96, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(inMonth ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isHovering { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.5)) }
        }
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { onAdd() }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids {
                if let uuid = UUID(uuidString: id) {
                    Task { await model.reschedule(id: uuid, toDay: day) }
                }
            }
            return true
        }
    }

    private var numberColor: Color {
        if model.isToday(day) { return .white }
        return inMonth ? .primary : .secondary
    }
}

private struct ScheduleChip: View {
    let schedule: Schedule
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(PlatformStyle.color(schedule.platform)).frame(width: 6, height: 6)
            Text(timeText)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10))
                .lineLimit(1)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlatformStyle.color(schedule.platform).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }

    private var timeText: String {
        schedule.scheduledAt.formatted(.dateTime.hour().minute())
    }
}

private struct AddScheduleSheet: View {
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
        // Default to 9:00 AM on the chosen day.
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        comps.hour = 9
        comps.minute = 0
        _time = State(initialValue: Calendar.current.date(from: comps) ?? day)
        _clipId = State(initialValue: model.schedulableClips.first?.id)
        _notifyProfileId = State(initialValue: model.currentProfileId)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Schedule for \(day.formatted(.dateTime.weekday().month().day()))").font(.headline)
                Spacer()
            }
            .padding()
            Divider()

            if model.schedulableClips.isEmpty {
                ContentUnavailableView(
                    "No clips to schedule",
                    systemImage: "film",
                    description: Text("Upload a video first, then schedule it here.")
                )
                .frame(width: 420, height: 180)
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
                .formStyle(.grouped)
                .frame(width: 420)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Schedule") {
                    if let clipId {
                        let when = combine(day: day, time: time)
                        Task { await model.add(clipId: clipId, platform: platform, at: when, notes: notes.isEmpty ? nil : notes, notifyProfileId: notifyProfileId) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(clipId == nil)
            }
            .padding()
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

/// Per-platform colors and display names.
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
