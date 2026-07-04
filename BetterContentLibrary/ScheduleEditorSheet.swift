//
//  ScheduleEditorSheet.swift
//  BetterContentLibrary
//
//  The scheduling pop-up. Opened from the calendar (a day's "+" or dropping a
//  library clip on a day) and from the library ("Schedule…" in the context
//  menu). Clip and date prefill when known; every field stays editable.
//
//  Layout: clip preview + picker on the left; platform chips, date/time,
//  caption, and the internal notify/notes group on the right.
//

import SwiftUI
import AppKit
import BetterContentCore

struct ScheduleEditorSheet: View {
    private let model: AppModel
    /// When set, the sheet edits this schedule in place instead of creating.
    private let existing: Schedule?

    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.hiddenPlatforms) private var hiddenPlatformsRaw = ""
    @State private var clipId: UUID?
    @State private var platform: Platform = .instagram
    @State private var scheduledAt: Date
    @State private var caption = ""
    @State private var notes = ""
    @State private var notifyProfileId: UUID?
    @State private var poster: NSImage?
    @State private var previewClip: Clip?

    private var schedule: ScheduleModel { model.schedule }

    /// - Parameters:
    ///   - clipId: preselects the clip (right-click / drag from library); nil
    ///     lets the user pick.
    ///   - day: prefills the date (drag onto a day / a day's "+"); nil defaults
    ///     to tomorrow. Time defaults to 9:00 AM either way.
    init(model: AppModel, clipId: UUID? = nil, day: Date? = nil) {
        self.model = model
        existing = nil
        _clipId = State(initialValue: clipId ?? model.schedule.schedulableClips.first?.id)
        _notifyProfileId = State(initialValue: model.schedule.currentProfileId)

        // Default to the first platform the user hasn't hidden in Settings.
        let hiddenRaw = UserDefaults.standard.string(forKey: SettingsKey.hiddenPlatforms) ?? ""
        _platform = State(initialValue: Platform.visible(hiddenRaw: hiddenRaw).first ?? .instagram)

        let calendar = Calendar.current
        let base = day ?? calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        var comps = calendar.dateComponents([.year, .month, .day], from: base)
        comps.hour = 9
        comps.minute = 0
        _scheduledAt = State(initialValue: calendar.date(from: comps) ?? base)
    }

    /// Edit an existing scheduled post: every field prefills from it, and
    /// saving updates the schedule in place.
    init(model: AppModel, editing schedule: Schedule) {
        self.model = model
        existing = schedule
        _clipId = State(initialValue: schedule.clipId)
        _platform = State(initialValue: schedule.platform)
        _scheduledAt = State(initialValue: schedule.scheduledAt)
        _caption = State(initialValue: schedule.caption ?? "")
        _notes = State(initialValue: schedule.notes ?? "")
        _notifyProfileId = State(initialValue: schedule.notifyProfileId)
    }

    /// The preselected clip is offered even if it fell outside the capped
    /// schedulable list, so a drag from the library always resolves.
    private var clipChoices: [Clip] {
        var clips = schedule.schedulableClips
        if let clipId, !clips.contains(where: { $0.id == clipId }),
           let extra = schedule.clipsById[clipId] {
            clips.insert(extra, at: 0)
        }
        return clips
    }

    private var selectedClip: Clip? {
        clipId.flatMap { schedule.clipsById[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            if clipChoices.isEmpty {
                ContentUnavailableView(
                    "No clips to schedule",
                    systemImage: "film",
                    description: Text("Add a video to the library first, then schedule it here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    clipColumn
                        .frame(width: 300)
                    Divider()
                    detailColumn
                }
                .frame(maxHeight: .infinity)
            }

            Divider()
            footer
        }
        .frame(width: 980, height: 720)
        .sheet(item: $previewClip) { clip in
            ClipPreviewView(clip: clip, model: model)
        }
        .task(id: clipId) {
            poster = nil
            if let clip = selectedClip {
                poster = await model.thumbnails.image(for: clip)
            }
        }
    }

    // MARK: Left column — clip preview & picker

    private var clipColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            posterPreview

            if let clip = selectedClip {
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    if let uploader = schedule.uploaderName(for: clip) {
                        Text("Uploaded by \(uploader)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !clipMetadata.isEmpty {
                        Text(clipMetadata)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Clip")
                Picker("Clip", selection: $clipId) {
                    ForEach(clipChoices) { clip in
                        Text(clip.title).tag(Optional(clip.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
    }

    private var posterPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            if let poster {
                // .fit, never .fill: a portrait poster under .fill reports the
                // covering size and inflates the whole sheet past its frame.
                Image(nsImage: poster)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text("\(aspectLabel) · clip preview")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            }

            if selectedClip?.isPlayable == true {
                Button {
                    previewClip = selectedClip
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }
                .buttonStyle(.plain)
                .help("Preview clip")
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .bottomTrailing) {
            if let duration = selectedClip?.durationFormatted {
                Text(duration)
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
    }

    private var aspectLabel: String {
        switch selectedClip?.orientation {
        case .horizontal: return "16:9"
        case .vertical: return "9:16"
        case .square: return "1:1"
        case nil: return "clip"
        }
    }

    /// "1920 × 1080 · MP4 · 24.1 MB" from whatever the clip actually has.
    private var clipMetadata: String {
        guard let clip = selectedClip else { return "" }
        var parts: [String] = []
        if let w = clip.width, let h = clip.height { parts.append("\(w) × \(h)") }
        if let ext = clip.r2Key.map({ ($0 as NSString).pathExtension }), !ext.isEmpty {
            parts.append(ext.uppercased())
        }
        if let size = clip.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Right column — platform, when, caption, internal

    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                platformSection
                whenSection
                captionSection
                internalSection
            }
            .padding(20)
        }
    }

    /// The chips on offer: what Settings → Platforms leaves visible, plus the
    /// current selection even if since hidden (editing an old post must still
    /// show its platform), in canonical order.
    private var platformChoices: [Platform] {
        let visible = Platform.visible(hiddenRaw: hiddenPlatformsRaw)
        if visible.contains(platform) { return visible }
        return Platform.allCases.filter { visible.contains($0) || $0 == platform }
    }

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Platform")
            FlowLayout(spacing: 8) {
                ForEach(platformChoices, id: \.self) { p in
                    PlatformChip(platform: p, isSelected: platform == p) {
                        platform = p
                    }
                }
            }
        }
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("When")
            HStack(spacing: 12) {
                fieldBox("Date") {
                    DatePicker("Date", selection: $scheduledAt, displayedComponents: [.date])
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                }
                fieldBox("Time") {
                    DatePicker("Time", selection: $scheduledAt, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                }
            }
            Text("Posts \(scheduledAt.formatted(.relative(presentation: .named))) · \(TimeZone.current.identifier)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("Caption")
                Spacer()
                Text(captionCount)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(captionOverLimit ? .red : .secondary)
            }

            editor(text: $caption, placeholder: "The post text for \(platform.displayName)…", minHeight: 140)

            HStack {
                Text("Public — the post text shown on \(platform.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(caption, forType: .string)
                }
                .disabled(caption.isEmpty)
            }
        }
    }

    /// Public caption length limit per platform, for the counter.
    private var captionLimit: Int? {
        switch platform {
        case .instagram, .tiktok: return 2200
        case .youtube, .youtubeShorts: return 5000
        case .x: return 280
        case .facebook: return 63_206
        case .linkedin: return 3000
        case .other: return nil
        }
    }

    private var captionOverLimit: Bool {
        if let limit = captionLimit { return caption.count > limit }
        return false
    }

    private var captionCount: String {
        if let limit = captionLimit {
            return "\(caption.count.formatted()) / \(limit.formatted())"
        }
        return caption.count.formatted()
    }

    private var internalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                sectionLabel("Internal")
                Text("· only your team sees this")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text("Notify")
                Spacer()
                Picker("Notify", selection: $notifyProfileId) {
                    Text("No one").tag(UUID?.none)
                    ForEach(schedule.orgMembers) { member in
                        Text(member.displayName ?? "Member").tag(Optional(member.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                editor(text: $notes, placeholder: "Context for whoever posts this…", minHeight: 64)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("⎋ cancels · ↩ \(existing == nil ? "schedules" : "saves")")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(existing == nil ? "Schedule" : "Save") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(clipId == nil)
        }
        .padding()
        .background(.bar)
    }

    private func save() {
        guard let clipId else { return }
        let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let existing {
                await schedule.update(
                    id: existing.id,
                    clipId: clipId,
                    platform: platform,
                    at: scheduledAt,
                    caption: trimmedCaption.isEmpty ? nil : trimmedCaption,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    notifyProfileId: notifyProfileId
                )
            } else {
                await schedule.add(
                    clipId: clipId,
                    platform: platform,
                    at: scheduledAt,
                    caption: trimmedCaption.isEmpty ? nil : trimmedCaption,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    notifyProfileId: notifyProfileId
                )
            }
        }
        dismiss()
    }

    // MARK: Shared bits

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }

    /// Boxed labeled field, like the mock's DATE / TIME cells.
    private func fieldBox<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel(label)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Bordered multi-line text box with a placeholder (TextEditor has none).
    private func editor(text: Binding<String>, placeholder: String, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Platform chip

private struct PlatformChip: View {
    let platform: Platform
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(platform.brandColor).frame(width: 8, height: 8)
                Text(platform.displayName)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow layout (wrapping chips)

/// Left-aligned wrapping layout: rows fill until `maxWidth`, then wrap.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layoutRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in layoutRows(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.indices.append(index)
            current.height = max(current.height, size.height)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
