//
//  ScheduleScreen.swift
//  BetterContentLibrary (iOS)
//
//  Month calendar: an "Up next" card answers "what do I post next?" before any
//  tapping; day cells carry status dots; the selected day's agenda stays pinned
//  below the grid. Tapping an agenda row (or the up-next card) opens Day detail.
//  Styled with system semantic colors so it follows light/dark natively.
//

import SwiftUI
import BetterContentCore

struct ScheduleScreen: View {
    let model: AppModel

    @State private var selectedDay = Date()
    @State private var detailDay: DaySelection?
    @State private var addDay: DaySelection?
    @State private var editingPost: Schedule?
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
            .background(Color(.systemGroupedBackground))
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
            .task { await schedule.loadIfNeeded() }
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
                ScheduleFormSheet(day: selection.date, model: schedule)
            }
            .sheet(item: $editingPost) { post in
                ScheduleFormSheet(editing: post, model: schedule)
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
                            .font(.caption2.weight(.bold))
                            .kerning(0.6)
                            .foregroundStyle(.tint)
                        Text(schedule.clip(for: next)?.title ?? "Clip")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            PlatformBadge(next.platform, size: 13)
                            Text(next.scheduledAt.formatted(.dateTime.hour().minute()))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
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
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
                    .font(.footnote.weight(isToday ? .bold : .medium))
                    .foregroundStyle(
                        isToday ? Color.white
                        : isSelected ? Color.accentColor
                        : inMonth ? Color.primary
                        : Color.secondary.opacity(0.5)
                    )
                    .frame(width: 24, height: 24)
                    .background {
                        if isToday {
                            Circle().fill(Color.accentColor)
                        } else if isSelected {
                            Circle()
                                .fill(Color.accentColor.opacity(0.15))
                                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
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
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    addDay = DaySelection(date: selectedDay)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.small)
            }

            let daySchedules = schedule.schedules(on: selectedDay)
            if daySchedules.isEmpty {
                Text("Nothing scheduled")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
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
                            Button { editingPost = sched } label: {
                                Label("Edit…", systemImage: "pencil")
                            }
                            if sched.status == .planned {
                                Button("Mark as Posted") { Task { await schedule.markPosted(sched.id) } }
                                Button("Skip") { Task { await schedule.skip(sched.id) } }
                            }
                            Divider()
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

    /// Agenda row: 3px schedule-status border, platform monogram, title, time.
    private func agendaRow(_ sched: Schedule) -> some View {
        HStack(spacing: 8) {
            PlatformBadge(sched.platform, size: 16)
            Text(schedule.clip(for: sched)?.title ?? "Clip")
                .font(.footnote.weight(.medium))
                .foregroundStyle(sched.status == .skipped ? Color.secondary : Color.primary)
                .strikethrough(sched.status == .skipped)
                .lineLimit(1)
            Spacer()
            Text(sched.scheduledAt.formatted(.dateTime.hour().minute()))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 8, bottomLeading: 8))
                .fill(sched.status.color)
                .frame(width: 3)
        }
    }
}

// MARK: - Schedule form (create & edit)

struct ScheduleFormSheet: View {
    let model: ScheduleModel
    /// When set, the sheet edits this schedule in place instead of creating.
    private let existing: Schedule?

    @Environment(\.dismiss) private var dismiss
    @State private var clipId: UUID?
    @State private var platform: Platform = .instagram
    @State private var scheduledAt: Date
    @State private var caption = ""
    @State private var notes = ""
    @State private var notifyProfileId: UUID?

    /// Create a new post, prefilled to `day` at 9:00 (every field editable).
    init(day: Date, model: ScheduleModel) {
        self.model = model
        existing = nil
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        comps.hour = 9
        comps.minute = 0
        _scheduledAt = State(initialValue: Calendar.current.date(from: comps) ?? day)
        _clipId = State(initialValue: model.schedulableClips.first?.id)
        _notifyProfileId = State(initialValue: model.currentProfileId)
    }

    /// Edit an existing scheduled post: every field prefills from it, and
    /// saving updates the schedule in place.
    init(editing schedule: Schedule, model: ScheduleModel) {
        self.model = model
        existing = schedule
        _clipId = State(initialValue: schedule.clipId)
        _platform = State(initialValue: schedule.platform)
        _scheduledAt = State(initialValue: schedule.scheduledAt)
        _caption = State(initialValue: schedule.caption ?? "")
        _notes = State(initialValue: schedule.notes ?? "")
        _notifyProfileId = State(initialValue: schedule.notifyProfileId)
    }

    private var captionLimit: Int {
        switch platform {
        case .x: return 280
        case .youtube, .youtubeShorts: return 5000
        default: return 2200
        }
    }

    /// The preselected clip is offered even if it fell outside the capped
    /// schedulable list, so editing an old post always resolves its clip.
    private var clipChoices: [Clip] {
        var clips = model.schedulableClips
        if let clipId, !clips.contains(where: { $0.id == clipId }),
           let extra = model.clipsById[clipId] {
            clips.insert(extra, at: 0)
        }
        return clips
    }

    var body: some View {
        NavigationStack {
            Group {
                if clipChoices.isEmpty {
                    ContentUnavailableView(
                        "No clips to schedule",
                        systemImage: "film",
                        description: Text("Upload a video first, then schedule it here.")
                    )
                } else {
                    Form {
                        Section {
                            Picker("Clip", selection: $clipId) {
                                ForEach(clipChoices) { clip in
                                    Text(clip.title).tag(Optional(clip.id))
                                }
                            }
                        }
                        Section("Platform") {
                            platformChips
                                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        }
                        Section {
                            DatePicker("When", selection: $scheduledAt,
                                       displayedComponents: [.date, .hourAndMinute])
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
                            Text("\(caption.count)/\(captionLimit) · copied at post time from the day's card")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(caption.count > captionLimit ? .red : .secondary)
                        }
                        Section {
                            TextField("Notes — context for whoever posts this", text: $notes, axis: .vertical)
                                .lineLimit(2...6)
                        } footer: {
                            Text("Internal — only your team sees this")
                        }
                    }
                }
            }
            .navigationTitle(existing == nil
                             ? scheduledAt.formatted(.dateTime.weekday().month().day())
                             : "Edit Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Save") { save() }
                        .disabled(clipId == nil)
                }
            }
        }
    }

    private func save() {
        guard let clipId else { return }
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let existing {
                await model.update(
                    id: existing.id, clipId: clipId, platform: platform, at: scheduledAt,
                    caption: trimmedCaption.isEmpty ? nil : trimmedCaption,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    notifyProfileId: notifyProfileId
                )
            } else {
                await model.add(
                    clipId: clipId, platform: platform, at: scheduledAt,
                    caption: trimmedCaption.isEmpty ? nil : trimmedCaption,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    notifyProfileId: notifyProfileId
                )
            }
        }
        dismiss()
    }

    /// Equal-width platform chips; selection gets the 2px brand-color border.
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
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(platform == p ? p.brandColor : Color.clear, lineWidth: 2)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
