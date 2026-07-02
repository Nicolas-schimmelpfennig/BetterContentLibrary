//
//  ScheduleScreen.swift
//  BetterContentLibrary (iOS)
//
//  Month calendar (design 1o): an "Up next" card answers "what do I post
//  next?" before any tapping; day cells carry status dots; the selected day's
//  agenda stays pinned below the grid. Tapping an agenda row (or the up-next
//  card) opens Day detail.
//

import SwiftUI
import BetterContentCore

struct ScheduleScreen: View {
    let model: AppModel

    @State private var selectedDay = Date()
    @State private var detailDay: DaySelection?
    @State private var addDay: DaySelection?
    @State private var deepLink = DeepLinkCenter.shared

    private var schedule: ScheduleModel { model.schedule }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    upNextCard
                    calendar
                    agenda
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(BCLTheme.well)
            .navigationTitle(schedule.monthTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { schedule.step(months: -1) } label: { Image(systemName: "chevron.left") }
                    Button("Today") {
                        schedule.goToToday()
                        selectedDay = Date()
                    }
                    Button { schedule.step(months: 1) } label: { Image(systemName: "chevron.right") }
                }
            }
            .task { await schedule.load() }
            // Open the relevant day's card when a tapped notification deep-links here
            // (covers both cold launch and while running).
            .task(id: deepLink.scheduleDay) {
                if let day = deepLink.scheduleDay {
                    selectedDay = day
                    detailDay = DaySelection(date: day)
                    deepLink.scheduleDay = nil
                }
            }
            .sheet(item: $detailDay) { selection in
                DayDetailSheet(day: selection.date, model: model)
            }
            .sheet(item: $addDay) { selection in
                AddScheduleSheet(day: selection.date, model: schedule)
            }
        }
    }

    struct DaySelection: Identifiable {
        let id = UUID()
        let date: Date
    }

    // MARK: Up next (due within 24 h)

    @ViewBuilder
    private var upNextCard: some View {
        if let next = schedule.upNext {
            Button {
                detailDay = DaySelection(date: next.scheduledAt)
            } label: {
                HStack(spacing: 10) {
                    thumbWell(for: schedule.clip(for: next))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("UP NEXT · \(relative(next.scheduledAt))")
                            .font(.system(size: 10, weight: .bold))
                            .kerning(0.6)
                            .foregroundStyle(BCLTheme.accentText)
                        Text(schedule.clip(for: next)?.title ?? "Clip")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(BCLTheme.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            PlatformBadge(next.platform, size: 13)
                            Text(next.scheduledAt.formatted(.dateTime.hour().minute()))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(BCLTheme.textPrimary.opacity(0.6))
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BCLTheme.accentText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [BCLTheme.accent.opacity(0.16), BCLTheme.accent.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: BCLTheme.radiusSheet)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BCLTheme.radiusSheet)
                        .strokeBorder(BCLTheme.accent.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func thumbWell(for clip: Clip?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(.black)
            if let clip {
                ClipThumbnailView(clip: clip, loader: model.thumbnails, skim: model.skim, skimEnabled: false)
                    .padding(2)
            }
        }
        .frame(width: 30, height: 46)
    }

    private func relative(_ date: Date) -> String {
        let minutes = Int(date.timeIntervalSinceNow / 60)
        if minutes <= 0 { return "NOW" }
        if minutes < 60 { return "IN \(minutes) MIN" }
        return "IN \(minutes / 60) H \(minutes % 60) MIN"
    }

    // MARK: Calendar (dot cells)

    private var calendar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(schedule.weekdaySymbols, id: \.self) { symbol in
                    Text(String(symbol.prefix(1)).uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BCLTheme.textPrimary.opacity(0.35))
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(schedule.gridDays, id: \.self) { day in
                    dayCell(day)
                }
            }
        }
        .padding(10)
        .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: BCLTheme.radiusSheet))
        .overlay(RoundedRectangle(cornerRadius: BCLTheme.radiusSheet).strokeBorder(BCLTheme.hairline, lineWidth: 1))
    }

    private func dayCell(_ day: Date) -> some View {
        let cal = Calendar.current
        let inMonth = schedule.isInCurrentMonth(day)
        let isToday = schedule.isToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let daySchedules = schedule.schedules(on: day)

        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 12, weight: isToday ? .bold : .medium))
                    .foregroundStyle(
                        isToday ? .white
                        : isSelected ? BCLTheme.accentText
                        : inMonth ? BCLTheme.textPrimary.opacity(0.75)
                        : BCLTheme.textPrimary.opacity(0.25)
                    )
                    .frame(width: 24, height: 24)
                    .background {
                        if isToday {
                            Circle().fill(BCLTheme.accent)
                        } else if isSelected {
                            Circle()
                                .fill(BCLTheme.accent.opacity(0.2))
                                .overlay(Circle().strokeBorder(BCLTheme.accent, lineWidth: 1.5))
                        }
                    }
                HStack(spacing: 2) {
                    ForEach(Array(daySchedules.prefix(3).enumerated()), id: \.offset) { _, sched in
                        Circle()
                            .fill(sched.status.color)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: String.self) { ids, _ in
            for id in ids where UUID(uuidString: id) != nil {
                Task { await schedule.reschedule(id: UUID(uuidString: id)!, toDay: day) }
            }
            return true
        }
    }

    // MARK: Pinned agenda for the selected day

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(selectedDay.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BCLTheme.textPrimary)
                Spacer()
                Button {
                    addDay = DaySelection(date: selectedDay)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BCLTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(BCLTheme.content, in: Circle())
                        .overlay(Circle().strokeBorder(BCLTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            let daySchedules = schedule.schedules(on: selectedDay)
            if daySchedules.isEmpty {
                Text("Nothing scheduled")
                    .font(.system(size: 12))
                    .foregroundStyle(BCLTheme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                VStack(spacing: 6) {
                    ForEach(daySchedules) { sched in
                        Button {
                            detailDay = DaySelection(date: selectedDay)
                        } label: {
                            agendaRow(sched)
                        }
                        .buttonStyle(.plain)
                        .draggable(sched.id.uuidString)
                        .contextMenu {
                            if sched.status == .planned {
                                Button("Mark as Posted") { Task { await schedule.markPosted(sched.id) } }
                                Button("Skip") { Task { await schedule.skip(sched.id) } }
                                Divider()
                            }
                            Button("Delete", role: .destructive) {
                                Task { await schedule.delete(sched.id) }
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 16)
    }

    /// Same chip anatomy as macOS: 3px status border, monogram, title, mono time.
    private func agendaRow(_ sched: Schedule) -> some View {
        HStack(spacing: 8) {
            PlatformBadge(sched.platform, size: 16)
            Text(schedule.clip(for: sched)?.title ?? "Clip")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(sched.status == .skipped ? BCLTheme.textTertiary : BCLTheme.textPrimary)
                .strikethrough(sched.status == .skipped)
                .lineLimit(1)
            Spacer()
            Text(sched.scheduledAt.formatted(.dateTime.hour().minute()))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BCLTheme.textLabel)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: BCLTheme.radiusCard))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: BCLTheme.radiusCard, bottomLeading: BCLTheme.radiusCard)
            )
            .fill(sched.status.color)
            .frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: BCLTheme.radiusCard).strokeBorder(BCLTheme.hairline, lineWidth: 1))
    }
}

// MARK: - Add Schedule sheet (design 1s)

struct AddScheduleSheet: View {
    let day: Date
    let model: ScheduleModel

    @Environment(\.dismiss) private var dismiss
    @State private var clipId: UUID?
    @State private var platform: Platform = .instagram
    @State private var time: Date
    @State private var caption = ""
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

    private var captionLimit: Int {
        switch platform {
        case .x: return 280
        case .youtube, .youtubeShorts: return 5000
        default: return 2200
        }
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
                        Section {
                            Picker("Clip", selection: $clipId) {
                                ForEach(model.schedulableClips) { clip in
                                    Text(clip.title).tag(Optional(clip.id))
                                }
                            }
                        }
                        Section("Platform") {
                            platformChips
                                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        }
                        Section {
                            DatePicker("Time", selection: $time, displayedComponents: [.hourAndMinute])
                            Picker("Notify", selection: $notifyProfileId) {
                                Text("No one").tag(UUID?.none)
                                ForEach(model.orgMembers) { member in
                                    Text(member.displayName ?? "Member").tag(Optional(member.id))
                                }
                            }
                        }
                        Section {
                            TextField("Caption — the post text", text: $caption, axis: .vertical)
                                .lineLimit(3...8)
                        } footer: {
                            Text("\(caption.count)/\(captionLimit) · copied at post time from Day detail")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(caption.count > captionLimit ? BCLTheme.errorText : BCLTheme.textTertiary)
                        }
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
                    Button("Add") {
                        if let clipId {
                            let when = combine(day: day, time: time)
                            let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await model.add(
                                    clipId: clipId, platform: platform, at: when,
                                    caption: trimmed.isEmpty ? nil : trimmed,
                                    notes: nil, notifyProfileId: notifyProfileId
                                )
                            }
                        }
                        dismiss()
                    }
                    .disabled(clipId == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Equal-width platform chips; selection gets the 2px brand-color border —
    /// the one place platform color gets loud.
    private var platformChips: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(Platform.allCases, id: \.self) { p in
                Button {
                    platform = p
                } label: {
                    VStack(spacing: 4) {
                        PlatformBadge(p, size: 18)
                        Text(p.displayName)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(BCLTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
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
