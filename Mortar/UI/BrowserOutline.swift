import AppKit
import SwiftUI

struct BrowserOutline: NSViewRepresentable {
    var rows: [BrowserRow]
    var root: String
    @Bindable var model: AppModel

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.style = .inset
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowSizeStyle = .medium
        outline.indentationPerLevel = 16
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
        outline.doubleAction = #selector(Coordinator.open(_:))
        outline.target = context.coordinator
        outline.menu = context.coordinator.menu()
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        context.coordinator.installColumns(on: outline)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.root = root
        context.coordinator.rows = rows
        if let outline = context.coordinator.outline {
            context.coordinator.syncColumns(outline)
            if let saved = context.coordinator.model.library.session("browser.scroll"), let y = Double(saved) {
                outline.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: y))
            }
            outline.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model, root: root, rows: rows) }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var model: AppModel
        var root: String
        var rows: [BrowserRow]
        weak var outline: NSOutlineView?

        init(model: AppModel, root: String, rows: [BrowserRow]) {
            self.model = model
            self.root = root
            self.rows = rows
        }

        func installColumns(on outline: NSOutlineView) {
            rebuildColumns(on: outline)
        }

        func syncColumns(_ outline: NSOutlineView) {
            let wanted = model.orderedBrowserColumns
            let current = outline.tableColumns.map(\.identifier.rawValue)
            if current != wanted { rebuildColumns(on: outline) }
            else { retitle(outline); refreshHeaderMenu(outline) }
        }

        private func rebuildColumns(on outline: NSOutlineView) {
            for column in outline.tableColumns { outline.removeTableColumn(column) }
            for id in model.orderedBrowserColumns {
                let flexible = id == "name"
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = title(id)
                column.minWidth = flexible ? 160 : 64
                column.width = flexible ? 280 : (id == "kind" || id == "date" ? 140 : 88)
                if let saved = savedWidth(id) { column.width = saved }
                if !flexible { column.maxWidth = id == "kind" ? 220 : 180 }
                column.resizingMask = flexible ? .autoresizingMask : []
                outline.addTableColumn(column)
            }
        outline.outlineTableColumn = outline.tableColumns.first
        NotificationCenter.default.addObserver(self, selector: #selector(columnResized(_:)), name: NSTableView.columnDidResizeNotification, object: outline)
        refreshHeaderMenu(outline)
    }

    private func savedWidth(_ id: String) -> CGFloat? {
        guard let saved = model.library.session("browser.columnWidths") else { return nil }
        for part in saved.split(separator: ",") {
            let bits = part.split(separator: "=")
            if bits.count == 2, bits[0] == Substring(id), let width = Double(bits[1]) { return CGFloat(width) }
        }
        return nil
    }

    @objc private func columnResized(_ notification: Notification) {
        guard let outline else { return }
        let encoded = outline.tableColumns.map { "\($0.identifier.rawValue)=\(Int($0.width))" }.joined(separator: ",")
        model.library.setSession("browser.columnWidths", encoded)
        if let y = outline.enclosingScrollView?.contentView.bounds.origin.y {
            model.library.setSession("browser.scroll", "\(y)")
        }
    }

        private func refreshHeaderMenu(_ outline: NSOutlineView) {
            let menu = NSMenu()
            menu.delegate = self
            for id in ["repos", "props", "lock", "depth"] {
                let item = NSMenuItem(title: title(id), action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.representedObject = id
                item.target = self
                item.state = model.browserColumns.contains(id) ? .on : .off
                menu.addItem(item)
            }
            outline.headerView?.menu = menu
        }

        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? String else { return }
            model.toggleBrowserColumn(id)
            if let outline { syncColumns(outline); outline.reloadData() }
        }

        func retitle(_ outline: NSOutlineView) {
            for column in outline.tableColumns {
                column.title = title(column.identifier.rawValue)
            }
        }

        private func title(_ id: String) -> String {
            switch id {
            case "name": return model.t("column.name")
            case "date": return model.t("column.date")
            case "size": return model.t("column.size")
            case "revision": return model.t("column.revision")
            case "author": return model.t("column.author")
            case "repos": return model.t("column.repos")
            case "props": return model.t("column.props")
            case "lock": return model.t("column.lock")
            case "depth": return model.t("column.depth")
            default: return model.t("column.kind")
            }
        }

        func children(of parent: String) -> [BrowserRow] {
            model.filteredRows(parent: parent)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: (item as? BrowserRow)?.path ?? root).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: (item as? BrowserRow)?.path ?? root)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? BrowserRow)?.isDirectory ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let row = item as? BrowserRow, let column = tableColumn?.identifier.rawValue else { return nil }
            if column == "name" {
                let cell = outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("nameCell"), owner: self) as? NameCell ?? NameCell()
                cell.identifier = NSUserInterfaceItemIdentifier("nameCell")
                cell.apply(row, icon: fileIcon(row))
                return cell
            }
            let id = NSUserInterfaceItemIdentifier(column)
            let text = outlineView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
            text.identifier = id
            text.lineBreakMode = .byTruncatingTail
            text.font = .systemFont(ofSize: 13)
            text.textColor = .secondaryLabelColor
            switch column {
            case "date":
                text.stringValue = model.browserDate(row.date)
            case "size":
                text.stringValue = row.isDirectory ? "--" : model.formattedSize(row.size)
            case "revision":
                text.stringValue = row.revision
            case "author":
                text.stringValue = row.author
            case "repos":
                text.stringValue = row.reposItem == "none" ? "" : row.reposItem
            case "props":
                text.stringValue = row.props == "none" || row.props == "normal" ? "" : row.props
            case "lock":
                text.stringValue = row.lock
            case "depth":
                text.stringValue = row.depth
            default:
                text.stringValue = fileKind(row)
            }
            return text
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline else { return }
            let selected = outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? BrowserRow }
            model.selectedPaths = selected.map(\.path)
            if let first = selected.first, let full = model.absolutePath(first.path) {
                Task { await model.loadInspector(path: full) }
            }
        }

        @objc func open(_ sender: Any?) {
            guard let outline, let row = outline.item(atRow: outline.clickedRow) as? BrowserRow else { return }
            let flags = NSEvent.modifierFlags
            guard let full = model.absolutePath(row.path) else {
                model.openPath(row.path, directory: row.isDirectory)
                return
            }
            let url = URL(fileURLWithPath: full)
            if flags.contains(.command) {
                if row.isDirectory, !isPackage(row) {
                    NSWorkspace.shared.open(url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                return
            }
            if isPackage(row), !flags.contains(.option) {
                NSWorkspace.shared.open(url)
                return
            }
            model.openPath(row.path, directory: row.isDirectory)
        }

        func menu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: model.t("action.update"), action: #selector(update(_:)), keyEquivalent: "")
            menu.addItem(withTitle: model.t("action.commit"), action: #selector(commit(_:)), keyEquivalent: "")
            menu.addItem(withTitle: model.t("action.revert"), action: #selector(revert(_:)), keyEquivalent: "")
            menu.addItem(withTitle: model.t("action.compareBase"), action: #selector(compare(_:)), keyEquivalent: "")
            menu.addItem(withTitle: model.t("view.log"), action: #selector(showLog(_:)), keyEquivalent: "")
            menu.addItem(withTitle: model.t("action.showAll"), action: #selector(showAll(_:)), keyEquivalent: "")
            menu.addItem(withTitle: model.t("column.depth") + " empty", action: #selector(depthEmpty(_:)), keyEquivalent: "")
            menu.addItem(withTitle: model.t("column.depth") + " infinity", action: #selector(depthFull(_:)), keyEquivalent: "")
            for item in menu.items { item.target = self }
            return menu
        }

        @objc func update(_ sender: Any?) { Task { await model.update(revision: "HEAD", depth: nil, externals: true) } }
        @objc func commit(_ sender: Any?) { model.prepareCommit() }
        @objc func revert(_ sender: Any?) { Task { await model.revert(paths: model.selectedPaths) } }
        @objc func compare(_ sender: Any?) { Task { await model.compareBase() } }
        @objc func showLog(_ sender: Any?) { Task { await model.loadLog() } }
        @objc func showAll(_ sender: Any?) {
            model.filter = "all"
            model.filterLocked = false
            model.search = ""
            if let outline { outline.scrollRowToVisible(outline.clickedRow) }
        }
        @objc func depthEmpty(_ sender: Any?) { Task { await model.setDepth("empty") } }
        @objc func depthFull(_ sender: Any?) { Task { await model.setDepth("infinity") } }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let row = item as? BrowserRow, let full = model.absolutePath(row.path) else { return nil }
            return NSURL(fileURLWithPath: full)
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            info.draggingSourceOperationMask.contains(.copy) ? .copy : .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty else { return false }
            let inside = urls.allSatisfy { url in
                guard let wc = model.selectedWorkingCopy else { return false }
                return url.path.hasPrefix(wc.path + "/") || url.path == wc.path
            }
            if !inside || model.selectedWorkingCopy == nil {
                model.receiveExternalDrop(urls)
                return true
            }
            let destination = (item as? BrowserRow)?.path ?? root
            let copy = info.draggingSourceOperationMask.contains(.copy)
            guard let wc = model.selectedWorkingCopy else { return false }
            for url in urls {
                let relative = String(url.path.dropFirst(wc.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !relative.isEmpty else { continue }
                let name = (relative as NSString).lastPathComponent
                let dest = destination.isEmpty ? name : destination + "/" + name
                if copy { Task { await model.copyItem(from: relative, to: dest) } }
                else { Task { await model.move(from: relative, to: dest) } }
            }
            return true
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            for item in menu.items {
                if let id = item.representedObject as? String {
                    item.state = model.browserColumns.contains(id) ? .on : .off
                }
            }
        }

        private func isPackage(_ row: BrowserRow) -> Bool {
            let ext = (row.name as NSString).pathExtension.lowercased()
            return ["xcodeproj", "xcworkspace", "nib", "pages", "app", "bundle", "framework"].contains(ext)
        }

        private func opensAsFile(_ row: BrowserRow) -> Bool { isPackage(row) }

        private func fileIcon(_ row: BrowserRow) -> NSImage {
            let image: NSImage
            if let full = model.absolutePath(row.path), FileManager.default.fileExists(atPath: full) {
                image = NSWorkspace.shared.icon(forFile: full)
            } else {
                image = NSWorkspace.shared.icon(forFileType: (row.name as NSString).pathExtension)
            }
            image.size = NSSize(width: 16, height: 16)
            return image
        }

        private func fileKind(_ row: BrowserRow) -> String {
            if let full = model.absolutePath(row.path),
               let kind = try? URL(fileURLWithPath: full).resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription,
               !kind.isEmpty {
                return kind
            }
            if row.isDirectory, !opensAsFile(row) { return model.t("kind.folder") }
            let ext = (row.name as NSString).pathExtension
            if ext.isEmpty { return model.t("kind.file") }
            return ext.uppercased()
        }
    }
}

private final class NameCell: NSTableCellView {
    private let badge = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        badge.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 3
        badge.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.wantsLayer = true
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
        dot.layer?.cornerRadius = 3
        let stack = NSStackView(views: [badge, icon, label, dot])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        textField = label
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ row: BrowserRow, icon fileIcon: NSImage) {
        label.stringValue = row.name
        label.textColor = row.item == "missing" || row.item == "ignored" ? .secondaryLabelColor : .labelColor
        let base = NSFont.systemFont(ofSize: 13)
        label.font = row.item == "ignored" || row.letter == "X" ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
        icon.image = fileIcon
        icon.contentTintColor = nil
        badge.isHidden = row.letter.isEmpty
        badge.stringValue = row.letter
        badge.layer?.backgroundColor = statusColor(row.letter).cgColor
        dot.isHidden = !(row.isDirectory && row.containsChanges)
        toolTip = row.item
    }

    private func statusColor(_ letter: String) -> NSColor {
        switch letter {
        case "M": return NSColor(calibratedRed: 0, green: 0.48, blue: 1, alpha: 1)
        case "A": return NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case "D", "I": return .secondaryLabelColor
        case "C": return NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 1)
        case "!", "~": return NSColor(calibratedRed: 1, green: 0.58, blue: 0, alpha: 1)
        case "?": return NSColor(calibratedRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)
        case "X": return NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.98, alpha: 1)
        case "S": return NSColor(calibratedRed: 0.35, green: 0.34, blue: 0.84, alpha: 1)
        case "R": return NSColor(calibratedRed: 1, green: 0.18, blue: 0.33, alpha: 1)
        default: return .labelColor
        }
    }
}
