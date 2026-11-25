import AppKit
import SwiftUI

// What the Workspace's page (WorkspacePanel) and its column in the side bar
// (WorkspaceColumn) both do with a link: follow the tabs, open it, change
// it, and the menu a right-click on it brings up.

/// Whether the tab column shows the Workspace instead of the tabs. One
/// switch for every window, kept for the next launch.
@MainActor
final class WorkspaceColumnState: ObservableObject {
    static let shared = WorkspaceColumnState()

    @Published var on: Bool {
        didSet { Store.settings.set(on, forKey: "workspace.column") }
    }
    /// The rows of the tree that are open to their links: a view, or a
    /// folder.
    @Published var open: Set<WorkspacePlace> = []

    init() {
        // Not under the tests: they share the test world's settings with
        // whoever has the app open there, and the column would then stand in
        // for the tabs they look for.
        on = Store.settings.bool(forKey: "workspace.column") && NSClassFromString("XCTestCase") == nil
    }

    func toggle(_ place: WorkspacePlace) {
        if open.contains(place) { open.remove(place) } else { open.insert(place) }
    }
}

/// Where the Workspace is looking: an Inbox, what is to do, what is due, or a
/// folder.
enum WorkspacePlace: Hashable {
    case inbox, todo, due
    case folder(UUID)

    /// A name for the place, for the ids of rows.
    var key: String {
        switch self {
        case .inbox: return "inbox"
        case .todo: return "todo"
        case .due: return "due"
        case .folder(let id): return id.uuidString
        }
    }
}

/// What the Workspace shows and who has the arrow keys, shared by the tree
/// (down the tab column, or down the page's own side) and the links beside
/// it, so that one picks and the other shows.
@MainActor
final class WorkspaceNav: ObservableObject {
    static let shared = WorkspaceNav()

    enum Zone { case sections, links }

    @Published var place: WorkspacePlace = .inbox
    /// Which part the arrow keys are for.
    @Published private(set) var zone: Zone = .sections
    /// Whether the Workspace has the arrow keys at all. It has them from the
    /// moment it is asked for, a click on it or a key, and keeps them when a
    /// page it opened takes the window's keyboard, a text field in it
    /// included: until a click on a page, or on a field, gives them back.
    @Published var keysOwned = false

    /// The arrow keys go to this part, and the Workspace has them.
    func go(_ zone: Zone) {
        self.zone = zone
        keysOwned = true
    }
}

/// One row of the sections: a view, or a folder.
struct WorkspaceSection: Identifiable {
    var place: WorkspacePlace
    var title: String
    var symbol: String
    var depth: Int
    var folder: UUID?

    var id: WorkspacePlace { place }
}

/// One row of the tree: a section, or a link under one.
struct WorkspaceRow: Identifiable {
    enum Kind {
        case section(WorkspaceSection)
        case link(WorkItem, under: WorkspacePlace)
    }
    var id: String
    var depth: Int
    var kind: Kind
}

/// The sections and links as rows, and the walks through them.
enum WorkspaceTree {
    /// The views, then the folders, each followed by the folders in it: those
    /// of a closed folder are left out. `open` nil is every folder open.
    @MainActor
    static func sections(_ space: Workspace, open: Set<UUID>?) -> [WorkspaceSection] {
        var out = [
            WorkspaceSection(place: .inbox, title: "Inbox", symbol: "tray", depth: 0, folder: nil),
            WorkspaceSection(place: .todo, title: "To do", symbol: "checklist", depth: 0, folder: nil),
            WorkspaceSection(place: .due, title: "Due this week", symbol: "calendar", depth: 0, folder: nil),
        ]
        func walk(_ parent: UUID?, depth: Int) {
            for folder in space.children(of: parent) {
                out.append(WorkspaceSection(place: .folder(folder.id), title: folder.name, symbol: "folder",
                                            depth: depth, folder: folder.id))
                if open?.contains(folder.id) ?? true { walk(folder.id, depth: depth + 1) }
            }
        }
        walk(nil, depth: 0)
        return out
    }

    /// The id of the row of a section.
    static func rowID(_ place: WorkspacePlace) -> String { "s/\(place.key)" }

    /// Whether a section has anything to open to: folders in it, or links.
    @MainActor
    static func hasContent(_ place: WorkspacePlace, in space: Workspace) -> Bool {
        switch place {
        case .inbox: return space.count(in: nil) > 0
        case .todo: return !space.todo().isEmpty
        case .due: return !space.due().isEmpty
        case .folder(let id): return !space.children(of: id).isEmpty || space.count(in: id) > 0
        }
    }

    /// The tree as rows: the views, then the folders, each open one followed
    /// by the folders in it and then its links.
    @MainActor
    static func rows(_ space: Workspace, open: Set<WorkspacePlace>) -> [WorkspaceRow] {
        var out: [WorkspaceRow] = []
        func section(_ section: WorkspaceSection) {
            out.append(WorkspaceRow(id: rowID(section.place), depth: section.depth, kind: .section(section)))
        }
        func links(_ list: [WorkItem], under place: WorkspacePlace, depth: Int) {
            for item in list {
                out.append(WorkspaceRow(id: "l/\(place.key)/\(item.id)", depth: depth, kind: .link(item, under: place)))
            }
        }
        let views: [(WorkspacePlace, String, String, [WorkItem])] = [
            (.inbox, "Inbox", "tray", space.items(in: nil)),
            (.todo, "To do", "checklist", space.todo()),
            (.due, "Due this week", "calendar", space.due()),
        ]
        for (place, title, symbol, items) in views {
            section(WorkspaceSection(place: place, title: title, symbol: symbol, depth: 0, folder: nil))
            if open.contains(place) { links(items, under: place, depth: 1) }
        }
        func walk(_ parent: UUID?, depth: Int) {
            for folder in space.children(of: parent) {
                let place = WorkspacePlace.folder(folder.id)
                section(WorkspaceSection(place: place, title: folder.name, symbol: "folder", depth: depth, folder: folder.id))
                if open.contains(place) {
                    walk(folder.id, depth: depth + 1)
                    links(space.items(in: folder.id), under: place, depth: depth + 1)
                }
            }
        }
        walk(nil, depth: 0)
        return out
    }

    enum ColumnKey { case up, down, left, right }

    /// Where an arrow key takes the tree: the row the cursor goes to, and the
    /// section it opens or folds.
    struct TreeMove: Equatable {
        var cursor: String?
        var toggle: WorkspacePlace?
    }

    /// Up and down go row to row, stopping at the ends. Right opens a section
    /// that has something in it, to list its folders and links, and once it
    /// is open goes into it. Left folds an open section, or goes up to the
    /// section that holds this row. `rows` are the rows as drawn.
    @MainActor
    static func treeMove(_ key: ColumnKey, from id: String?, in rows: [WorkspaceRow],
                         open: Set<WorkspacePlace>, space: Workspace) -> TreeMove {
        guard !rows.isEmpty else { return TreeMove() }
        guard let id, let at = rows.firstIndex(where: { $0.id == id }) else { return TreeMove(cursor: rows[0].id) }
        let row = rows[at]
        switch key {
        case .down:
            return TreeMove(cursor: rows[min(at + 1, rows.count - 1)].id)
        case .up:
            return TreeMove(cursor: rows[max(at - 1, 0)].id)
        case .right:
            guard case .section(let section) = row.kind, hasContent(section.place, in: space) else {
                return TreeMove(cursor: id)
            }
            if !open.contains(section.place) { return TreeMove(cursor: id, toggle: section.place) }
            if at + 1 < rows.count, rows[at + 1].depth > row.depth { return TreeMove(cursor: rows[at + 1].id) }
            return TreeMove(cursor: id)
        case .left:
            switch row.kind {
            case .section(let section):
                if open.contains(section.place) { return TreeMove(cursor: id, toggle: section.place) }
                if case .folder(let folder) = section.place, let parent = space.folder(folder)?.parent {
                    return TreeMove(cursor: rowID(.folder(parent)))
                }
                return TreeMove(cursor: id)
            case .link(_, let under):
                return TreeMove(cursor: rowID(under))
            }
        }
    }

    /// Where a step up or down the list of tabs lands: the place `direction`
    /// away from `current`, going round: past the last is the first, and
    /// before the first is the last. From none, a step down is the first and
    /// a step up the last.
    static func stepIndex(of current: Int?, count: Int, direction: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return direction > 0 ? 0 : count - 1 }
        return ((current + direction) % count + count) % count
    }
}

@MainActor
struct WorkspaceTools {
    let browser: Browser
    let space: Workspace

    /// The ordinary pages open in this window: not Search's own pages, not a
    /// private tab.
    var openTabs: [Tab] { browser.tabs.filter { $0.page == nil && !$0.shy && $0.pageAddress != nil } }

    /// Makes the items follow the tabs (Workspace.sync).
    func sync() {
        space.sync(open: openTabs.compactMap { tab in
            tab.pageAddress.map { ($0.absoluteString, tab.title) }
        })
    }

    func tab(for item: WorkItem) -> Tab? {
        openTabs.first { tab in tab.pageAddress.flatMap { Workspace.normalized($0.absoluteString) } == item.url }
    }

    /// Whether the item is the page in front.
    func isFront(_ item: WorkItem) -> Bool {
        guard let front = browser.active, let address = front.pageAddress else { return false }
        return Workspace.normalized(address.absoluteString) == item.url
    }

    /// A page open in a tab goes to that tab; a closed one is opened.
    func open(_ item: WorkItem) {
        if let live = tab(for: item) {
            browser.select(live)
        } else if let url = URL(string: item.url) {
            browser.open(url, foreground: true)
        }
    }

    func change(_ ids: [WorkItem.ID], _ edit: @escaping (inout WorkItem) -> Void) {
        for id in ids { space.update(id, edit) }
    }

    func due(_ ids: [WorkItem.ID], days: Int) {
        let start = Calendar.current.startOfDay(for: Date())
        let date = Calendar.current.date(byAdding: .day, value: days, to: start)
        change(ids) { $0.due = date }
    }
}

/// What a right-click offers for the links `ids`, the one clicked first.
struct WorkItemMenu: View {
    let tools: WorkspaceTools
    let item: WorkItem
    let ids: [WorkItem.ID]
    /// A folder is wanted: where it goes, and the links that go into it.
    var ask: (UUID?, [WorkItem.ID]) -> Void
    /// Links were taken away, so a selection of them is no longer one.
    var removed: () -> Void = {}

    private var space: Workspace { tools.space }

    var body: some View {
        let live = tools.tab(for: item)
        Button(live == nil ? "Open" : "Show Tab") { tools.open(item) }
        if let live, ids.count == 1 {
            Button("Close Tab") { tools.browser.close(live) }
        }
        Divider()
        if ids.count > 1 {
            Button { ask(item.folder, ids) } label: {
                Label("Create Folder from Selection", systemImage: "folder.badge.plus")
            }
            Divider()
        }
        Menu("Status") {
            Button("None") { tools.change(ids) { $0.status = nil } }
            ForEach(WorkStatus.allCases, id: \.self) { status in
                Button(status.title) { tools.change(ids) { $0.status = status } }
            }
        }
        Menu("Priority") {
            Button("None") { tools.change(ids) { $0.priority = 0 } }
            Button("Low") { tools.change(ids) { $0.priority = 1 } }
            Button("Medium") { tools.change(ids) { $0.priority = 2 } }
            Button("High") { tools.change(ids) { $0.priority = 3 } }
        }
        Menu("Due") {
            Button("Today") { tools.due(ids, days: 0) }
            Button("Tomorrow") { tools.due(ids, days: 1) }
            Button("In a week") { tools.due(ids, days: 7) }
            Button("None") { tools.change(ids) { $0.due = nil } }
        }
        Menu("Move to") {
            Button("Inbox") { tools.change(ids) { $0.folder = nil } }
            ForEach(space.flattened()) { folder in
                Button(space.path(of: folder.id)) { tools.change(ids) { $0.folder = folder.id } }
            }
        }
        Button(item.kept ? "Don't Keep When Closed" : "Keep When Closed") {
            tools.change(ids) { $0.kept = !item.kept }
        }
        let closed = ids.compactMap { space.item($0) }.filter { !space.isLive($0) }
        if !closed.isEmpty {
            Divider()
            Button("Remove", role: .destructive) {
                closed.forEach { space.remove($0.id) }
                removed()
            }
        }
    }
}
