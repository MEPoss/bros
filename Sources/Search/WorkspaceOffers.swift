import Foundation

// Workspace in the rest of the browser: ⌘K finds the links kept there as it
// finds the pages open, and a key keeps the page in front in the Inbox.

extension Browser {
    /// The Workspace of this window's profile: each profile has its own.
    var workspace: Workspace { Workspace.of(profileID) }

    /// What ⌘K adds under the open pages: links kept in the Workspace that
    /// the words match, not the ones already offered as an open page.
    func keptPages(matching typed: String, besides open: [Suggestion]) -> [Suggestion] {
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let taken = Set(open.map { History.identity(for: $0.url) })
        let space = workspace
        var found: [Suggestion] = []
        for item in space.search(typed) where item.isWorthKeeping {
            guard found.count < 4, let url = URL(string: item.url),
                  !taken.contains(History.identity(for: url)) else { continue }
            found.append(Suggestion(key: item.label, title: space.path(of: item.folder), url: url, kind: .kept))
        }
        return found
    }

    /// The page in front, kept so that it stays in the Workspace when its tab
    /// closes. Said either way: a key that stays silent reads as a key that
    /// did nothing.
    func keepInWorkspace() {
        guard let tab = active, tab.isWeb, let address = tab.pageAddress?.absoluteString else {
            announce("Nothing to keep here")
            return
        }
        let space = workspace
        if let held = space.item(for: address), held.kept {
            announce("Already kept in \(space.path(of: held.folder))")
        } else if let held = space.keep(url: address, title: tab.title) {
            announce("Kept in \(space.path(of: held.folder))")
        }
    }

    /// The Workspace's page, where its links are shown.
    func showWorkspacePage() {
        show(InternalPage(.workspace))
    }

    /// The Workspace in the tab column in place of the tabs, with its page,
    /// the area of links, beside it; or the tabs back. Where the tabs are
    /// not down the side, or the column is only icons, there is no column to
    /// put it in: the page of the same name, with its own sections.
    func toggleWorkspace() {
        let column = WorkspaceColumnState.shared
        guard prefs.sidebar, !prefs.iconColumn else {
            lead(to: InternalPage(.workspace))
            WorkspaceNav.shared.go(.sections)
            return
        }
        column.on.toggle()
        if column.on {
            showWorkspacePage()
            WorkspaceNav.shared.go(.sections)
        }
    }

    /// The tabs open, in the order the Workspace lists them: the Inbox's
    /// first, then each folder's, each tab once. A page open in two tabs
    /// stands for both, one after the other, so that none is out of reach.
    func workspaceTabs() -> [Tab] {
        let space = workspace
        let tools = WorkspaceTools(browser: self, space: space)
        let open = tools.openTabs
        var seen = Set<Tab.ID>()
        var out: [Tab] = []
        func add(_ items: [WorkItem]) {
            for item in items {
                for tab in open where tab.pageAddress.flatMap({ Workspace.normalized($0.absoluteString) }) == item.url {
                    if seen.insert(tab.id).inserted { out.append(tab) }
                }
            }
        }
        add(space.items(in: nil))
        for folder in space.flattened() { add(space.items(in: folder.id)) }
        return out
    }

    /// ⌥⌘↓ and ⌥⌘↑: the page under the one on screen, or over it, in the
    /// list on the left: the tab column's, or, with the Workspace in its
    /// place, the Workspace's. It only ever goes to a tab that is open: it
    /// opens nothing, and past the last it goes round to the first.
    func stepColumn(_ direction: Int) {
        guard WorkspaceColumnState.shared.on, prefs.sidebar, !prefs.iconColumn else {
            stepInColumn(direction)
            return
        }
        let list = workspaceTabs()
        let here = list.firstIndex { $0.id == active?.id }
        guard let next = WorkspaceTree.stepIndex(of: here, count: list.count, direction: direction) else { return }
        select(list[next])
    }

    /// ⌥⌘→ and ⌥⌘←: the next section of the Workspace, or the one before,
    /// round the ends, its links shown in the area to the right.
    func stepSection(_ direction: Int) {
        let nav = WorkspaceNav.shared
        let list = WorkspaceTree.sections(workspace, open: nil)
        guard !list.isEmpty else { return }
        let at = list.firstIndex { $0.place == nav.place } ?? (direction > 0 ? -1 : 0)
        nav.place = list[((at + direction) % list.count + list.count) % list.count].place
        showWorkspacePage()
    }

    /// Whether the page in front was kept on purpose, for the menu to say so.
    var pageKeptInWorkspace: Bool {
        active?.pageAddress.flatMap { workspace.item(for: $0.absoluteString)?.kept } ?? false
    }
}
