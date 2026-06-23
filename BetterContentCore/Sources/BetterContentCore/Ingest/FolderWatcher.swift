#if os(macOS)
import CoreServices
import Foundation

/// Watches a folder for finished video files using FSEvents.
///
/// FSEvents fires while a file is still being written, so each observed path is
/// debounced: the watcher waits until the file's size has stopped changing for a
/// quiet interval before reporting it as ready. Each path is reported once.
public final class FolderWatcher: @unchecked Sendable {
    /// Called on a background queue with the URL of a file that has finished writing.
    public typealias Handler = @Sendable (URL) -> Void

    private let folder: URL
    private let handler: Handler
    private let videoExtensions: Set<String>
    private let quietInterval: TimeInterval

    private let queue = DispatchQueue(label: "com.bettercontentlibrary.folderwatcher")
    private var stream: FSEventStreamRef?

    // Guarded by `queue`.
    private var pending: [String: DispatchWorkItem] = [:]
    private var lastSize: [String: Int64] = [:]
    private var reported: Set<String> = []

    public init(
        folder: URL,
        videoExtensions: Set<String> = ["mp4", "mov", "m4v"],
        quietInterval: TimeInterval = 2.0,
        handler: @escaping Handler
    ) {
        self.folder = folder
        self.handler = handler
        self.videoExtensions = videoExtensions
        self.quietInterval = quietInterval
    }

    public func start() {
        queue.async { [weak self] in self?.startStream() }
    }

    public func stop() {
        queue.async { [weak self] in self?.stopStream() }
    }

    deinit { stopStream() }

    // MARK: FSEvents (all on `queue`)

    private func startStream() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
    }

    // Called from the C callback, already on `queue`.
    fileprivate func handlePaths(_ paths: [String]) {
        for path in paths {
            let ext = (path as NSString).pathExtension.lowercased()
            guard videoExtensions.contains(ext), !reported.contains(path) else { continue }
            scheduleStabilityCheck(path)
        }
    }

    private func scheduleStabilityCheck(_ path: String) {
        pending[path]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkStability(path) }
        pending[path] = work
        queue.asyncAfter(deadline: .now() + quietInterval, execute: work)
    }

    private func checkStability(_ path: String) {
        pending[path] = nil
        guard !reported.contains(path) else { return }

        guard let size = fileSize(path) else {
            lastSize[path] = nil
            return // file vanished (e.g. moved during write) — wait for a new event
        }

        if lastSize[path] == size {
            // Size held steady across the quiet interval: treat as finished.
            reported.insert(path)
            lastSize[path] = nil
            handler(URL(fileURLWithPath: path))
        } else {
            lastSize[path] = size
            scheduleStabilityCheck(path) // still growing — check again
        }
    }

    private func fileSize(_ path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }
}

// Top-level C callback: recover the watcher from the context and forward paths.
private func fsEventsCallback(
    stream: ConstFSEventStreamRef,
    info: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    watcher.handlePaths(paths)
}
#endif
