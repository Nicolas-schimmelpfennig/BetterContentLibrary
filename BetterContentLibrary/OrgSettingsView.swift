//
//  OrgSettingsView.swift
//  BetterContentLibrary
//
//  Settings → Org: share your organization (standing invite code / link),
//  see and manage members, join another org, or leave. Admin-only controls
//  are hidden for members and enforced server-side regardless.
//

import SwiftUI
import BetterContentCore

struct OrgSettingsView: View {
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
        .formStyle(.grouped)
        .task {
            await model.load()
            orgName = model.organization?.name ?? ""
        }
        .sheet(isPresented: $showJoinSheet) {
            JoinOrgSheet(profile: profile)
        }
        .sheet(isPresented: $showConvertSheet, onDismiss: { Task { await model.load() } }) {
            MigrationSheet(target: .r2)
        }
        .confirmationDialog(
            "Regenerate the invite code?",
            isPresented: $showRegenerateConfirm
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
            isPresented: $showLeaveConfirm
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
            } else {
                LabeledContent("Name", value: model.organization?.name ?? "—")
            }
            LabeledContent("Your role", value: model.currentRole.displayLabel)
        } header: {
            Text("Organization")
        } footer: {
            if model.isAdmin {
                Text("Press Return to save the name. Everyone in the organization sees it.")
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
                HStack {
                    Button("Copy Code") { copy(org.inviteCode) }
                    Button("Copy Link") { copy(OrgInviteLink.url(code: org.inviteCode).absoluteString) }
                    if model.isAdmin {
                        Spacer()
                        Button("Regenerate…") { showRegenerateConfirm = true }
                    }
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
                        .menuStyle(.borderlessButton)
                        .fixedSize()
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

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private static func displayName(_ member: Profile) -> String {
        member.displayName?.isEmpty == false ? member.displayName! : "Member"
    }
}
