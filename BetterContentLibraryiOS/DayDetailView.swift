//
//  DayDetailView.swift
//  BetterContentLibrary (iOS)
//
//  Tapping a calendar day shows its scheduled posts as a horizontally swipeable
//  gallery of cards. Each card: title, tappable thumbnail (→ preview), the
//  post's custom cover if one was uploaded, metadata, and a pinned download
//  button that saves the video (and the cover with it) to Photos.
//

import SwiftUI
import BetterContentCore

struct DayDetailSheet: View {
    let day: Date
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false

    private var schedule: ScheduleModel { model.schedule }
    private var posts: [Schedule] {
        schedule.schedules(on: day).sorted { $0.scheduledAt < $1.scheduledAt }
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
                    TabView {
                        ForEach(posts) { post in
                            ScheduledPostCard(post: post, model: model)
                                .padding(.horizontal)
                                .padding(.bottom, posts.count > 1 ? 36 : 12)
                                .padding(.top, 8)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: posts.count > 1 ? .always : .never))
                    .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month().day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAdding = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $isAdding) { ScheduleFormSheet(day: day, model: schedule) }
            .scheduleErrorAlert(schedule)
        }
    }
}

// MARK: - Card

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
    @State private var isEditing = false
    @State private var phase: DownloadPhase = .idle
    @State private var cover: UIImage?
    @State private var coverPhase: DownloadPhase = .idle

    private var schedule: ScheduleModel { model.schedule }
    private var clip: Clip? { schedule.clip(for: post) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(clip?.title ?? "Untitled")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            isEditing = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    thumbnail
                    if post.hasCover { coverSection }
                    metadata
                }
                .padding(20)
            }
            downloadBar
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .fullScreenCover(item: $previewClip) { ClipPreviewView(clip: $0, model: model) }
        .sheet(isPresented: $isEditing) { ScheduleFormSheet(editing: post, model: schedule) }
        // Keyed on the cover key: a replaced cover (new key) reloads.
        .task(id: post.coverKey) {
            cover = nil
            coverPhase = .idle
            if post.hasCover { cover = await schedule.coverImage(for: post) }
        }
    }

    /// The custom thumbnail uploaded with this post, with its own save button
    /// (the main download button saves it too).
    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Thumbnail", systemImage: "photo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                switch coverPhase {
                case .saved:
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .working:
                    ProgressView().controlSize(.small)
                default:
                    Button {
                        saveCover()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(cover == nil)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 80, maxHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if case .failed(let message) = coverPhase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func saveCover() {
        coverPhase = .working("Saving…")
        Task {
            do {
                try await PhotoSaver.saveImage(try await schedule.coverData(for: post))
                coverPhase = .saved
            } catch {
                coverPhase = .failed(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let clip {
            Button {
                if clip.isPlayable { previewClip = clip }
            } label: {
                ClipThumbnailView(clip: clip, loader: model.thumbnails, skim: model.skim, skimEnabled: false)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        if clip.isPlayable {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(radius: 4)
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(!clip.isPlayable)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { Text("Clip unavailable").foregroundStyle(.secondary) }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let uploader = clip.flatMap({ schedule.uploaderName(for: $0) }) {
                MetaRow(icon: "person.fill", label: "Uploaded by", value: uploader)
            }
            MetaRow(icon: "calendar", label: "Scheduled",
                    value: post.scheduledAt.formatted(date: .abbreviated, time: .shortened))
            MetaRow(icon: "square.stack.3d.up.fill", label: "Platform",
                    value: post.platform.displayName, tint: post.platform.brandColor)
            if let duration = clip?.durationFormatted {
                MetaRow(icon: "clock.fill", label: "Duration", value: duration)
            }
            if let resolution = clip?.resolutionFormatted {
                MetaRow(icon: "ratio", label: "Resolution", value: resolution)
            }

            if let caption = post.caption, !caption.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Caption", systemImage: "text.quote")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = caption
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    Text(caption).font(.body).textSelection(.enabled)
                }
                .padding(.top, 4)
            }

            if let notes = post.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Description", systemImage: "text.alignleft")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(notes).font(.body)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var downloadBar: some View {
        VStack(spacing: 8) {
            Divider()
            switch phase {
            case .saved:
                Label(post.hasCover ? "Video & thumbnail saved to Photos" : "Saved to Photos",
                      systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            default:
                EmptyView()
            }

            Button(action: download) {
                HStack(spacing: 8) {
                    if case .working(let label) = phase {
                        ProgressView().controlSize(.small)
                        Text(label)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(post.hasCover ? "Download Video + Thumbnail" : "Download to Photos")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(clip?.isPlayable != true || phase.isWorking)
            .padding([.horizontal, .bottom])
        }
        .background(.bar)
    }

    private func download() {
        guard let clip else { return }
        phase = .working("Downloading…")
        Task {
            do {
                let url = try await model.downloadVideoFile(for: clip)
                defer { try? FileManager.default.removeItem(at: url) }
                var coverData: Data?
                if post.hasCover {
                    phase = .working("Downloading thumbnail…")
                    coverData = try await schedule.coverData(for: post)
                }
                phase = .working("Saving…")
                try await PhotoSaver.saveVideo(at: url)
                if let coverData {
                    try await PhotoSaver.saveImage(coverData)
                    coverPhase = .saved
                }
                phase = .saved
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

private struct MetaRow: View {
    let icon: String
    let label: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}
