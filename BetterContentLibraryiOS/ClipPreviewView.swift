//
//  ClipPreviewView.swift
//  BetterContentLibrary (iOS)
//
//  Full-screen video preview backed by a presigned R2 stream URL.
//

import SwiftUI
import AVKit
import BetterContentCore

struct ClipPreviewView: View {
    let clip: Clip
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                } else if failed {
                    Label("Couldn't load video", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.white)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .navigationTitle(clip.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            if let url = await model.streamURL(for: clip) {
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            } else {
                failed = true
            }
        }
        .onDisappear { player?.pause() }
    }
}
