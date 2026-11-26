import AppKit
import Combine
import SwiftUI

// The Workspace's tree: the Inbox, what is to do, what is due and the folders
// down the left, each opening to the folders and links in it as a list, and
// the links of the one picked in the area to the right, where the page of the
// same name shows them (WorkspacePanel). It stands in for the list of tabs
// while it is on in the tab column (WorkspaceColumnState), and it is the side
// of the page itself when the column is not there.
//
// The arrow keys do all of it: up and down from row to row, right to open a
// section to its list, left to fold it or to go up to the one that holds the
// row, Return to open a link, or to go over to the links on the right from a
// section.

struct WorkspaceColumn: View {
    @ObservedObject var browser: Browser
    @ObservedObject var state: WorkspaceColumnState
    @ObservedObject var nav: WorkspaceNav
    let space: Workspace
    /// The side of the Workspace page, rather than the tab column: with no
    /// way back to the tabs.
    var embedded = false

    /// A folder being asked for: where it goes.
    private struct FolderAsk {
        var parent: UUID?
        var moving: [WorkItem.ID] = []
    }

    @State private var asking: FolderAsk?
    @State private var folderName = ""
    /// What is typed in the search field; empty shows the tree.
    @State private var hunt = ""
    /// A folder the keys or its menu asked to delete, until it is answered.
    @State private var deleting: UUID?
    /// The row the arrow keys are on.
    @State private var cursor: String?
    /// The row a drag is over, drawn with a ring.
    @State private var targeted: String?
    /// The links picked together (⇧-click for a range, ⌘-click one by one),
    /// and the one a range runs from.
    @State private var marked: Set<WorkItem.ID> = []
    @State private var anchor: WorkItem.ID?
    /// Which view this is, for the key receiver to know its own answer.
    @State private var token = UUID()
    /// Titles arrive after the tab does, and a tab's page can move on without
    /// the list of tabs changing.
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var tools: WorkspaceTools { WorkspaceTools(browser: browser, space: space) }

    private var rows: [WorkspaceRow] { WorkspaceTree.rows(space, open: state.open) }

    /// The row under the keys: the one they were last on, or else the section
    /// the links on the right are of.
    private func current(in rows: [WorkspaceRow]) -> String? {
        if let cursor, rows.contains(where: { $0.id == cursor }) { return cursor }
        let section = WorkspaceTree.rowID(nav.place)
        return rows.contains(where: { $0.id == section }) ? section : nil
    }

    /// Whether the arrow keys are the tree's now.
    private var keyed: Bool { nav.keysOwned && nav.zone == .sections }

    /// The row under the keys, drawn when the tree has them.
    private var cursorFill: Color { keyed ? Color.accentColor.opacity(0.22) : Palette.wash }

    var body: some View {
        let rows = self.rows
        let here = current(in: rows)
        return VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            if !hunt.isEmpty {
                results
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(rows) { row in line(row, here: here) }
                    }
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button { ask(parent: nil) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    }
                }
                .onChange(of: cursor) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            tools.sync()
            WorkspaceKeys.shared.register(.sections, token: token) { key in handle(key) }
        }
        .onDisappear { WorkspaceKeys.shared.unregister(.sections, token: token) }
        .onChange(of: nav.place) { _, place in show(place) }
        .onReceive(browser.$tabs) { _ in tools.sync() }
        .onReceive(tick) { _ in tools.sync() }
        .alert("New folder", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            TextField("Name", text: $folderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { folderName = "" }
        } message: {
            Text("Choose a name for the folder.")
        }
    }

    /// The Workspace was sent to a place from somewhere else: the folders
    /// above it are opened, and the cursor goes to it.
    private func show(_ place: WorkspacePlace) {
        if case .folder(let id) = place {
            var up = space.folder(id)?.parent
            while let parent = up {
                state.open.insert(.folder(parent))
                up = space.folder(parent)?.parent
            }
        }
        cursor = WorkspaceTree.rowID(place)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 4) {
            Text("Workspace")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 4)
            small("folder.badge.plus", "New folder") { ask(parent: nil) }
            if !embedded {
                small(state.preview ? "eye.fill" : "eye",
                      state.preview ? "Stop showing pages while you move down the list"
                                    : "Show each page beside the list as you move down it") { state.preview.toggle() }
                small("sidebar.left", "Back to the tabs") { state.on = false }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .alert("Delete folder \u{201C}\(deleting.flatMap { space.folder($0)?.name } ?? "")\u{201D}?",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { deleteConfirmed() }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its links go to the Inbox and its folders move up a level. No link is deleted.")
        }
    }

    private func deleteConfirmed() {
        guard let id = deleting else { return }
        deleting = nil
        if nav.place == .folder(id) { nav.place = .inbox }
        cursor = nil
        space.removeFolder(id)
    }

    // MARK: search

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextField("Search", text: $hunt)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { openFirstResult() }
                .onExitCommand { hunt = "" }
            if !hunt.isEmpty {
                Button { hunt = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Palette.wash)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    /// The folders and links the words are in, in place of the tree.
    private var results: some View {
        let folders = space.searchFolders(hunt)
        let links = space.search(hunt)
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if folders.isEmpty && links.isEmpty {
                    Text("Nothing matches.")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                }
                ForEach(folders) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: folder.glyph).frame(width: 16).foregroundStyle(Palette.muted)
                        Text(space.path(of: folder.id)).lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                    .onTapGesture { openFolder(folder.id) }
                }
                ForEach(links) { item in
                    linkRow(item, id: "l/search/\(item.id)", depth: 0, picked: false)
                        .help("\(item.url)\n\(space.path(of: item.folder))")
                }
            }
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openFolder(_ id: UUID) {
        hunt = ""
        state.open.insert(.folder(id))
        show(.folder(id))
        pick(.folder(id), row: WorkspaceTree.rowID(.folder(id)))
    }

    /// Return in the field: the first folder, or else the first link.
    private func openFirstResult() {
        if let folder = space.searchFolders(hunt).first {
            openFolder(folder.id)
        } else if let item = space.search(hunt).first {
            tools.open(item)
        }
    }

    private func small(_ symbol: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: the rows

    private func count(_ place: WorkspacePlace) -> Int {
        switch place {
        case .inbox: return space.count(in: nil)
        case .todo: return space.todo().count
        case .due: return space.due().count
        case .folder(let id): return space.count(in: id)
        }
    }

    @ViewBuilder
    private func line(_ row: WorkspaceRow, here: String?) -> some View {
        switch row.kind {
        case .section(let section): sectionRow(section, id: row.id, depth: row.depth, picked: here == row.id)
        case .link(let item, _): linkRow(item, id: row.id, depth: row.depth, picked: here == row.id)
        }
    }

    /// Picks a section: its links show in the area to the right.
    private func pick(_ place: WorkspacePlace, row: String) {
        marked = []
        cursor = row
        guard nav.place != place else { return browser.showWorkspacePage() }
        nav.place = place
        browser.showWorkspacePage()
    }

    @ViewBuilder
    private func sectionRow(_ section: WorkspaceSection, id: String, depth: Int, picked: Bool) -> some View {
        let showing = nav.place == section.place
        let folder = section.folder
        let content = WorkspaceTree.hasContent(section.place, in: space)
        let open = state.open.contains(section.place)
        let accepts = section.place == .inbox || folder != nil
        let base = HStack(spacing: 4) {
            // The chevron opens and folds the list, for a section that has
            // anything to list.
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .frame(width: 14, height: 22)
                .opacity(content ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { if content { state.toggle(section.place) } }
            Button {
                nav.go(.sections)
                pick(section.place, row: id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: section.symbol).frame(width: 16).foregroundStyle(Palette.muted)
                    Text(section.title).lineLimit(1)
                    Spacer(minLength: 4)
                    let total = count(section.place)
                    if total > 0 { Text("\(total)").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .padding(.leading, CGFloat(depth) * 12)
        .background(picked ? cursorFill : (showing ? Palette.wash : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(accepts && targeted == id ? 1 : 0)
        )
        .dropDestination(for: WorkDrag.self) { drags, _ in
            accepts ? drop(drags, onto: folder) : false
        } isTargeted: { on in
            if on { targeted = id } else if targeted == id { targeted = nil }
        }
        if let folder {
            base
                .draggable(WorkDrag(folder: folder))
                .contextMenu {
                    Button { ask(parent: space.folder(folder)?.parent) } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Button { ask(parent: folder) } label: { Label("New Subfolder", systemImage: "folder.badge.plus") }
                    if let made = space.folder(folder) { FolderIconMenu(space: space, folder: made) }
                    Divider()
                    Button("Delete Folder…", role: .destructive) { deleting = folder }
                }
        } else {
            base
        }
    }

    private func linkRow(_ item: WorkItem, id: String, depth: Int, picked: Bool) -> some View {
        let live = space.isLive(item)
        return HStack(spacing: 6) {
            Circle()
                .fill(live ? Palette.safe : Palette.faint)
                .frame(width: 6, height: 6)
            Text(item.label)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let status = item.status {
                Circle()
                    .fill(status == .done ? Palette.safe : status == .doing ? Color.accentColor : Palette.unsafe)
                    .frame(width: 7, height: 7)
                    .help(status.title)
            }
            if item.priority > 0 {
                Text(String(repeating: "!", count: item.priority))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.unsafe)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .padding(.leading, CGFloat(depth) * 12 + 10)
        .opacity(live ? 1 : 0.6)
        .background(marked.contains(item.id) ? Color.accentColor.opacity(0.32)
                    : picked ? cursorFill : (tools.isFront(item) ? Palette.wash : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(targeted == id ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { click(item, id: id) }
        .draggable(WorkDrag(items: carried(with: item)))
        .dropDestination(for: WorkDrag.self) { drags, _ in
            drop(drags, onto: item.folder)
        } isTargeted: { on in
            if on { targeted = id } else if targeted == id { targeted = nil }
        }
        .contextMenu {
            let ids = carried(with: item)
            WorkItemMenu(tools: tools, item: item, ids: ids, ask: { parent, moving in
                ask(parent: parent, moving: moving)
            }, removed: { marked = [] })
        }
        .help(item.url)
    }

    // MARK: picking links together

    /// The links of the rows shown, top to bottom.
    private var linkOrder: [WorkItem.ID] {
        rows.compactMap { row in
            if case .link(let item, _) = row.kind { return item.id }
            return nil
        }
    }

    /// What a drag or a menu on `item` takes: the whole pick when the item
    /// is in it, else the item alone.
    private func carried(with item: WorkItem) -> [WorkItem.ID] {
        guard marked.contains(item.id), marked.count > 1 else { return [item.id] }
        return linkOrder.filter { marked.contains($0) }
    }

    /// A click on a link: ⇧ picks the range from the last one clicked, ⌘
    /// adds or takes away one; a plain click opens it and starts over.
    private func click(_ item: WorkItem, id: String) {
        let flags = NSEvent.modifierFlags
        cursor = id
        nav.go(.sections)
        if flags.contains(.shift) {
            let order = linkOrder
            if let from = anchor.flatMap({ order.firstIndex(of: $0) }) ?? order.firstIndex(of: item.id),
               let to = order.firstIndex(of: item.id) {
                marked = Set(order[min(from, to)...max(from, to)])
            }
            if anchor == nil { anchor = item.id }
        } else if flags.contains(.command) {
            if marked.contains(item.id) { marked.remove(item.id) } else { marked.insert(item.id) }
            anchor = item.id
        } else {
            marked = []
            anchor = item.id
            keep(item)
            tools.open(item)
        }
    }

    /// An item opened on purpose is no longer the preview's to replace.
    private func keep(_ item: WorkItem) {
        if let live = tools.tab(for: item), live === state.previewTab { state.previewTab = nil }
    }

    /// The page shown beside the list while the arrows walk it: a tab that
    /// is already open is brought forward; any other page goes in the one
    /// preview tab, which the next page replaces.
    private func showPreview(of item: WorkItem) {
        if let live = tools.tab(for: item) {
            browser.select(live)
            return
        }
        guard let url = URL(string: item.url) else { return }
        if let tab = state.previewTab, browser.tabs.contains(where: { $0 === tab }) {
            tab.go(to: url)
            browser.select(tab)
        } else {
            state.previewTab = browser.open(url, foreground: true)
        }
    }

    // MARK: the keys

    /// The arrows walk the tree, Return opens a link or goes over to the
    /// links on the right from a section. Moving onto a section shows its
    /// links on the right; moving onto a link only marks it, and opens
    /// nothing until Return. Gives back whether the key was taken.
    private func handle(_ key: WorkspaceKeys.Key) -> Bool {
        guard hunt.isEmpty else { return false }
        let rows = self.rows
        let arrow: WorkspaceTree.ColumnKey
        switch key {
        case .up: arrow = .up
        case .down: arrow = .down
        case .left: arrow = .left
        case .right: arrow = .right
        case .delete:
            guard let id = current(in: rows), let row = rows.first(where: { $0.id == id }),
                  case .section(let section) = row.kind, let folder = section.folder else { return false }
            deleting = folder
            return true
        case .enter:
            guard let id = current(in: rows), let row = rows.first(where: { $0.id == id }) else { return false }
            switch row.kind {
            case .section(let section):
                pick(section.place, row: id)
                nav.go(.links)
            case .link(let item, _):
                keep(item)
                tools.open(item)
            }
            return true
        }
        let move = WorkspaceTree.treeMove(arrow, from: current(in: rows), in: rows, open: state.open, space: space)
        if let place = move.toggle { state.toggle(place) }
        if let next = move.cursor {
            cursor = next
            if let row = rows.first(where: { $0.id == next }) {
                switch row.kind {
                case .section(let section):
                    if section.place != nav.place { pick(section.place, row: next) }
                case .link(let item, _):
                    marked = []
                    if state.preview && !embedded { showPreview(of: item) }
                }
            }
        }
        return true
    }

    // MARK: folders

    private func ask(parent: UUID?, moving: [WorkItem.ID] = []) {
        folderName = moving.isEmpty ? "" : "New Folder"
        asking = FolderAsk(parent: parent, moving: moving)
    }

    private func createFolder() {
        guard let request = asking else { return }
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        folderName = ""
        guard let made = space.addFolder(name.isEmpty ? "New Folder" : name, in: request.parent) else { return }
        for id in request.moving { space.move(id, to: made.id) }
        marked = []
        if let parent = request.parent { state.open.insert(.folder(parent)) }
        pick(.folder(made.id), row: WorkspaceTree.rowID(.folder(made.id)))
    }

    /// Links or a folder dropped on a folder, or on the Inbox: moved there.
    private func drop(_ drags: [WorkDrag], onto folder: UUID?) -> Bool {
        var moved = false
        defer { if moved { marked = [] } }
        for drag in drags {
            for id in drag.items { space.move(id, to: folder); moved = true }
            if let dragged = drag.folder { space.moveFolder(dragged, to: folder); moved = true }
        }
        return moved
    }
}
