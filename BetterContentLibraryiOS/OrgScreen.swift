//
//  OrgScreen.swift
//  BetterContentLibrary (iOS)
//
//  Settings → Organization: share the org (standing invite code / link), see
//  and manage members, join another org, or leave. Admin-only controls are
//  hidden for members and enforced server-side regardless. Also home to the
//  iOS join flow (JoinOrgScreen) and migration progress (MigrationScreen).
//

import SwiftUI
import BetterContentCore

struct OrgScreen: View {
    @Environment(AuthService.self) private var auth

    let profile: Profile
    @State private var model: OrgModel

    @State private var orgName = ""
    @State private var showJoinSheet = false
    @State private var showRegenerateConfirm = false
    @State private var showLeaveConfirm = false
    @State private var removalCandidate: Profile?
    @State private var showConvertSheet = false

    init(profile: Profile) {
        self.profile = profile
        _model = State(initialValue: OrgModel(profile: profile))
    }

    var body: some View {
        Form {
            organizationSection
            inviteSection
            membersSection
            joinSection
            leaveSection
        }
        .navigationTitle("Organization")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load()
            orgName = model.organization?.name ?? ""
        }
        .sheet(isPresented: $showJoinSheet) {
            JoinOrgScreen(profile: profile)
        }
        .sheet(isPresented: $showConvertSheet, onDismiss: { Task { await model.load() } }) {
            MigrationScreen(target: .r2)
        }
        .confirmationDialog(
            "Regenerate the invite code?",
            isPresented: $showRegenerateConfirm,
            titleVisibility: .visible
        ) {
            Button("Regenerate", role: .destructive) {
                Task { await model.regenerateInvite() }
            }
        } message: {
            Text("The current code stops working immediately. Anyone you already invited keeps their membership.")
        }
        .confirmationDialog(
            "Remove \(removalCandidate.map(Self.displayName) ?? "this member")?",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: removalCandidate
        ) { member in
            Button("Remove from Organization", role: .destructive) {
                Task { await model.removeMember(member.id) }
            }
        } message: { member in
            Text("\(Self.displayName(member)) gets a fresh personal library. Clips they uploaded stay with the organization.")
        }
        .confirmationDialog(
            "Leave this organization?",
            isPresented: $showLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave Organization", role: .destructive) {
                Task {
                    do {
                        try await model.leave()
                        await auth.refreshProfile()
                    } catch {
                        model.errorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("You'll get a fresh personal library. Clips you uploaded stay with the organization.")
        }
        .alert("Organization", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: Sections

    private var organizationSection: some View {
        Section {
            if model.isAdmin {
                TextField("Name", text: $orgName)
                    .onSubmit { Task { await model.rename(orgName) } }
                    .submitLabel(.done)
            } else {
                LabeledContent("Name", value: model.organization?.name ?? "—")
            }
            LabeledContent("Your role", value: model.currentRole.displayLabel)
        } footer: {
            if model.isAdmin {
                Text("Tap Done to save the name. Everyone in the organization sees it.")
            }
        }
    }

    @ViewBuilder
    private var inviteSection: some View {
        Section {
            if model.nonR2Count > 0 {
                Label(
                    "\(model.nonR2Count) of your clips are in iCloud Drive — teammates wouldn't be able to play them. Move everything to BetterContent Cloud to start inviting.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                Button("Move \(model.nonR2Count) Clip\(model.nonR2Count == 1 ? "" : "s") to BetterContent Cloud…") {
                    showConvertSheet = true
                }
            } else if let org = model.organization {
                LabeledContent("Invite code") {
                    Text(org.inviteCode)
                        .monospaced()
                        .textSelection(.enabled)
                }
                Button("Copy Code") { UIPasteboard.general.string = org.inviteCode }
                ShareLink(item: OrgInviteLink.url(code: org.inviteCode)) {
                    Text("Share Invite Link")
                }
                if model.isAdmin {
                    Button("Regenerate Code…", role: .destructive) { showRegenerateConfirm = true }
                }
            }
        } header: {
            Text("Invite Teammates")
        } footer: {
            Text("Anyone signed into the app can join with this code, so share it like a Wi-Fi password. Teams store clips in BetterContent Cloud — iCloud Drive is for single-user libraries.")
        }
    }

    private var membersSection: some View {
        Section("Members (\(model.members.count))") {
            ForEach(model.members) { member in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.displayName(member) + (member.id == profile.id ? " (you)" : ""))
                        Text(member.role.displayLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isAdmin && member.id != profile.id {
                        Menu {
                            if member.role.isAdmin {
                                Button("Make Member") {
                                    Task { await model.setRole(member.id, admin: false) }
                                }
                            } else {
                                Button("Make Admin") {
                                    Task { await model.setRole(member.id, admin: true) }
                                }
                            }
                            Divider()
                            Button("Remove from Organization…", role: .destructive) {
                                removalCandidate = member
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
    }

    private var joinSection: some View {
        Section {
            Button("Join Another Organization…") { showJoinSheet = true }
        } footer: {
            Text("Paste a code or link from a teammate. You'll choose whether to bring your clips or start fresh before anything happens.")
        }
    }

    @ViewBuilder
    private var leaveSection: some View {
        if model.isMultiUser {
            Section {
                Button("Leave Organization…", role: .destructive) { showLeaveConfirm = true }
                    .disabled(model.isLastAdmin)
            } footer: {
                if model.isLastAdmin {
                    Text("You're the only admin — make someone else an admin first.")
                } else {
                    Text("Clips you uploaded stay with the organization; you'll get a fresh personal library.")
                }
            }
        }
    }

    // MARK: Helpers

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private static func displayName(_ member: Profile) -> String {
        member.displayName?.isEmpty == false ? member.displayName! : "Member"
    }
}

// MARK: - Join flow

/// Code → preview → "bring my clips" or "start fresh" → (blocking iCloud→R2
/// conversion when needed) → join → summary. On success the profile refreshes
/// and RootView rebuilds the session for the new org.
struct JoinOrgScreen: View {
    @Environment(AuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var model: OrgModel
    @State private var migration = MigrationModel()

    @State private var codeText: String
    @State private var preview: OrgPreview?
    @State private var isConverting = false
    @State private var joinResult: JoinResult?
    @State private var bringLibrary = true
    @State private var errorText: String?
    @State private var isBusy = false

    init(profile: Profile, initialCode: String = "") {
        _model = State(initialValue: OrgModel(profile: profile))
        _codeText = State(initialValue: initialCode)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let result = joinResult {
                    doneSection(result)
                } else if isConverting {
                    convertingSection
                } else if let preview {
                    confirmSections(preview)
                } else {
                    codeSection
                }
            }
            .navigationTitle("Join Organization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(joinResult == nil ? "Cancel" : "Done") {
                        if isConverting { migration.cancel() }
                        dismiss()
                    }
                }
            }
            .task { await model.load() }
        }
        .interactiveDismissDisabled(isConverting)
    }

    // MARK: Steps

    private var codeSection: some View {
        Section {
            TextField("Code or link", text: $codeText)
                .monospaced()
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .onSubmit { Task { await lookUp() } }
            Button("Continue") { Task { await lookUp() } }
                .disabled(OrgInviteLink.normalize(codeText) == nil || isBusy)
        } header: {
            Text("Invite Code")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Paste the invite code or link a teammate shared with you.")
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func confirmSections(_ preview: OrgPreview) -> some View {
        Section {
            LabeledContent("Organization", value: preview.orgName)
            LabeledContent("Members", value: "\(preview.memberCount)")
            LabeledContent("You join as", value: "Member")
        }

        Section {
            Picker("Your current library", selection: $bringLibrary) {
                Text("Bring my clips").tag(true)
                Text("Start fresh").tag(false)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } footer: {
            if bringLibrary {
                if model.nonR2Count > 0 {
                    Text("\(model.nonR2Count) of your clips are in iCloud Drive. They'll be converted to BetterContent Cloud first so your new teammates can play them.")
                } else {
                    Text("Your clips, folders, and schedule move with you. Clips the organization already has are left behind instead of duplicated.")
                }
            } else {
                Text("Your current library stays in your old organization. You won't see it after joining.")
            }
        }

        Section {
            Button("Join “\(preview.orgName)”") { Task { await startJoin(preview) } }
                .disabled(isBusy)
            Button("Back") {
                errorText = nil
                self.preview = nil
            }
        } footer: {
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
        }
    }

    private var convertingSection: some View {
        Section {
            ProgressView(value: migration.progress)
            Text(migration.currentTitle.map { "Moving “\($0)”…" }
                 ?? "\(migration.completed) of \(migration.total)")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Moving Clips to BetterContent Cloud")
        } footer: {
            Text("Teammates can't reach clips in your iCloud Drive, so they're converted before joining.")
        }
    }

    private func doneSection(_ result: JoinResult) -> some View {
        Section {
            Label("Welcome to “\(preview?.orgName ?? "your new organization")”", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } footer: {
            if bringLibrary {
                Text(summaryText(result))
            } else {
                Text("You joined with a fresh library. Your old clips stay in your previous organization.")
            }
        }
    }

    // MARK: Actions

    private func lookUp() async {
        guard let code = OrgInviteLink.normalize(codeText) else { return }
        errorText = nil
        isBusy = true
        defer { isBusy = false }
        do {
            if let found = try await model.preview(code: code) {
                preview = found
            } else {
                errorText = OrgError.invalidCode.localizedDescription
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func startJoin(_ preview: OrgPreview) async {
        errorText = nil
        if bringLibrary && model.nonR2Count > 0 {
            isConverting = true
            migration.onFinished = {
                Task { await finishConversion(preview) }
            }
            migration.start(to: .r2)
        } else {
            await join(preview)
        }
    }

    private func finishConversion(_ preview: OrgPreview) async {
        isConverting = false
        if migration.failures.isEmpty && migration.total == migration.completed {
            await join(preview)
        } else {
            errorText = migration.failures.first.map {
                "Couldn't move “\($0.clipTitle)”: \($0.message)"
            } ?? "The conversion didn't finish. Try again."
            migration.reset()
            await model.load()
        }
    }

    private func join(_ preview: OrgPreview) async {
        guard let code = OrgInviteLink.normalize(codeText) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await model.join(code: code, bringLibrary: bringLibrary)
            await auth.refreshProfile()
            joinResult = result
        } catch {
            errorText = error.localizedDescription
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

// MARK: - Migration progress

/// Bulk storage conversion with visible progress. Cancelling stops between
/// clips — everything already moved stays moved; re-opening resumes the rest.
struct MigrationScreen: View {
    @Environment(\.dismiss) private var dismiss

    let target: StorageProvider

    @State private var migration = MigrationModel()
    @State private var pendingCount: Int?
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Form {
                switch migration.state {
                case .idle:
                    idleSection
                case .running:
                    runningSection
                case .finished:
                    finishedSection
                }
            }
            .navigationTitle("Move to \(target.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(migration.state == .running ? "Cancel" : "Done") {
                        if migration.state == .running {
                            migration.cancel()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .task { await countPending() }
        }
        .interactiveDismissDisabled(migration.state == .running)
    }

    @ViewBuilder
    private var idleSection: some View {
        if let error = loadError {
            Section { Text(error).foregroundStyle(.red) }
        } else if let count = pendingCount {
            if count == 0 {
                Section {
                    Text("Everything is already stored in \(target.displayName).")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button("Move \(count) Clip\(count == 1 ? "" : "s")") {
                        migration.start(to: target)
                    }
                } footer: {
                    Text(explainer(count: count))
                }
            }
        } else {
            Section { ProgressView("Checking your library…") }
        }
    }

    private var runningSection: some View {
        Section {
            ProgressView(value: migration.progress)
            Text(migration.currentTitle.map { "Moving “\($0)”…" }
                 ?? "\(migration.completed) of \(migration.total)")
                .font(.callout)
                .foregroundStyle(.secondary)
        } footer: {
            Text("Clips stay playable while they move. You can cancel and resume any time.")
        }
    }

    @ViewBuilder
    private var finishedSection: some View {
        let moved = migration.completed - migration.failures.count
        Section {
            Label(
                "\(moved) clip\(moved == 1 ? "" : "s") moved to \(target.displayName).",
                systemImage: migration.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(migration.failures.isEmpty ? .green : .orange)
            ForEach(migration.failures) { failure in
                Text("“\(failure.clipTitle)”: \(failure.message)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if !migration.failures.isEmpty {
                Text("Run the migration again to retry — finished clips are skipped.")
            }
        }
    }

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
