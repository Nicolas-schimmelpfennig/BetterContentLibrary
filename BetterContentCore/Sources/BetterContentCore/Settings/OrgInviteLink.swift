//
//  OrgInviteLink.swift
//  BetterContentCore
//
//  The `bettercontent://join?code=XXXXXXXX` invite link: built for Copy Link,
//  parsed by both apps' onOpenURL, and normalized from whatever the user
//  pastes into the join field (a bare code or a whole link).
//

import Foundation

public enum OrgInviteLink {
    public static let scheme = "bettercontent"
    public static let host = "join"

    /// Invite codes are exactly 8 characters from this alphabet (no I/L/O/U/
    /// 0/1), mirroring `internal.generate_invite_code()` in the database.
    public static let codeLength = 8

    public static func url(code: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        return components.url!
    }

    /// Extracts the code from an invite URL; nil when the URL is anything else.
    public static func code(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme,
              url.host()?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let raw = items.first(where: { $0.name == "code" })?.value
        else { return nil }
        return normalizeBareCode(raw)
    }

    /// Accepts whatever landed in the join field — a bare code, with stray
    /// whitespace or lowercase, or a full invite link — and returns the
    /// canonical uppercase code, or nil when it can't be one.
    public static func normalize(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("\(scheme)://"), let url = URL(string: trimmed) {
            return code(from: url)
        }
        return normalizeBareCode(trimmed)
    }

    private static func normalizeBareCode(_ raw: String) -> String? {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upper.count == codeLength,
              upper.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return upper
    }
}
