import Foundation
import Testing
@testable import BetterContentCore

private func makeTempStore() throws -> (PendingUploadStore, URL) {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pending-store-tests-\(UUID().uuidString)", isDirectory: true)
    return (PendingUploadStore(directory: dir), dir)
}

@Test func stageCopiesFileIntoStore() throws {
    let (store, dir) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let source = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("source-\(UUID().uuidString).mp4")
    try Data("video".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: source) }

    let staged = try store.stage(source)
    #expect(FileManager.default.fileExists(atPath: staged.path))
    #expect(staged.lastPathComponent.hasSuffix(source.lastPathComponent))
    #expect(staged.deletingLastPathComponent() == store.directory)
}

@Test func trackedUploadsSurviveReload() throws {
    let (store, dir) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let clipId = UUID()
    let staged = store.directory.appendingPathComponent("abc-clip.mp4")
    try Data("video".utf8).write(to: staged)
    store.track(clipId: clipId, fileURL: staged)

    // A second store over the same directory simulates an app relaunch.
    let reloaded = PendingUploadStore(directory: dir)
    #expect(reloaded.trackedClipIds == [clipId])

    reloaded.finish(clipId: clipId)
    #expect(reloaded.trackedClipIds.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: staged.path))
}

@Test func sweepRemovesOnlyUntrackedFiles() throws {
    let (store, dir) = try makeTempStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    let tracked = store.directory.appendingPathComponent("tracked.mp4")
    let orphan = store.directory.appendingPathComponent("orphan.mp4")
    try Data("a".utf8).write(to: tracked)
    try Data("b".utf8).write(to: orphan)
    store.track(clipId: UUID(), fileURL: tracked)

    store.sweepUntrackedFiles()

    #expect(FileManager.default.fileExists(atPath: tracked.path))
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    // The registry sidecar must survive its own sweep.
    #expect(store.trackedClipIds.count == 1)
}
