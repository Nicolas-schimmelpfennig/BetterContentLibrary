//
//  MigrationSheet.swift
//  BetterContentLibrary
//
//  Bulk storage conversion with visible progress: counts what's pending,
//  asks once, then moves clip by clip. Cancelling stops between clips —
//  everything already moved stays moved; re-opening resumes the rest.
//

import SwiftUI
import BetterContentCore

struct MigrationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let target: StorageProvider

    @State private var migration = MigrationModel()
    @State private var pendingCount: Int?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move clips to \(target.displayName)")
                .font(.title3.weight(.semibold))

            switch migration.state {
            case .idle:
                idleContent
            case .running:
                runningContent
            case .finished:
                finishedContent
            }
        }
        .padding(24)
        .frame(width: 440)
        .task { await countPending() }
        .interactiveDismissDisabled(migration.state == .running)
    }

    // MARK: States

    @ViewBuilder
    private var idleContent: some View {
        if let error = loadError {
            Text(error).foregroundStyle(.red)
            doneRow
        } else if let count = pendingCount {
            if count == 0 {
                Text("Everything is already stored in \(target.displayName).")
                    .foregroundStyle(.secondary)
                doneRow
            } else {
                Text(explainer(count: count))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Move \(count) Clip\(count == 1 ? "" : "s")") {
                        migration.start(to: target)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            ProgressView("Checking your library…")
        }
    }

    @ViewBuilder
    private var runningContent: some View {
        ProgressView(value: migration.progress)
        Text(migration.currentTitle.map { "Moving “\($0)”…" }
             ?? "\(migration.completed) of \(migration.total)")
            .font(.callout)
            .foregroundStyle(.secondary)
        Text("Clips stay playable while they move. You can cancel and resume any time.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        HStack {
            Spacer()
            Button("Cancel") { migration.cancel() }
        }
    }

    @ViewBuilder
    private var finishedContent: some View {
        let moved = migration.completed - migration.failures.count
        Label(
            "\(moved) clip\(moved == 1 ? "" : "s") moved to \(target.displayName).",
            systemImage: migration.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(migration.failures.isEmpty ? .green : .orange)

        if !migration.failures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(migration.failures) { failure in
                    Text("“\(failure.clipTitle)”: \(failure.message)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Run the migration again to retry — finished clips are skipped.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        doneRow
    }

    private var doneRow: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Helpers

    private func explainer(count: Int) -> String {
        switch target {
        case .r2:
            return "\(count) clip\(count == 1 ? " is" : "s are") stored in iCloud Drive. Moving them to BetterContent Cloud makes them playable for everyone in your organization."
        case .iCloudDrive:
            return "\(count) clip\(count == 1 ? " is" : "s are") in BetterContent Cloud. Moving them to iCloud Drive stores them under your own Apple ID — only your devices will be able to play them."
        case .googleDrive:
            return "Google Drive isn't available yet."
        }
    }

    private func countPending() async {
        do {
            pendingCount = try await StorageMigrationService().pendingClips(to: target).count
        } catch {
            loadError = error.localizedDescription
        }
    }
}
