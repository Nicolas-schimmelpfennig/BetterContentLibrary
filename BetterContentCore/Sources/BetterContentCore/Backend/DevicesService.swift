import Foundation
import Supabase

/// Registers a device's APNs token so the backend can push "time to post"
/// notifications to it. One row per app install (migration 0017): a rotated
/// token replaces its install's row instead of piling up beside it.
public final class DevicesService: Sendable {
    private let client: SupabaseClient

    public init(client: SupabaseClient = Backend.client) {
        self.client = client
    }

    /// Records this install's current push token for the signed-in user.
    /// `installId` is a stable per-install id; `environment` is the APNs
    /// gateway the token belongs to ("sandbox" or "production"). Server-side,
    /// this also drops any other row holding the token and the caller's
    /// pre-install-id rows (the stale tokens that made failed pushes look
    /// delivered).
    public func register(installId: String, token: String, environment: String) async throws {
        try await client
            .rpc("register_device", params: RegisterParams(
                p_install_id: installId, p_token: token, p_environment: environment
            ))
            .execute()
    }

    /// Removes this install's row for the signed-in user — call before signing
    /// out, so the phone stops receiving that account's post reminders.
    public func unregister(installId: String) async throws {
        try await client
            .rpc("unregister_device", params: UnregisterParams(p_install_id: installId))
            .execute()
    }

    /// Asks the backend to push a test notification to every device registered
    /// for the signed-in user, and returns what APNs said for each — the
    /// end-to-end check behind Settings → Send Test Notification.
    public func sendTestPush() async throws -> [DevicePushCheck] {
        let response: TestResponse = try await client.functions.invoke(
            "send-due-notifications",
            options: FunctionInvokeOptions(body: ["action": "test"])
        )
        return response.devices
    }

    private struct TestResponse: Decodable, Sendable {
        let devices: [DevicePushCheck]
    }

    private struct RegisterParams: Encodable, Sendable {
        let p_install_id: String
        let p_token: String
        let p_environment: String
    }

    private struct UnregisterParams: Encodable, Sendable {
        let p_install_id: String
    }
}

/// One registered device's answer to a test push.
public struct DevicePushCheck: Decodable, Sendable, Identifiable {
    public let installId: String?
    public let tokenPrefix: String
    /// When the install last registered, as Postgres wrote it (the function
    /// client's default decoder has no date strategy, so it's parsed lazily).
    private let registeredAtRaw: String?
    /// APNs accepted the push (it will be delivered when the device is reachable).
    public let ok: Bool
    /// "sandbox" or "production" — whichever gateway gave the final answer.
    public let gateway: String
    public let status: Int
    /// APNs's reason on failure (e.g. "BadDeviceToken", "Unregistered").
    public let reason: String?
    /// The row was deleted because both gateways disowned the token.
    public let removed: Bool

    public var id: String { installId ?? tokenPrefix }

    public var registeredAt: Date? {
        guard let raw = registeredAtRaw else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    enum CodingKeys: String, CodingKey {
        case installId = "install_id"
        case tokenPrefix = "token_prefix"
        case registeredAtRaw = "registered_at"
        case ok, gateway, status, reason, removed
    }
}
