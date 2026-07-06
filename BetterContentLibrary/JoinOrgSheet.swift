//
//  JoinOrgSheet.swift
//  BetterContentLibrary
//
//  The full join flow: code → preview of the org behind it → "bring my clips"
//  or "start fresh" → (if bringing and some clips are in iCloud) a blocking
//  conversion step → join → summary. On success the profile is refreshed and
//  the whole session tree rebuilds for the new org (ContentView keys on it).
//

import SwiftUI
import BetterContentCore

struct JoinOrgSheet: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var model: OrgModel
    @State private var migration = MigrationModel()

    @State private var codeText: String
    @State private var phase: Phase = .code
    @State private var bringLibrary = true
    @State private var errorText: String?
    @State private var isBusy = false

    private enum Phase: Equatable {
        case code
        case confirm(OrgPreview)
        case converting(OrgPreview)
        case done(JoinResult, orgName: String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.code, .code): return true
            case let (.confirm(a), .confirm(b)): return a.orgId == b.orgId
            case let (.converting(a), .converting(b)): return a.orgId == b.orgId
            case let (.done(a, _), .done(b, _)): return a.orgId == b.orgId
            default: return false
            }
        }
    }

    init(profile: Profile, initialCode: String = "") {
        _model = State(initialValue: OrgModel(profile: profile))
        _codeText = State(initialValue: initialCode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch phase {
            case .code:
                codeStep
            case let .confirm(preview):
                confirmStep(preview)
            case let .converting(preview):
                convertingStep(preview)
            case let .done(result, orgName):
                doneStep(result, orgName: orgName)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task { await model.load() }
    }

    // MARK: Step 1 — enter the code

    @ViewBuilder
    private var codeStep: some View {
        Text("Join an Organization")
            .font(.title3.weight(.semibold))
        Text("Paste the invite code or link a teammate shared with you.")
            .foregroundStyle(.secondary)

        TextField("Code or link", text: $codeText)
            .textFieldStyle(.roundedBorder)
            .monospaced()
            .onSubmit { Task { await lookUp() } }

        if let errorText {
            Text(errorText).font(.callout).foregroundStyle(.red)
        }

        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Continue") { Task { await lookUp() } }
                .keyboardShortcut(.defaultAction)
                .disabled(OrgInviteLink.normalize(codeText) == nil || isBusy)
        }
    }

    private func lookUp() async {
        guard let code = OrgInviteLink.normalize(codeText) else { return }
        errorText = nil
        isBusy = true
        defer { isBusy = false }
        do {
            if let preview = try await model.preview(code: code) {
                errorText = nil
                phase = .confirm(preview)
            } else {
                errorText = OrgError.invalidCode.localizedDescription
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: Step 2 — confirm + library choice

    @ViewBuilder
    private func confirmStep(_ preview: OrgPreview) -> some View {
        Text("Join “\(preview.orgName)”?")
            .font(.title3.weight(.semibold))
        Text("\(preview.memberCount) member\(preview.memberCount == 1 ? "" : "s") · You'll join as a Member.")
            .foregroundStyle(.secondary)

        Picker("Your current library", selection: $bringLibrary) {
            Text("Bring my clips into “\(preview.orgName)”").tag(true)
            Text("Start fresh (leave my clips behind)").tag(false)
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()

        Group {
            if bringLibrary {
                if model.nonR2Count > 0 {
                    Label(
                        "\(model.nonR2Count) of your clips are in iCloud Drive. They'll be converted to BetterContent Cloud first so your new teammates can play them.",
                        systemImage: "arrow.triangle.2.circlepath.icloud"
                    )
                } else {
                    Text("Your clips, folders, and schedule move with you. Clips the organization already has are left behind instead of duplicated.")
                }
            } else {
                Text("Your current library stays in your old organization. You won't see it after joining.")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)

        if let errorText {
            Text(errorText).font(.callout).foregroundStyle(.red)
        }

        HStack {
            Button("Back") {
                errorText = nil
                phase = .code
            }
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Join") { Task { await startJoin(preview) } }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy)
        }
    }

    private func startJoin(_ preview: OrgPreview) async {
        errorText = nil
        if bringLibrary && model.nonR2Count > 0 {
            phase = .converting(preview)
            migration.onFinished = {
                Task { await finishConversion(preview) }
            }
            migration.start(to: .r2)
        } else {
            await join(preview)
        }
    }

    // MARK: Step 2½ — iCloud → R2 conversion (only when bringing a mixed library)

    @ViewBuilder
    private func convertingStep(_ preview: OrgPreview) -> some View {
        Text("Moving clips to BetterContent Cloud")
            .font(.title3.weight(.semibold))
        Text("Teammates can't reach clips in your iCloud Drive, so they're converted before joining.")
            .foregroundStyle(.secondary)

        ProgressView(value: migration.progress)
        Text(migration.currentTitle.map { "Moving “\($0)”…" }
             ?? "\(migration.completed) of \(migration.total)")
            .font(.callout)
            .foregroundStyle(.secondary)

        HStack {
            Spacer()
            Button("Cancel") {
                migration.cancel()
                dismiss()
            }
        }
    }

    private func finishConversion(_ preview: OrgPreview) async {
        if migration.failures.isEmpty && migration.total == migration.completed {
            await join(preview)
        } else {
            errorText = migration.failures.first.map {
                "Couldn't move “\($0.clipTitle)”: \($0.message)"
            } ?? "The conversion didn't finish. Try again."
            migration.reset()
            await model.load()
            phase = .confirm(preview)
        }
    }

    // MARK: Step 3 — join + summary

    private func join(_ preview: OrgPreview) async {
        guard let code = OrgInviteLink.normalize(codeText) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await model.join(code: code, bringLibrary: bringLibrary)
            await auth.refreshProfile()
            phase = .done(result, orgName: preview.orgName)
        } catch {
            errorText = error.localizedDescription
            phase = .confirm(preview)
        }
    }

    @ViewBuilder
    private func doneStep(_ result: JoinResult, orgName: String) -> some View {
        Label("Welcome to “\(orgName)”", systemImage: "checkmark.circle.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.green)

        if bringLibrary {
            Text(summaryText(result))
                .foregroundStyle(.secondary)
        } else {
            Text("You joined with a fresh library. Your old clips stay in your previous organization.")
                .foregroundStyle(.secondary)
        }

        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func summaryText(_ result: JoinResult) -> String {
        var parts = ["\(result.movedClips) clip\(result.movedClips == 1 ? "" : "s") moved over."]
        if result.skippedDuplicates > 0 {
            parts.append("\(result.skippedDuplicates) duplicate\(result.skippedDuplicates == 1 ? " was" : "s were") already in the organization and stayed in your old library — nothing was deleted.")
        }
        return parts.joined(separator: " ")
    }
}
