//
//  LibraryTableView.swift
//  BetterContentLibrary
//
//  Ported from VideoTag's ClipTableView: a native NSTableView for snappy
//  selection, native column sorting, and arrow-key navigation. Adapted to
//  BetterContentLibrary's folder+clip model with inline rename, double-click to
//  open, and a context menu that includes "Move to" (BCL's folder support).
//

import AppKit
import SwiftUI
import BetterContentCore

struct LibraryTableView: NSViewRepresentable {
    var items: [LibraryEntry]
    var subfolders: [Folder]
    var regenerating: Set<UUID>
    /// A clip's lifecycle tag (uploading / scheduled / posted / …), derived
    /// upstream so the table just renders it.
    var displayStatus: (Clip) -> ClipDisplayStatus
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<LibraryEntry>]

    var onOpen: (LibraryEntry) -> Void
    var onRename: (LibraryEntry, String) -> Void
    var onMove: ([String], UUID?) -> Void
    var onPreview: (Clip) -> Void
    var onMarkPosted: ([Clip]) -> Void
    var onRegenerate: ([Clip]) -> Void
    var onDeleteFolder: (Folder) -> Void
    var onDeleteClips: ([Clip]) -> Void

    private static let columns: [(id: String, title: String, width: CGFloat, min: CGFloat)] = [
        ("name", "Name", 300, 180),
        ("status", "Status", 90, 70),
        ("kind", "Kind", 80, 60),
        ("created", "Date Added", 160, 120),
        ("duration", "Duration", 80, 60),
        ("resolution", "Resolution", 100, 80),
        ("size", "Size", 90, 60),
    ]

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 22
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.doubleClicked)

        for spec in Self.columns {
            let column = NSTableColumn(identifier: .init(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = spec.min
            // Status is derived (not a LibraryEntry sort key), so it doesn't sort.
            if spec.id != "status" {
                column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            }
            tableView.addTableColumn(column)
        }

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.items = items
        // Reload only when the displayed rows actually change, so selection and
        // arrow-nav (which re-run updateNSView) stay snappy.
        let signature = contentSignature(items)
        if signature != coordinator.contentSignature {
            coordinator.contentSignature = signature
            coordinator.tableView?.reloadData()
        }
        coordinator.syncSortDescriptors()
        coordinator.syncSelection()
    }

    private func contentSignature(_ items: [LibraryEntry]) -> Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.name)
            hasher.combine(item.sortDuration)
            hasher.combine(item.sortSize)
            hasher.combine(item.sortDate)
            if let clip = item.clip { hasher.combine(displayStatus(clip)) }
        }
        return hasher.finalize()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: Column <-> comparator mapping

    static func comparator(columnID: String, ascending: Bool) -> KeyPathComparator<LibraryEntry> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch columnID {
        case "name": return KeyPathComparator(\.sortName, order: order)
        case "kind": return KeyPathComparator(\.sortKind, order: order)
        case "created": return KeyPathComparator(\.sortDate, order: order)
        case "duration": return KeyPathComparator(\.sortDuration, order: order)
        case "resolution": return KeyPathComparator(\.sortPixels, order: order)
        case "size": return KeyPathComparator(\.sortSize, order: order)
        default: return KeyPathComparator(\.sortDate, order: order)
        }
    }

    static func columnID(for comparator: KeyPathComparator<LibraryEntry>) -> String {
        switch comparator.keyPath {
        case \LibraryEntry.sortName: "name"
        case \LibraryEntry.sortKind: "kind"
        case \LibraryEntry.sortDuration: "duration"
        case \LibraryEntry.sortPixels: "resolution"
        case \LibraryEntry.sortSize: "size"
        default: "created"
        }
    }

    static func text(for item: LibraryEntry, columnID: String) -> String {
        switch columnID {
        case "name": return item.name
        case "kind": return item.kindLabel
        case "created": return item.dateAdded.formatted(date: .abbreviated, time: .shortened)
        case "duration": return item.clip?.durationFormatted ?? "—"
        case "resolution": return item.clip?.resolutionFormatted ?? "—"
        case "size": return item.clip?.fileSizeFormatted ?? "—"
        default: return ""
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var parent: LibraryTableView
        var items: [LibraryEntry] = []
        weak var tableView: NSTableView?
        var contentSignature = 0
        private var isSyncingSelection = false

        init(_ parent: LibraryTableView) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, items.indices.contains(row) else { return nil }
            let id = tableColumn.identifier
            let item = items[row]
            let isName = (id.rawValue == "name")

            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
                ?? Self.makeCell(identifier: id, withIcon: isName)

            if id.rawValue == "status" {
                // Derived status tag, tinted in the status color. Cells are
                // reused, so both branches set the color explicitly.
                if let clip = item.clip {
                    let status = parent.displayStatus(clip)
                    cell.textField?.stringValue = status.label
                    cell.textField?.textColor = NSColor(status.color)
                } else {
                    cell.textField?.stringValue = "—"
                    cell.textField?.textColor = .tertiaryLabelColor
                }
            } else {
                cell.textField?.stringValue = LibraryTableView.text(for: item, columnID: id.rawValue)
                cell.textField?.textColor = .labelColor
            }

            if isName {
                cell.imageView?.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
                cell.imageView?.contentTintColor = item.isFolder ? .controlAccentColor : .secondaryLabelColor
                cell.textField?.isEditable = true
                cell.textField?.delegate = self
                cell.textField?.tag = row
            }
            return cell
        }

        private static func makeCell(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingMiddle
            field.translatesAutoresizingMaskIntoConstraints = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            cell.addSubview(field)
            cell.textField = field

            if withIcon {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            } else {
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            return cell
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tableView else { return }
            let ids = Set(tableView.selectedRowIndexes.compactMap { idx in
                items.indices.contains(idx) ? items[idx].id : nil
            })
            if ids != parent.selection {
                parent.selection = ids
            }
        }

        func syncSelection() {
            guard let tableView else { return }
            let desired = IndexSet(items.enumerated().compactMap {
                parent.selection.contains($0.element.id) ? $0.offset : nil
            })
            guard desired != tableView.selectedRowIndexes else { return }
            isSyncingSelection = true
            tableView.selectRowIndexes(desired, byExtendingSelection: false)
            isSyncingSelection = false
        }

        // MARK: Sorting

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            parent.sortOrder = [LibraryTableView.comparator(columnID: key, ascending: descriptor.ascending)]
        }

        func syncSortDescriptors() {
            guard let tableView, let comparator = parent.sortOrder.first else { return }
            let key = LibraryTableView.columnID(for: comparator)
            let ascending = comparator.order == .forward
            let current = tableView.sortDescriptors.first
            if current?.key != key || current?.ascending != ascending {
                tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
            }
        }

        // MARK: Rename (inline editing of the name field)

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  items.indices.contains(field.tag) else { return }
            let item = items[field.tag]
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty, newName != item.name {
                parent.onRename(item, newName)
            } else {
                field.stringValue = item.name
            }
        }

        // MARK: Open / context menu

        @objc func doubleClicked() {
            guard let tableView, items.indices.contains(tableView.clickedRow) else { return }
            parent.onOpen(items[tableView.clickedRow])
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView, items.indices.contains(tableView.clickedRow) else { return }
            let clicked = items[tableView.clickedRow]

            switch clicked {
            case .folder(let folder):
                addItem(to: menu, "Open") { [weak self] in self?.parent.onOpen(clicked) }
                addItem(to: menu, "Rename") { [weak self] in self?.beginRename(row: tableView.clickedRow) }
                menu.addItem(.separator())
                addItem(to: menu, "Delete") { [weak self] in self?.parent.onDeleteFolder(folder) }

            case .clip(let clip):
                let targetClips = self.targetClips(clicked: clicked)
                addItem(to: menu, "Preview", enabled: clip.isPlayable) { [weak self] in self?.parent.onPreview(clip) }
                let postedTargets = targetClips.filter { parent.displayStatus($0) == .scheduled }
                if !postedTargets.isEmpty {
                    let title = postedTargets.count > 1 ? "Mark \(postedTargets.count) as Posted" : "Mark as Posted"
                    addItem(to: menu, title) { [weak self] in self?.parent.onMarkPosted(postedTargets) }
                }
                addItem(to: menu, "Rename") { [weak self] in self?.beginRename(row: tableView.clickedRow) }
                let regenTitle = targetClips.count > 1 ? "Regenerate \(targetClips.count) Thumbnails" : "Regenerate Thumbnail"
                addItem(to: menu, regenTitle, enabled: clip.isPlayable) { [weak self] in
                    self?.parent.onRegenerate(targetClips)
                }
                menu.addItem(.separator())
                menu.addItem(moveMenuItem(for: targetClips.map(\.id.uuidString)))
                menu.addItem(.separator())
                let deleteTitle = targetClips.count > 1 ? "Delete \(targetClips.count) Videos" : "Delete"
                addItem(to: menu, deleteTitle) { [weak self] in self?.parent.onDeleteClips(targetClips) }
            }
        }

        /// Clips a context action applies to: the whole clip selection if the
        /// clicked row is part of it, otherwise just that clip.
        private func targetClips(clicked: LibraryEntry) -> [Clip] {
            let selected = items.compactMap(\.clip).filter { parent.selection.contains("clip-\($0.id.uuidString)") }
            if let clip = clicked.clip, selected.contains(where: { $0.id == clip.id }) {
                return selected
            }
            return clicked.clip.map { [$0] } ?? []
        }

        private func moveMenuItem(for clipIDs: [String]) -> NSMenuItem {
            let item = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            addItem(to: submenu, "Library (root)") { [weak self] in self?.parent.onMove(clipIDs, nil) }
            if !parent.subfolders.isEmpty {
                submenu.addItem(.separator())
                for folder in parent.subfolders {
                    addItem(to: submenu, folder.name) { [weak self] in self?.parent.onMove(clipIDs, folder.id) }
                }
            }
            item.submenu = submenu
            return item
        }

        private func beginRename(row: Int) {
            tableView?.editColumn(0, row: row, with: nil, select: true)
        }

        private func addItem(to menu: NSMenu, _ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.representedObject = Handler(handler)
            menu.addItem(item)
        }

        @objc private func menuAction(_ sender: NSMenuItem) {
            (sender.representedObject as? Handler)?.run()
        }

        private final class Handler {
            let run: () -> Void
            init(_ run: @escaping () -> Void) { self.run = run }
        }
    }
}
