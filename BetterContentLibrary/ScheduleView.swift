//
//  ScheduleView.swift
//  BetterContentLibrary
//
//  Month calendar (design 1h/1i): chips carry a 3px status border, platform
//  monogram, title, and mono time; days cap at 3 chips + "+N more" popover;
//  chips drag between days; context menu marks posted / skips / deletes.
//

import SwiftUI
import BetterContentCore

struct ScheduleView: View {
    let model: AppModel

    @State private var addTarget: AddTarget?

    private var schedule: ScheduleModel { model.schedule }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)

    var body: some View {
        VStack(spacing: 0) {
            header
            weekdayHeader
            BCLTheme.hairline.frame(height: 1)
            calendarGrid
        }
        .background(BCLTheme.content)
        .navigationTitle("Schedule")
        .task { await schedule.load() }
        .sheet(item: $addTarget) { target in
            AddScheduleSheet(day: target.day, model: schedule)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(schedule.monthTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(BCLTheme.textPrimary)
            Spacer()
            controlButton("Today") { schedule.goToToday() }
            HStack(spacing: 0) {
                controlIcon("chevron.left") { schedule.step(months: -1) }
                controlIcon("chevron.right") { schedule.step(months: 1) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func controlButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BCLTheme.textPrimary)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(BCLTheme.control, in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
        }
        .buttonStyle(.plain)
    }

    private func controlIcon(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BCLTheme.textPrimary.opacity(0.7))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 1) {
            ForEach(schedule.weekdaySymbols, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(BCLTheme.textLabel)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var calendarGrid: some View {
        ScrollView {
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
        }
        .background(BCLTheme.well)
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
    @State private var showingOverflow = false

    private let maxChips = 3

    private var dayNumber: String { day.formatted(.dateTime.day()) }
    private var inMonth: Bool { model.isInCurrentMonth(day) }
    private var daySchedules: [Schedule] { model.schedules(on: day) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(dayNumber)
                    .font(.system(size: 11, weight: model.isToday(day) ? .bold : .regular))
                    .foregroundStyle(numberColor)
                    .frame(minWidth: 18, minHeight: 18)
                    .background {
                        if model.isToday(day) { Circle().fill(BCLTheme.accent) }
                    }
                Spacer()
                if isHovering {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BCLTheme.textSecondary)
                    }
                    .buttonStyle(.borderless)
                }
            }

            ForEach(daySchedules.prefix(maxChips)) { sched in
                chip(for: sched)
            }

            if daySchedules.count > maxChips {
                Button {
                    showingOverflow = true
                } label: {
                    Text("+\(daySchedules.count - maxChips) more…")
                        .font(.system(size: 10))
                        .foregroundStyle(BCLTheme.textLabel)
                        .padding(.leading, 4)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingOverflow) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(daySchedules) { sched in
                            chip(for: sched)
                        }
                    }
                    .padding(10)
                    .frame(width: 240)
                    .background(BCLTheme.raised)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(minHeight: 96, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(inMonth ? BCLTheme.content : BCLTheme.content.opacity(0.55))
        .overlay {
            if isHovering {
                RoundedRectangle(cornerRadius: BCLTheme.radiusBadge)
                    .strokeBorder(BCLTheme.accent.opacity(0.5))
            }
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

    private func chip(for sched: Schedule) -> some View {
        ScheduleChipView(schedule: sched, title: model.clip(for: sched)?.title ?? "Clip")
            .draggable(sched.id.uuidString)
            .contextMenu {
                if sched.status == .planned {
                    Button("Mark as Posted") { Task { await model.markPosted(sched.id) } }
                    Button("Skip") { Task { await model.skip(sched.id) } }
                    Divider()
                }
                Button("Delete", role: .destructive) {
                    Task { await model.delete(sched.id) }
                }
            }
    }

    private var numberColor: Color {
        if model.isToday(day) { return .white }
        return inMonth ? BCLTheme.textPrimary : BCLTheme.textTertiary
    }
}

/// Chip anatomy (identical on iOS): 3px status left border, 14px platform
/// monogram, title, mono time. Skipped = gray + strikethrough.
struct ScheduleChipView: View {
    let schedule: Schedule
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            PlatformBadge(schedule.platform, size: 14)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(schedule.status == .skipped ? BCLTheme.textTertiary : BCLTheme.textPrimary)
                .strikethrough(schedule.status == .skipped)
                .lineLimit(1)
            Spacer(minLength: 2)
            Text(schedule.scheduledAt.formatted(.dateTime.hour().minute()))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(BCLTheme.textLabel)
        }
        .padding(.leading, 4)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BCLTheme.raised, in: RoundedRectangle(cornerRadius: BCLTheme.radiusBadge))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: BCLTheme.radiusBadge, bottomLeading: BCLTheme.radiusBadge)
            )
            .fill(schedule.status.color)
            .frame(width: 3)
        }
    }
}

// MARK: - Add Schedule sheet (design 1i)

struct AddScheduleSheet: View {
    let day: Date
    let model: ScheduleModel
    var preselectedClip: Clip?

    @Environment(\.dismiss) private var dismiss
    @State private var clipId: UUID?
    @State private var platform: Platform = .instagram
    @State private var time: Date
    @State private var caption = ""
    @State private var notes = ""
    @State private var notifyProfileId: UUID?

    init(day: Date, model: ScheduleModel, preselectedClip: Clip? = nil) {
        self.day = day
        self.model = model
        self.preselectedClip = preselectedClip
        // Default to 9:00 AM on the chosen day.
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        comps.hour = 9
        comps.minute = 0
        _time = State(initialValue: Calendar.current.date(from: comps) ?? day)
        _clipId = State(initialValue: preselectedClip?.id ?? model.schedulableClips.first?.id)
        _notifyProfileId = State(initialValue: model.currentProfileId)
    }

    /// Platform-aware caption limits (X is the only tight one).
    private var captionLimit: Int {
        switch platform {
        case .x: return 280
        case .youtube, .youtubeShorts: return 5000
        default: return 2200
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Schedule")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BCLTheme.textPrimary)
                Spacer()
                Text(day.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(BCLTheme.textPrimary.opacity(0.35))
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.schedulableClips.isEmpty {
                ContentUnavailableView(
                    "No clips to schedule",
                    systemImage: "film",
                    description: Text("Upload a video first, then schedule it here.")
                )
                .frame(width: 460, height: 180)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    labeled("CLIP") {
                        Picker("", selection: $clipId) {
                            ForEach(model.schedulableClips) { clip in
                                Text(clip.title).tag(Optional(clip.id))
                            }
                        }
                        .labelsHidden()
                    }

                    labeled("PLATFORM") { platformChips }

                    HStack(spacing: 16) {
                        labeled("TIME · \(TimeZone.current.identifier)") {
                            DatePicker("", selection: $time, displayedComponents: [.hourAndMinute])
                                .labelsHidden()
                        }
                        labeled("NOTIFY") {
                            Picker("", selection: $notifyProfileId) {
                                Text("No one").tag(UUID?.none)
                                ForEach(model.orgMembers) { member in
                                    Text(member.displayName ?? "Member").tag(Optional(member.id))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                    }

                    labeled("CAPTION — the post text, copied at post time") {
                        VStack(alignment: .trailing, spacing: 3) {
                            TextEditor(text: $caption)
                                .font(.system(size: 12.5))
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .frame(height: 64)
                                .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
                                .overlay(RoundedRectangle(cornerRadius: BCLTheme.radiusControl).strokeBorder(BCLTheme.border, lineWidth: 1))
                            Text("\(caption.count)/\(captionLimit)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(caption.count > captionLimit ? BCLTheme.errorText : BCLTheme.textTertiary)
                        }
                    }

                    labeled("NOTES — internal, never pasted") {
                        TextField("Optional", text: $notes)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
                            .overlay(RoundedRectangle(cornerRadius: BCLTheme.radiusControl).strokeBorder(BCLTheme.border, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 18)
                .frame(width: 460)
            }

            BCLTheme.hairline.frame(height: 1).padding(.top, 14)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(BCLTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(BCLTheme.control, in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
                    .keyboardShortcut(.cancelAction)
                Button {
                    if let clipId {
                        let when = combine(day: day, time: time)
                        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            await model.add(
                                clipId: clipId, platform: platform, at: when,
                                caption: trimmedCaption.isEmpty ? nil : trimmedCaption,
                                notes: notes.isEmpty ? nil : notes,
                                notifyProfileId: notifyProfileId
                            )
                        }
                    }
                    dismiss()
                } label: {
                    Text("Add")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                        .background(BCLTheme.accent, in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(clipId == nil)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(BCLTheme.raised)
    }

    private func labeled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(BCLTheme.textLabel)
            content()
        }
    }

    /// Segmented platform chips — the one place platform color gets loud
    /// (2px brand-color border on the selection).
    private var platformChips: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(Platform.allCases, id: \.self) { p in
                Button {
                    platform = p
                } label: {
                    HStack(spacing: 5) {
                        PlatformBadge(p, size: 14)
                        Text(p.displayName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(BCLTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
                    .overlay(
                        RoundedRectangle(cornerRadius: BCLTheme.radiusControl)
                            .strokeBorder(platform == p ? p.brandColor : BCLTheme.hairline, lineWidth: platform == p ? 2 : 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
