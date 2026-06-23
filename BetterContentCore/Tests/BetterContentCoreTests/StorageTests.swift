import Foundation
import Testing
@testable import BetterContentCore

@Test func uploadTicketDecodesFromFunctionResponse() throws {
    let json = """
    {
      "uploadUrl": "https://acct.r2.cloudflarestorage.com/bucket/orgs/abc/clips/def.mp4?X-Amz-Signature=xyz",
      "key": "orgs/abc/clips/def.mp4"
    }
    """.data(using: .utf8)!

    let ticket = try JSONDecoder().decode(UploadTicket.self, from: json)

    #expect(ticket.key == "orgs/abc/clips/def.mp4")
    #expect(ticket.uploadUrl.scheme == "https")
    #expect(ticket.uploadUrl.query?.contains("X-Amz-Signature") == true)
}

@Test func downloadTicketDecodesFromFunctionResponse() throws {
    let json = """
    {
      "downloadUrl": "https://acct.r2.cloudflarestorage.com/bucket/orgs/abc/clips/def.mp4?X-Amz-Signature=xyz",
      "key": "orgs/abc/clips/def.mp4"
    }
    """.data(using: .utf8)!

    let ticket = try JSONDecoder().decode(DownloadTicket.self, from: json)

    #expect(ticket.key == "orgs/abc/clips/def.mp4")
    #expect(ticket.downloadUrl.host == "acct.r2.cloudflarestorage.com")
}
