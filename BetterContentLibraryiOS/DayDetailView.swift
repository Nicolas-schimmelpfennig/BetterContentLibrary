//
//  DayDetailView.swift
//  BetterContentLibrary (iOS)
//
//  The push-notification landing screen (design 1p). The day's posts sort by
//  urgency: the next planned one expands into a full card — amber header,
//  caption with one-tap Copy, Save to Photos (primary) and "Posted ✓" —
//  while later items stay compact and completed ones dim with a teal seal.
//

import SwiftUI
import BetterContentCore

struct DayDetailSheet: View {
    let day: Date
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false
    @State private var expandedId: UUID?

    private var schedule: ScheduleModel { model.schedule }

    /// Urgency order: planned first (soonest on top), then skipped, then posted.
    private var posts: [Schedule] {
        schedule.schedules(on: day).sorted { a, b in
            if a.status == b.status { return a.scheduledAt < b.scheduledAt }
            return rank(a.status) < rank(b.status)
        }
    }

    private func rank(_ status: ScheduleStatus) -> Int {
        switch status {
        case .planned: return 0
        case .skipped: return 1
        case .posted: return 2
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if posts.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing scheduled", systemImage: "calendar")
                    } description: {
                        Text("No posts scheduled for this day yet.")
                    } actions: {
                        Button("Schedule a Post") { isAdding = true }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(posts) { post in
                                if isExpanded(post) {
                                    ScheduledPostCard(post: post, model: model)
                                } else {
                                    compactRow(post)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(BCLTheme.well)
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $isAdding) { AddScheduleSheet(day: day, model: schedule) }
        }
        .preferredColorScheme(.dark)
    }

    /// The tapped card wins; otherwise the first planned post expands.
    private func isExpanded(_ post: Schedule) -> Bool {
        if let expandedId { return post.id == expandedId }
        return post.id == posts.first(where: { $0.status == .planned })?.id
    }

    private func compactRow(_ post: Schedule) -> some View {
        Button {
            expandedId = post.id
        } label: {
            HStack(spacing: 8) {
                PlatformBadge(post.platform, size: 16)
                Text(schedule.clip(for: post)?.title ?? "Clip")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(post.status == .posted || post.status == .skipped
                                     ? BCLTheme.textTertiary : BCLTheme.textPrimary)
                    .strikethrough(post.status == .skipped)
                    .lineLimit(1)
                Spacer()
                if post.status == .posted {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(ClipDisplayStatus.posted.color)
                }
                Text(post.scheduledAt.formatted(.dateTime.hour().minute()))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(BCLTheme.textLabel)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: BCLTheme.radiusCard))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: BCLTheme.radiusCard, bottomLeading: BCLTheme.radiusCard)
                )
                .fill(post.status.color)
                .frame(width: 3)
            }
            .overlay(RoundedRectangle(cornerRadius: BCLTheme.radiusCard).strokeBorder(BCLTheme.hairline, lineWidth: 1))
            .opacity(post.status == .posted ? 0.6 : 1)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Expanded card

private enum DownloadPhase: Equatable {
    case idle
    case working(String)
    case saved
    case failed(String)

    var isWorking: Bool { if case .working = self { return true } else { return false } }
}

private struct ScheduledPostCard: View {
    let post: Schedule
    let model: AppModel

    @State private var previewClip: Clip?
    @State private var phase: DownloadPhase = .idle
    @State private var copiedCaption = false

    private var schedule: ScheduleModel { model.schedule }
    private var clip: Clip? { schedule.clip(for: post) }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                thumbnail
                Text(clip?.title ?? "Untitled")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(BCLTheme.textPrimary)

                if let caption = post.caption, !caption.isEmpty {
                    captionBlock(caption)
                }
                if let notes = post.notes, !notes.isEmpty {
                    notesBlock(notes)
                }
                metadata
                actions
            }
            .padding(14)
        }
        .background(BCLTheme.content)
        .clipShape(RoundedRectangle(cornerRadius: BCLTheme.radiusSheet))
        .overlay(RoundedRectangle(cornerRadius: BCLTheme.radiusSheet).strokeBorder(headerColor.opacity(0.4), lineWidth: 1))
        .fullScreenCover(item: $previewClip) { ClipPreviewView(clip: $0, model: model) }
    }

    private var headerColor: Color { post.status.color }

    private var header: some View {
        HStack(spacing: 8) {
            PlatformBadge(post.platform, size: 16)
            Text(headerText)
                .font(.system(size: 11, weight: .bold))
                .kerning(0.5)
                .foregroundStyle(headerColor)
            Spacer()
            Text(post.scheduledAt.formatted(.dateTime.hour().minute()))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(headerColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(headerColor.opacity(0.14))
    }

    private var headerText: String {
        switch post.status {
        case .posted: return "POSTED"
        case .skipped: return "SKIPPED"
        case .planned:
            let minutes = Int(post.scheduledAt.timeIntervalSinceNow / 60)
            if minutes <= 0 { return "DUE NOW · \(post.platform.displayName.uppercased())" }
            if minutes < 120 { return "DUE IN \(minutes) MIN · \(post.platform.displayName.uppercased())" }
            return "PLANNED · \(post.platform.displayName.uppercased())"
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let clip {
            Button {
                if clip.isPlayable { previewClip = clip }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: BCLTheme.radiusCard).fill(BCLTheme.well)
                    ClipThumbnailView(clip: clip, loader: model.thumbnails, skim: model.skim, skimEnabled: false)
                        .padding(6)
                }
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: BCLTheme.radiusCard))
                .overlay {
                    if clip.isPlayable {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(radius: 4)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!clip.isPlayable)
        }
    }

    /// The post text, written at scheduling time — one-tap Copy for pasting
    /// into the platform at post time.
    private func captionBlock(_ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CAPTION")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(BCLTheme.textLabel)
                Spacer()
                Button {
                    UIPasteboard.general.string = caption
                    copiedCaption = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedCaption = false
                    }
                } label: {
                    Label(copiedCaption ? "Copied" : "Copy", systemImage: copiedCaption ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copiedCaption ? ClipDisplayStatus.ready.color : BCLTheme.accent)
                }
                .buttonStyle(.plain)
            }
            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(BCLTheme.textPrimary.opacity(0.85))
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BCLTheme.well, in: RoundedRectangle(cornerRadius: BCLTheme.radiusCard))
    }

    private func notesBlock(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOTES — INTERNAL")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(BCLTheme.textLabel)
            Text(notes)
                .font(.system(size: 12.5))
                .foregroundStyle(BCLTheme.textSecondary)
        }
    }

    private var metadata: some View {
        VStack(spacing: 8) {
            if let uploader = clip.flatMap({ schedule.uploaderName(for: $0) }) {
                metaRow("Uploaded by", uploader, mono: false)
            }
            if let duration = clip?.durationFormatted {
                metaRow("Duration", duration, mono: true)
            }
            if let resolution = clip?.resolutionFormatted {
                metaRow("Resolution", resolution, mono: true)
            }
        }
    }

    private func metaRow(_ label: String, _ value: String, mono: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(BCLTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(BCLTheme.textPrimary)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 8) {
            switch phase {
            case .saved:
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(ClipDisplayStatus.ready.color)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(BCLTheme.errorText)
                    .multilineTextAlignment(.center)
            default:
                EmptyView()
            }

            Button(action: download) {
                HStack(spacing: 8) {
                    if case .working(let label) = phase {
                        ProgressView().controlSize(.small).tint(.white)
                        Text(label)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                        Text(phase == .saved ? "Save Again" : "Save to Photos")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(BCLTheme.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(clip?.isPlayable != true || phase.isWorking)
            .opacity(clip?.isPlayable != true ? 0.5 : 1)

            if post.status == .planned {
                Button {
                    Task { await schedule.markPosted(post.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                        Text("Posted ✓")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ClipDisplayStatus.posted.color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(ClipDisplayStatus.posted.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func download() {
        guard let clip else { return }
        phase = .working("Downloading…")
        Task {
            do {
                let url = try await model.downloadVideoFile(for: clip)
                phase = .working("Saving…")
                try await PhotoSaver.saveVideo(at: url)
                try? FileManager.default.removeItem(at: url)
                phase = .saved
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
