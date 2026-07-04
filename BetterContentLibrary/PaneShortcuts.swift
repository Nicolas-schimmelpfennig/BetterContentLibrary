//
//  PaneShortcuts.swift
//  BetterContentLibrary
//
//  Bare-key pane toggles (default L = Library, S = Schedule), user-editable in
//  Settings. Implemented as a local key monitor rather than menu key
//  equivalents: a bare-letter menu equivalent would fire while the user types
//  in a text field, whereas the monitor can check the first responder and
//  yield. Only acts in the main window (not sheets or Settings), never while
//  editing text, and keeps at least one pane visible.
//

import AppKit
import BetterContentCore

enum PaneShortcuts {
    /// The current toggle keys (single lowercase characters), Settings-backed.
    static var libraryKey: String {
        UserDefaults.standard.string(forKey: SettingsKey.libraryPaneShortcut) ?? "l"
    }
    static var scheduleKey: String {
        UserDefaults.standard.string(forKey: SettingsKey.schedulePaneShortcut) ?? "s"
    }
}

/// One local keyDown monitor for the pane toggles, alive while MainView is.
/// Writes straight to UserDefaults; the panes' `@AppStorage` picks it up.
@MainActor
final class PaneShortcutMonitor {
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
        // Only the main window — not sheets (schedule editor, drafts) and not
        // the Settings window.
        guard let window = event.window, window == NSApp.mainWindow else { return event }

        // Never while typing (rename fields, search, sheet text editors).
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText {
            return event
        }

        // Bare keys only; any command-like modifier passes through.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { return event }

        guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else {
            return event
        }

        switch key {
        case PaneShortcuts.libraryKey:
            toggle(SettingsKey.showLibraryPane, other: SettingsKey.showSchedulePane)
            return nil
        case PaneShortcuts.scheduleKey:
            toggle(SettingsKey.showSchedulePane, other: SettingsKey.showLibraryPane)
            return nil
        default:
            return event
        }
    }

    /// Flips a pane, re-showing the other if both would end up hidden.
    private func toggle(_ key: String, other: String) {
        let defaults = UserDefaults.standard
        let newValue = !(defaults.object(forKey: key) as? Bool ?? true)
        defaults.set(newValue, forKey: key)
        if !newValue, !(defaults.object(forKey: other) as? Bool ?? true) {
            defaults.set(true, forKey: other)
        }
    }
}
