import Foundation

/// An event emitted as a background upload progresses.
public enum UploadEvent: Sendable {
    case progress(clipId: UUID, fraction: Double)
    case finished(clipId: UUID, key: String)
    case failed(clipId: UUID, message: String)
}

/// Uploads files to R2 on a **background** `URLSession`, so transfers continue
/// even if the app is suspended or quit, and large files never block the app.
///
/// Background sessions must be delegate-driven (the async `URLSession` APIs don't
/// apply), and there must be exactly one session per identifier for the lifetime
/// of the process. Hence the shared singleton: instantiate it early at launch so
/// the delegate is attached before the system replays completion events.
///
/// Two ways to observe results:
/// - `events()` — an `AsyncStream` for live UI (progress bars). Only delivers to
///   current subscribers, so events that fire before anyone subscribes are missed.
/// - `onFinished` / `onFailed` — closures invoked for every terminal event,
///   *including* those replayed after relaunch. Wire these to `ClipsService` so
///   a clip's status is always reconciled regardless of UI state.
public final class BackgroundUploadService: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let shared = BackgroundUploadService()

    /// Called when an upload completes successfully (clip id, R2 key).
    public var onFinished: (@Sendable (UUID, String) -> Void)?
    /// Called when an upload fails (clip id, message).
    public var onFailed: (@Sendable (UUID, String) -> Void)?
    /// iOS only: set from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    public var backgroundCompletionHandler: (@Sendable () -> Void)?

    private let identifier: String
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<UploadEvent>.Continuation] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public init(identifier: String = "com.bettercontentlibrary.upload") {
        self.identifier = identifier
        super.init()
        _ = session // force creation so the delegate is attached immediately
    }

    /// Queues a file for background upload to a presigned R2 URL. The clip id and
    /// key ride along in `taskDescription` so they survive app relaunch.
    public func enqueue(fileURL: URL, to uploadURL: URL, key: String, clipId: UUID, contentType: String) {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = Context(clipId: clipId, key: key).encoded()
        task.resume()
    }

    /// A fresh stream of upload events for the current subscriber.
    public func events() -> AsyncStream<UploadEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    private func emit(_ event: UploadEvent) {
        let continuations = lock.withLock { Array(subscribers.values) }
        for continuation in continuations { continuation.yield(event) }
    }

    // MARK: URLSession delegate

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0, let context = Context(task.taskDescription) else { return }
        emit(.progress(clipId: context.clipId, fraction: Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let context = Context(task.taskDescription) else { return }

        if let error {
            onFailed?(context.clipId, error.localizedDescription)
            emit(.failed(clipId: context.clipId, message: error.localizedDescription))
            return
        }
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = "HTTP \(http.statusCode)"
            onFailed?(context.clipId, message)
            emit(.failed(clipId: context.clipId, message: message))
            return
        }
        onFinished?(context.clipId, context.key)
        emit(.finished(clipId: context.clipId, key: context.key))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        DispatchQueue.main.async { handler?() }
    }

    /// Context carried through a background task via its `taskDescription`.
    private struct Context: Codable {
        let clipId: UUID
        let key: String

        init(clipId: UUID, key: String) {
            self.clipId = clipId
            self.key = key
        }

        init?(_ description: String?) {
            guard let data = description?.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Context.self, from: data) else { return nil }
            self = decoded
        }

        func encoded() -> String {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
}
