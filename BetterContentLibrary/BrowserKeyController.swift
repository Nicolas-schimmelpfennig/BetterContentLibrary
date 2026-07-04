//
//  BrowserKeyController.swift
//  BetterContentLibrary
//
//  Ported from VideoTag's BrowserKeyController. Same approach: one local key
//  monitor drives Finder-style browser keys regardless of SwiftUI focus quirks.
//  Adapted for BetterContentLibrary — space opens the streaming preview (there's
//  no local file for Quick Look), and there's no ⌘C file copy.
//

import AppKit
import Combine
import SwiftUI

enum MoveDirection {
    case left, right, up, down

    init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .left
        case 124: self = .right
        case 125: self = .down
        case 126: self = .up
        default: return nil
        }
    }
}

/// Centralizes browser keyboard behavior through one local key monitor: spacebar
/// opens the preview for the primary selection, arrow keys move grid selection
/// Finder-style, and ⌘A selects everything. The space key is always yielded to
/// text fields (e.g. rename).
@MainActor
final class BrowserKeyController: ObservableObject {
    /// Bumped when an arrow key should move grid selection; the browser observes
    /// this and reads `pendingDirection`.
    @Published var arrowTick = 0
    /// Bumped on ⌘A; the browser selects all visible items.
    @Published var selectAllTick = 0
    /// Bumped on spacebar; the browser opens the primary selection's preview.
    @Published var spaceTick = 0

    /// False while the library pane is hidden, so its monitor doesn't eat
    /// space/arrows meant for whatever else is on screen.
    var isEnabled = true
    /// True when the grid (thumbnail) view is showing, false for the list.
    var isGridMode = true
    /// True when the detail pane (items) is active rather than the sidebar.
    /// Defaults true so arrows drive the grid on launch.
    var detailHasFocus = true
    /// True while a preview sheet is open, so space isn't double-handled.
    var isPreviewing = false

    private(set) var pendingDirection: MoveDirection?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Returns nil to consume the event, or the event to pass it through.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard isEnabled else { return event }

        // Never hijack keys while editing text (e.g. a rename field).
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText {
            return event
        }

        // Only the "command-like" modifiers matter; arrow keys also carry
        // .function / .numericPad, which we must ignore.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        // ⌘A selects every visible item, in both the grid and the list.
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "a" {
            selectAllTick &+= 1
            return nil
        }

        // Space and arrows only act without command-like modifiers, so
        // ⌘-shortcuts and shift+arrow pass through.
        guard modifiers.isEmpty else { return event }

        switch event.keyCode {
        case 49: // space
            guard !isPreviewing else { return event }
            spaceTick &+= 1
            return nil

        case 123, 124, 125, 126: // arrows
            guard let direction = MoveDirection(keyCode: event.keyCode) else { return event }
            // Grid has no native arrow nav, so we drive it whenever the detail
            // pane is active. The list (NSTableView) navigates itself.
            let shouldHandle = isGridMode ? detailHasFocus : false
            guard shouldHandle else { return event }
            pendingDirection = direction
            arrowTick &+= 1
            return nil

        default:
            return event
        }
    }
}

extension View {
    /// Installs the controller's key monitor for the lifetime of the view.
    func browserKeys(_ controller: BrowserKeyController) -> some View {
        onAppear { controller.start() }
            .onDisappear { controller.stop() }
    }
}
