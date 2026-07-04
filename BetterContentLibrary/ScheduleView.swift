//
//  ScheduleView.swift
//  BetterContentLibrary
//

import SwiftUI
import AppKit
import BetterContentCore

/// Month calendar (top) with a detail panel for the selected day (bottom).
/// Drag a chip to another day to reschedule, drop a library clip on a day to
/// schedule it, click a day to inspect it below, or double-click / "+" to add.
struct ScheduleView: View {
    let model: AppModel

    @State private var editorTarget: EditorTarget?
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private var schedule: ScheduleModel { model.schedule }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 1), count: 7)
    private let calendar = Calendar.current

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                Divider()
                weekdayHeader
                calendarGrid
                    .frame(maxHeight: .infinity)
                Divider()
                DayDetailPanel(
                    day: selectedDay,
                    model: model,
                    onAdd: { editorTarget = EditorTarget(day: selectedDay) },
                    onEdit: { editorTarget = EditorTarget(day: selectedDay, schedule: $0) }
                )
                .frame(height: max(200, geo.size.height * 0.35))
            }
        }
        .task { await schedule.loadIfNeeded() }
        .sheet(item: $editorTarget) { target in
            if let existing = target.schedule {
                ScheduleEditorSheet(model: model, editing: existing)
            } else {
                ScheduleEditorSheet(model: model, clipId: target.clipId, day: target.day)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(schedule.monthTitle).font(.title2.bold())
            Spacer()
            Button("Today") {
                schedule.goToToday()
                selectedDay = calendar.startOfDay(for: Date())
            }
            Button { schedule.step(months: -1) } label: { Image(systemName: "chevron.left") }
            Button { schedule.step(months: 1) } label: { Image(systemName: "chevron.right") }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
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
        GeometryReader { geo in
            // 8pt outer padding ×2 plus 5 row gaps of 1pt; the rest splits
            // across the 6 rows so the grid always fills its space exactly.
            let cellHeight = max(48, (geo.size.height - 16 - 5) / 6)
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(schedule.gridDays, id: \.self) { day in
                    DayCell(
                        day: day,
                        model: schedule,
                        height: cellHeight,
                        isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                        onSelect: { selectedDay = calendar.startOfDay(for: day) },
                        onAdd: {
                            selectedDay = calendar.startOfDay(for: day)
                            editorTarget = EditorTarget(day: day)
                        },
                        onScheduleClip: { clipId in
                            selectedDay = calendar.startOfDay(for: day)
                            editorTarget = EditorTarget(day: day, clipId: clipId)
                        }
                    )
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.12))
        }
    }

    struct EditorTarget: Identifiable {
        let id = UUID()
        let day: Date
        var clipId: UUID?
        /// When set, the editor opens on this schedule instead of creating.
        var schedule: Schedule?
    }
}

// MARK: - Day cell

private struct DayCell: View {
    let day: Date
    let model: ScheduleModel
    let height: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void
    let onAdd: () -> Void
    let onScheduleClip: (UUID) -> Void

    @State private var isHovering = false
    @State private var isDropTargeted = false

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
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .background(inMonth ? Color(nsColor: .controlBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.12))
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2)
            } else if isSelected {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.5))
            }
        }
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { onAdd() }
        .onTapGesture { onSelect() }
        // Both calendar chips and library clips drag UUID strings; an id that
        // matches an existing schedule is a chip move, anything else is a clip
        // being dropped in from the library — open the editor prefilled.
        .dropDestination(for: String.self) { ids, _ in
            for id in ids {
                guard let uuid = UUID(uuidString: id) else { continue }
                if model.items.contains(where: { $0.id == uuid }) {
                    Task { await model.reschedule(id: uuid, toDay: day) }
                } else {
                    onScheduleClip(uuid)
                }
            }
            return true
        } isTargeted: { isDropTargeted = $0 }
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
            Circle().fill(schedule.platform.brandColor).frame(width: 6, height: 6)
            Text(timeText)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 10))
                .strikethrough(schedule.status == .skipped)
                .lineLimit(1)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(schedule.platform.brandColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }

    private var timeText: String {
        schedule.scheduledAt.formatted(.dateTime.hour().minute())
    }
}

// MARK: - Selected-day detail panel

/// Everything scheduled on the selected day, as rows under the calendar.
private struct DayDetailPanel: View {
    let day: Date
    let model: AppModel
    let onAdd: () -> Void
    let onEdit: (Schedule) -> Void

    @State private var previewClip: Clip?

    private var schedule: ScheduleModel { model.schedule }
    private var posts: [Schedule] {
        schedule.schedules(on: day).sorted { $0.scheduledAt < $1.scheduledAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(day.formatted(.dateTime.weekday(.wide).month().day()))
                    .font(.headline)
                if !posts.isEmpty {
                    Text("\(posts.count) post\(posts.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onAdd) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Schedule a post on this day")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if posts.isEmpty {
                VStack(spacing: 10) {
                    Text("Nothing scheduled")
                        .foregroundStyle(.secondary)
                    Button("Schedule a Post") { onAdd() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(posts) { post in
                            ScheduledPostRow(
                                post: post,
                                model: model,
                                onPreview: { previewClip = $0 },
                                onEdit: { onEdit(post) }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .sheet(item: $previewClip) { clip in
            ClipPreviewView(clip: clip, model: model)
        }
    }
}

/// One scheduled post: thumbnail, time, platform, title, caption, status.
/// Clicking the row opens it in the schedule editor; the thumbnail previews.
private struct ScheduledPostRow: View {
    let post: Schedule
    let model: AppModel
    let onPreview: (Clip) -> Void
    let onEdit: () -> Void

    @State private var poster: NSImage?

    private var schedule: ScheduleModel { model.schedule }
    private var clip: Clip? { schedule.clip(for: post) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
            details
            Spacer(minLength: 0)
            statusBadge
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .contextMenu { menu }
    }

    private var thumbnail: some View {
        Button {
            if let clip, clip.isPlayable { onPreview(clip) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let poster {
                    Image(nsImage: poster)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
                if clip?.isPlayable == true {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(radius: 2)
                } else if poster == nil {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Preview clip")
        .task(id: clip?.id) {
            poster = nil
            if let clip { poster = await model.thumbnails.image(for: clip) }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(post.scheduledAt.formatted(.dateTime.hour().minute()))
                    .font(.callout.weight(.semibold).monospacedDigit())
                Circle().fill(post.platform.brandColor).frame(width: 7, height: 7)
                Text(post.platform.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(clip?.title ?? "Clip unavailable")
                .font(.callout.weight(.medium))
                .strikethrough(post.status == .skipped)
                .lineLimit(1)
            if let caption = post.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let id = post.notifyProfileId,
               let name = schedule.profilesById[id]?.displayName {
                Label(name, systemImage: "bell")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusBadge: some View {
        Text(post.status.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(post.status.color)
            .background(post.status.color.opacity(0.15), in: Capsule())
    }

    @ViewBuilder
    private var menu: some View {
        Button("Edit…") { onEdit() }
        Button("Preview") { if let clip { onPreview(clip) } }
            .disabled(clip?.isPlayable != true)
        Divider()
        if post.status == .planned {
            Button("Mark as Posted") { Task { await schedule.markPosted(post.id) } }
            Button("Skip") { Task { await schedule.skip(post.id) } }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await schedule.delete(post.id) } }
    }
}
