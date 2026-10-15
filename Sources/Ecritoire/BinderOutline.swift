import AppKit
import SwiftUI
import EcritoireCore

extension NSPasteboard.PasteboardType {
    static let binderItem = NSPasteboard.PasteboardType("fr.ecritoire.element-classeur")
}

/// Barre latérale : arbre du classeur dans un NSOutlineView (glisser-déposer, renommage, menu contextuel).
struct BinderOutline: NSViewRepresentable {
    @ObservedObject var workspace: Workspace

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = BinderOutlineView()
        let column = NSTableColumn(identifier: .init("nom"))
        column.isEditable = true
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = Palette.panelLavender
        outline.rowHeight = 22
        outline.indentationPerLevel = 16
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = true
        outline.allowsMultipleSelection = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([.binderItem])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.panelLavender
        context.coordinator.outline = outline
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.treeVersion != workspace.treeVersion {
            coordinator.treeVersion = workspace.treeVersion
            coordinator.reload()
        }
        coordinator.syncSelection()
        if let url = workspace.renameRequest {
            DispatchQueue.main.async {
                workspace.renameRequest = nil
                coordinator.beginRenaming(url)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        let workspace: Workspace
        weak var outline: NSOutlineView?
        var treeVersion = -1
        private var updatingSelection = false
        private var expanded: Set<String> = []

        init(workspace: Workspace) { self.workspace = workspace }

        private var expandedKey: String { "dossiersOuverts:" + (workspace.rootURL?.path ?? "") }

        func reload() {
            guard let outline else { return }
            previews.removeAll()
            if let saved = UserDefaults.standard.stringArray(forKey: expandedKey) { expanded = Set(saved) }
            updatingSelection = true
            outline.reloadData()
            expandSaved(workspace.root)
            updatingSelection = false
            syncSelection()
        }

        private func expandSaved(_ node: BinderNode?) {
            guard let node else { return }
            for child in node.children where child.isFolder && expanded.contains(child.url.path) {
                outline?.expandItem(child)
                expandSaved(child)
            }
        }

        func syncSelection() {
            guard let outline else { return }
            let current = outline.item(atRow: outline.selectedRow) as? BinderNode
            let wanted = workspace.selectedURL.flatMap { workspace.root?.find($0) }
            guard current !== wanted else { return }
            updatingSelection = true
            defer { updatingSelection = false }
            guard let wanted else {
                outline.deselectAll(nil)
                return
            }
            var ancestor = wanted.parent
            var chain: [BinderNode] = []
            while let a = ancestor, a !== workspace.root { chain.insert(a, at: 0); ancestor = a.parent }
            chain.forEach { outline.expandItem($0) }
            let row = outline.row(forItem: wanted)
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }

        func beginRenaming(_ url: URL) {
            guard let outline, let node = workspace.root?.find(url) else { return }
            let row = outline.row(forItem: node)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            outline.scrollRowToVisible(row)
            outline.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        private func node(_ item: Any?) -> BinderNode? { (item as? BinderNode) ?? workspace.root }

        // MARK: Source de données

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            node(item)?.children.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            node(item)!.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? BinderNode)?.isFolder ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? BinderNode else { return nil }
            let id = NSUserInterfaceItemIdentifier("cellule")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
            // Document « Sans titre » : sa première ligne, en italique gris (comme Scrivener).
            if BinderIcons.isUntitled(node), let preview = preview(for: node) {
                cell.textField?.stringValue = preview
                cell.textField?.font = NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
                cell.textField?.textColor = Palette.secondaryText
            } else {
                cell.textField?.stringValue = node.displayName
                cell.textField?.font = .systemFont(ofSize: 13)
                cell.textField?.textColor = Palette.text
            }
            let (image, color) = BinderIcons.appearance(for: node)
            cell.imageView?.image = image
            cell.imageView?.contentTintColor = color
            return cell
        }

        private var previews: [String: String] = [:]

        private func preview(for node: BinderNode) -> String? {
            if let cached = previews[node.url.path] { return cached.isEmpty ? nil : cached }
            let text = BinderIcons.preview(of: node.url) ?? ""
            previews[node.url.path] = text
            return text.isEmpty ? nil : text
        }

        /// Au début du renommage, le champ montre le vrai nom (et non l'aperçu de la première ligne).
        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let outline else { return }
            let row = outline.row(for: field)
            guard row >= 0, let node = outline.item(atRow: row) as? BinderNode else { return }
            if field.stringValue != node.displayName {
                field.stringValue = node.displayName
                field.font = .systemFont(ofSize: 13)
                field.textColor = Palette.text
            }
        }

        private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            let field = NSTextField(labelWithString: "")
            field.isEditable = true
            field.isBordered = false
            field.drawsBackground = false
            field.lineBreakMode = .byTruncatingTail
            field.font = .systemFont(ofSize: 13)
            field.textColor = Palette.text
            field.delegate = self
            for v in [image, field] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(v)
            }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.imageView = image
            cell.textField = field
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            SoftRowView()
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let outline else { return }
            let node = outline.item(atRow: outline.selectedRow) as? BinderNode
            if workspace.selectedURL != node?.url { workspace.selectedURL = node?.url }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !updatingSelection, let node = notification.userInfo?["NSObject"] as? BinderNode else { return }
            expanded.insert(node.url.path)
            UserDefaults.standard.set(Array(expanded), forKey: expandedKey)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !updatingSelection, let node = notification.userInfo?["NSObject"] as? BinderNode else { return }
            expanded.remove(node.url.path)
            UserDefaults.standard.set(Array(expanded), forKey: expandedKey)
        }

        // MARK: Renommage

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let outline else { return }
            let row = outline.row(for: field)
            guard row >= 0, let node = outline.item(atRow: row) as? BinderNode else { return }
            let newName = field.stringValue
            if newName != node.displayName {
                workspace.rename(node.url, to: newName)
            }
            field.stringValue = (workspace.root?.find(node.url) ?? node).displayName
        }

        // MARK: Glisser-déposer

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? BinderNode else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(node.url.path, forType: .binderItem)
            return pbItem
        }

        private func draggedURL(_ info: NSDraggingInfo) -> URL? {
            info.draggingPasteboard.string(forType: .binderItem).map { URL(fileURLWithPath: $0) }
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let source = draggedURL(info), let target = node(item) else { return [] }
            if !target.isFolder {
                // Déposer sur un document : on le place juste après, dans le même dossier.
                guard let parent = target.parent, let i = parent.children.firstIndex(of: target) else { return [] }
                outlineView.setDropItem(parent === workspace.root ? nil : parent, dropChildIndex: i + 1)
                return .move
            }
            let src = source.standardizedFileURL.path
            let dst = target.url.standardizedFileURL.path
            if dst == src || dst.hasPrefix(src + "/") { return [] }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let source = draggedURL(info), let target = node(item) else { return false }
            workspace.move(source, into: target.url, at: index == NSOutlineViewDropOnItemIndex ? nil : index)
            if let item { outlineView.expandItem(item) }
            return true
        }

        // MARK: Menu contextuel

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline else { return }
            let clicked = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? BinderNode : nil
            func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
                let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
                let handler = MenuAction(action)
                item.target = handler
                item.representedObject = handler
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
            let ws = workspace
            add("Nouveau document", "doc.badge.plus") { ws.newDocument(relativeTo: clicked) }
            add("Nouveau dossier", "folder.badge.plus") { ws.newFolder(relativeTo: clicked) }
            guard let clicked else { return }
            menu.addItem(.separator())
            add("Renommer", "pencil") { [weak self] in self?.beginRenaming(clicked.url) }
            add("Afficher dans le Finder", "folder") { ws.revealInFinder(clicked.url) }
            // Sous-menu « Icône ».
            let iconItem = NSMenuItem(title: "Icône", action: nil, keyEquivalent: "")
            iconItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
            let iconMenu = NSMenu()
            let reset = NSMenuItem(title: "Par défaut", action: #selector(MenuAction.run), keyEquivalent: "")
            let resetHandler = MenuAction { ws.setIcon(nil, for: clicked.url) }
            reset.target = resetHandler
            reset.representedObject = resetHandler
            reset.state = clicked.icon == nil ? .on : .off
            iconMenu.addItem(reset)
            iconMenu.addItem(.separator())
            for entry in BinderIcons.catalog {
                let item = NSMenuItem(title: entry.label, action: #selector(MenuAction.run), keyEquivalent: "")
                let handler = MenuAction { ws.setIcon(entry.id, for: clicked.url) }
                item.target = handler
                item.representedObject = handler
                item.image = BinderIcons.menuImage(entry)
                item.state = clicked.icon == entry.id ? .on : .off
                iconMenu.addItem(item)
            }
            iconItem.submenu = iconMenu
            menu.addItem(iconItem)
            menu.addItem(.separator())
            add("Placer dans la corbeille", "trash") { ws.trash(clicked.url) }
        }
    }
}

/// Cible d'un élément de menu construit avec une closure.
final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

final class BinderOutlineView: NSOutlineView {
    /// Entrée : renommer l'élément sélectionné (comme dans le Finder).
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0,
           let cell = view(atColumn: 0, row: selectedRow, makeIfNecessary: false) as? NSTableCellView,
           let field = cell.textField {
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            return
        }
        super.keyDown(with: event)
    }
}
