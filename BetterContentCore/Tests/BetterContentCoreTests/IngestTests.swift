import Foundation
import Testing
@testable import BetterContentCore

@Test func contentHasherMatchesKnownSHA256() throws {
    // SHA-256("abc") is a well-known vector.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hashtest-\(UUID().uuidString)")
    try "abc".data(using: .utf8)!.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let hash = try ContentHasher.sha256(of: tmp)
    #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func contentHasherHandlesEmptyFile() throws {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hashtest-empty-\(UUID().uuidString)")
    try Data().write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // SHA-256 of zero bytes.
    let hash = try ContentHasher.sha256(of: tmp)
    #expect(hash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}
