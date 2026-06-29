//
//  LibraryItem.swift
//  BetterContentCore
//
//  The unified library row model (folder | clip) plus sort keys and clip display
//  helpers, shared by the macOS and iOS browsers.
//

import Foundation

/// A row in the library: a subfolder or a clip. Gives both views one
/// selection/sort model. `id` is a stable string so it works as a SwiftUI
/// selection value and an NSTableView row token.
public enum LibraryEntry: Identifiable, Hashable {
    case folder(Folder)
    case clip(Clip)

    public var id: String {
        switch self {
        case .folder(let f): return "folder-\(f.id.uuidString)"
        case .clip(let c): return "clip-\(c.id.uuidString)"
        }
    }

    public var isFolder: Bool { if case .folder = self { return true } else { return false } }
    public var folder: Folder? { if case .folder(let f) = self { return f } else { return nil } }
    public var clip: Clip? { if case .clip(let c) = self { return c } else { return nil } }

    public var name: String {
        switch self {
        case .folder(let f): return f.name
        case .clip(let c): return c.title
        }
    }

    public var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .clip(let c):
            switch c.orientation {
            case .vertical: return "rectangle.portrait"
            case .horizontal: return "rectangle"
            case .square: return "square"
            case nil: return "film"
            }
        }
    }

    public var kindLabel: String { isFolder ? "Folder" : "Video" }

    public var dateAdded: Date {
        switch self {
        case .folder(let f): return f.createdAt
        case .clip(let c): return c.createdAt
        }
    }

    // Sort keys (non-optional so `KeyPathComparator` stays stable).
    public var sortName: String { name.localizedLowercase }
    public var sortDate: Date { dateAdded }
    public var sortKind: String { kindLabel }
    public var sortDuration: Double { clip?.durationS ?? -1 }
    public var sortSize: Int64 { clip?.fileSize ?? -1 }
    public var sortPixels: Int { (clip?.width ?? 0) * (clip?.height ?? 0) }
}

// MARK: - Sort keys

public enum LibrarySortKey: String, CaseIterable, Identifiable, Sendable {
    case name, dateAdded, kind, duration, resolution, size
    public var id: Self { self }

    /// Keys offered in the toolbar Sort menu (kind/resolution are still
    /// reachable by clicking the list's column headers).
    public static let menuCases: [LibrarySortKey] = [.name, .dateAdded, .duration, .size]

    public var label: String {
        switch self {
        case .name: return "Name"
        case .dateAdded: return "Date Added"
        case .kind: return "Kind"
        case .duration: return "Duration"
        case .resolution: return "Resolution"
        case .size: return "Size"
        }
    }

    /// The `KeyPathComparator` that sorts `LibraryEntry`s by this key.
    public func comparator(order: SortOrder) -> KeyPathComparator<LibraryEntry> {
        switch self {
        case .name: return KeyPathComparator(\LibraryEntry.sortName, order: order)
        case .dateAdded: return KeyPathComparator(\LibraryEntry.sortDate, order: order)
        case .kind: return KeyPathComparator(\LibraryEntry.sortKind, order: order)
        case .duration: return KeyPathComparator(\LibraryEntry.sortDuration, order: order)
        case .resolution: return KeyPathComparator(\LibraryEntry.sortPixels, order: order)
        case .size: return KeyPathComparator(\LibraryEntry.sortSize, order: order)
        }
    }

    public init(keyPath: PartialKeyPath<LibraryEntry>) {
        if keyPath == \LibraryEntry.sortName { self = .name }
        else if keyPath == \LibraryEntry.sortKind { self = .kind }
        else if keyPath == \LibraryEntry.sortDuration { self = .duration }
        else if keyPath == \LibraryEntry.sortPixels { self = .resolution }
        else if keyPath == \LibraryEntry.sortSize { self = .size }
        else { self = .dateAdded }
    }
}

// MARK: - Clip display helpers

extension Clip {
    public var durationFormatted: String? {
        guard let seconds = durationS else { return nil }
        return Duration.seconds(seconds)
            .formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    public var resolutionFormatted: String? {
        guard let width, let height else { return nil }
        return "\(width)×\(height)"
    }

    public var fileSizeFormatted: String? {
        fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}
