import Foundation
import Testing
@testable import BetterContentCore

@Test func platformRawValuesMatchPostgresEnum() {
    #expect(Platform.youtubeShorts.rawValue == "youtube_shorts")
    #expect(Platform.instagram.rawValue == "instagram")
}

@Test func clipDecodesFromSnakeCaseJSON() throws {
    let json = """
    {
      "id": "1d9f7d3a-0c2e-4b1b-9c2a-2b3c4d5e6f70",
      "org_id": "2d9f7d3a-0c2e-4b1b-9c2a-2b3c4d5e6f70",
      "uploaded_by": null,
      "title": "Test clip",
      "r2_key": null,
      "file_size": 1024,
      "duration_s": 12.5,
      "width": 1080,
      "height": 1920,
      "orientation": "vertical",
      "content_hash": null,
      "status": "ready",
      "created_at": "2026-06-23T10:00:00Z",
      "updated_at": "2026-06-23T10:00:00Z"
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let clip = try decoder.decode(Clip.self, from: json)

    #expect(clip.title == "Test clip")
    #expect(clip.orientation == .vertical)
    #expect(clip.status == .ready)
    #expect(clip.height == 1920)
}
