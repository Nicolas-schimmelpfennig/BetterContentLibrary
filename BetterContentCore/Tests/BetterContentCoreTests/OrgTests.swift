import Foundation
import Testing
@testable import BetterContentCore

// MARK: - Invite links

@Test func inviteLinkRoundTrips() {
    let url = OrgInviteLink.url(code: "N3KSW8JD")
    #expect(url.absoluteString == "bettercontent://join?code=N3KSW8JD")
    #expect(OrgInviteLink.code(from: url) == "N3KSW8JD")
}

@Test func inviteLinkRejectsForeignURLs() {
    #expect(OrgInviteLink.code(from: URL(string: "https://example.com/join?code=N3KSW8JD")!) == nil)
    #expect(OrgInviteLink.code(from: URL(string: "bettercontent://other?code=N3KSW8JD")!) == nil)
    #expect(OrgInviteLink.code(from: URL(string: "bettercontent://join?other=N3KSW8JD")!) == nil)
}

@Test func normalizeAcceptsBareCodesAndLinks() {
    #expect(OrgInviteLink.normalize("  n3ksw8jd\n") == "N3KSW8JD")
    #expect(OrgInviteLink.normalize("N3KSW8JD") == "N3KSW8JD")
    #expect(OrgInviteLink.normalize("bettercontent://join?code=n3ksw8jd") == "N3KSW8JD")
}

@Test func normalizeRejectsNonCodes() {
    #expect(OrgInviteLink.normalize("") == nil)
    #expect(OrgInviteLink.normalize("SHORT") == nil)
    #expect(OrgInviteLink.normalize("WAYTOOLONGCODE") == nil)
    #expect(OrgInviteLink.normalize("N3KS-8JD") == nil)
    #expect(OrgInviteLink.normalize("https://example.com") == nil)
}

// MARK: - Roles

@Test func roleLabelsMatchProductNames() {
    #expect(UserRole.owner.displayLabel == "Admin")
    #expect(UserRole.editor.displayLabel == "Member")
    #expect(UserRole.owner.isAdmin)
    #expect(!UserRole.editor.isAdmin)
    #expect(!UserRole.viewer.isAdmin)
}

// MARK: - Organization decoding

@Test func organizationDecodesPost0014Columns() throws {
    let json = """
    {
      "id": "533a1246-5153-4736-bc3e-7623c94617b3",
      "name": "Extase+me",
      "invite_code": "N3KSW8JD",
      "storage_limit_gb": 25,
      "eviction_order": "posted",
      "created_at": "2026-06-23T10:00:00Z"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let org = try decoder.decode(Organization.self, from: json)
    #expect(org.inviteCode == "N3KSW8JD")
    #expect(org.storageLimitGB == 25)
    #expect(org.evictionOrder == [.posted])
    #expect(org.storageLimitBytes == 25_000_000_000)
}

@Test func organizationToleratesPre0014Rows() throws {
    let json = """
    {
      "id": "533a1246-5153-4736-bc3e-7623c94617b3",
      "name": "Old Org",
      "created_at": "2026-06-23T10:00:00Z"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let org = try decoder.decode(Organization.self, from: json)
    #expect(org.inviteCode == "")
    #expect(org.storageLimitGB == 5)
    #expect(org.evictionOrder == EvictionCategory.defaultOrder)
}

@Test func emptyEvictionOrderMeansDisabled() throws {
    let json = """
    {
      "id": "533a1246-5153-4736-bc3e-7623c94617b3",
      "name": "No Eviction",
      "invite_code": "N3KSW8JD",
      "storage_limit_gb": 5,
      "eviction_order": "",
      "created_at": "2026-06-23T10:00:00Z"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let org = try decoder.decode(Organization.self, from: json)
    #expect(org.evictionOrder.isEmpty)
}
