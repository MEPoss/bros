import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// Workspace, as a page of its own (search://workspace): the tabs that are
// open, as files in the Inbox, and the folders you put them in. Another view
// of the tab list, not of the bookmarks: a page open in a tab is there
// without being added, and leaves when the tab closes unless it was kept or
// filed (see Workspace.sync). The Inbox is the top of it all: the folders at
// the top, and the pages not yet put in one.
//
// The sections are down its left side, or, with the Workspace in the tab
// column (WorkspaceColumn), there, and the page is then the area of links
// alone. Either way the links are here, to the right, and the arrow keys
// walk them: up, down, left and right between the icons, Return to open,
// and left from the first of a row back to the sections.

/// What is carried when links or a folder are dragged: dropped on a folder
/// of the list, they go in it.
struct WorkDrag: Codable, Transferable {
    var items: [UUID] = []
    var folder: UUID?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

/// How the links are laid out.
enum WorkspaceView: String {
    /// A picture of each page, as it last looked.
    case snapshots
    /// A letter for each site.
    case icons
    case list
}

/// Where each icon is, in the grid's own space, for the rubber band and the
/// arrow keys to be matched against.
private struct TileFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct WorkspacePanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var thumbs: WorkspaceThumbs
    @ObservedObject var nav: WorkspaceNav
    @ObservedObject var column: WorkspaceColumnState
    let space: Workspace

    /// A folder being asked for: where it goes, and the links that go into it.
    private struct FolderAsk {
        var parent: UUID?
        var moving: [WorkItem.ID] = []
    }

    @State private var hunt = ""
    @State private var selection = Set<WorkItem.ID>()
    /// The one a ⇧-click counts from.
    @State private var anchor: WorkItem.ID?
    /// The icon or folder the arrow keys are on.
    @State private var gridCursor: UUID?
    @State private var asking: FolderAsk?
    @State private var folderName = ""
    /// Links Delete asked to take out, until the question is answered.
    @State private var removing: [WorkItem.ID] = []
    /// A folder ⌘⌫ or its menu asked to delete, until the question is answered.
    @State private var removingFolder: UUID?
    /// The place a drag is over, drawn with a ring.
    @State private var targeted: WorkspacePlace?
    @State private var targetedFolder: UUID?
    /// The rubber band being drawn over the icons, and where each icon is.
    @State private var band: CGRect?
    @State private var bandBase = Set<WorkItem.ID>()
    @State private var frames: [UUID: CGRect] = [:]
    /// Which view this is, for the key receiver to know its own answer.
    @State private var token = UUID()
    /// Pictures, icons or a list, kept for the next time.
    @AppStorage("workspaceView", store: Store.settings) private var mode: WorkspaceView = .icons
    /// Titles arrive after the tab does, and a tab's page can move on without
    /// the list of tabs changing.
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    init(browser: Browser, space: Workspace, thumbs: WorkspaceThumbs, nav: WorkspaceNav, column: WorkspaceColumnState) {
        self.browser = browser
        self.space = space
        self.thumbs = thumbs
        self.nav = nav
        self.column = column
    }

    /// Where the Workspace is looking, shared with the sections wherever
    /// they are drawn.
    private var place: WorkspacePlace {
        get { nav.place }
        nonmutating set { nav.place = newValue }
    }

    /// Whether the sections are down this page's own side: not when they are
    /// in the tab column.
    private var showsSidebar: Bool {
        !(column.on && browser.prefs.sidebar && !browser.prefs.iconColumn)
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                WorkspaceColumn(browser: browser, state: column, nav: nav, space: space, embedded: true)
                    .padding(10)
                    .frame(width: 230)
                Rectangle().fill(Palette.hairline).frame(width: 1)
            }
            main
        }
        .background(Palette.ground)
        .onAppear {
            syncTabs()
            thumbs.prune(keeping: Set(space.items.map(\.id)))
            refreshThumbs()
            WorkspaceKeys.shared.register(.links, token: token) { key in handleLinks(key) }
            claimLinks()
        }
        .onDisappear { WorkspaceKeys.shared.unregister(.links, token: token) }
        .onReceive(browser.$tabs) { _ in syncTabs() }
        .onReceive(tick) { _ in
            syncTabs()
            refreshThumbs()
        }
        .onChange(of: mode) { _, _ in refreshThumbs() }
        .onChange(of: nav.place) { _, _ in
            selection = []
            gridCursor = nil
            hunt = ""
        }
        .onChange(of: nav.zone) { _, _ in claimLinks() }
        .alert(asking?.moving.isEmpty == false ? "Folder from selection" : "New folder",
               isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            TextField("Name", text: $folderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { folderName = "" }
        } message: {
            Text(asking?.moving.isEmpty == false ? "The links you picked go into it." : "Choose a name for the folder.")
        }
        .alert(removing.count == 1 ? "Delete this link?" : "Delete \(removing.count) links?",
               isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } })) {
            Button("Delete", role: .destructive) { removeConfirmed() }
            Button("Cancel", role: .cancel) { removing = [] }
        } message: {
            Text(removalNote)
        }
    }

    /// Whether the arrow keys are the links' now.
    private var keyed: Bool { nav.keysOwned && nav.zone == .links }

    /// The keys were sent over to the links: the cursor goes to the first.
    private func claimLinks() {
        guard keyed, gridCursor == nil, let first = (subfolders.map(\.id) + shown.map(\.id)).first else { return }
        gridCursor = first
        if shown.contains(where: { $0.id == first }) { selection = [first] }
    }

    // MARK: the tabs

    private var tools: WorkspaceTools { WorkspaceTools(browser: browser, space: space) }

    private func syncTabs() { tools.sync() }

    private func tab(for item: WorkItem) -> Tab? { tools.tab(for: item) }

    /// While the pictures are on show, the open pages shown are pictured
    /// again now and then, a couple at a time.
    private func refreshThumbs() {
        guard mode == .snapshots else { return }
        var started = 0
        for item in shown.prefix(60) where space.isLive(item) {
            guard started < 2, thumbs.wants(item.id), let live = tab(for: item) else { continue }
            thumbs.capture(live, for: item.id)
            started += 1
        }
    }

    // MARK: folders

    /// The folder on screen, if it is one: where a new folder goes.
    private var here: UUID? {
        if case .folder(let id) = place { return id }
        return nil
    }

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
        if !request.moving.isEmpty { selection = [] }
    }

    private var newFolderButton: some View {
        Button { ask(parent: here) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
    }

    // MARK: dropping and dragging

    /// Links or a folder dropped on a folder: moved there.
    private func drop(_ drags: [WorkDrag], onto folder: UUID?) -> Bool {
        var moved = false
        for drag in drags {
            for id in drag.items { space.move(id, to: folder); moved = true }
            if let dragged = drag.folder { space.moveFolder(dragged, to: folder); moved = true }
        }
        return moved
    }

    private func dragIDs(_ item: WorkItem) -> [WorkItem.ID] {
        selection.contains(item.id) ? Array(selection) : [item.id]
    }

    // MARK: list

    private var shown: [WorkItem] {
        if !hunt.isEmpty { return space.search(hunt) }
        switch place {
        case .inbox: return space.items(in: nil)
        case .todo: return space.todo()
        case .due: return space.due()
        case .folder(let id): return space.items(in: id)
        }
    }

    /// The folders at the level on screen, shown beside its links: at the
    /// top, in the Inbox, as the Desktop shows its folders.
    private var subfolders: [WorkFolder] {
        guard hunt.isEmpty else { return space.searchFolders(hunt) }
        switch place {
        case .inbox: return space.children(of: nil)
        case .folder(let id): return space.children(of: id)
        case .todo, .due: return []
        }
    }

    private var heading: String {
        if !hunt.isEmpty { return "Search" }
        switch place {
        case .inbox: return "Inbox"
        case .todo: return "To do"
        case .due: return "Due this week"
        case .folder(let id): return space.path(of: id)
        }
    }

    private var main: some View {
        let items = shown
        let folders = subfolders
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(heading).font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                    .alert("Delete folder \u{201C}\(removingFolder.flatMap { space.folder($0)?.name } ?? "")\u{201D}?",
                           isPresented: Binding(get: { removingFolder != nil }, set: { if !$0 { removingFolder = nil } })) {
                        Button("Delete", role: .destructive) { removeFolderConfirmed() }
                        Button("Cancel", role: .cancel) { removingFolder = nil }
                    } message: {
                        Text("Its links go to the Inbox and its folders move up a level. No link is deleted.")
                    }
                Spacer()
                Picker("View", selection: $mode) {
                    Image(systemName: "photo.on.rectangle").tag(WorkspaceView.snapshots)
                    Image(systemName: "square.grid.2x2").tag(WorkspaceView.icons)
                    Image(systemName: "list.bullet").tag(WorkspaceView.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 104)
                .help("Pictures, icons or list")
                TextField("Search links", text: $hunt)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if items.isEmpty && folders.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    Text(hunt.isEmpty ? emptyText : "Nothing matches.")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .contextMenu { if hunt.isEmpty && canHoldFolders { newFolderButton } }
            } else if mode == .list {
                list(items, folders: folders)
            } else {
                grid(items, folders: folders, pictures: mode == .snapshots)
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            footer(items, folders: folders)
        }
    }

    /// Whether a folder can be made where the page is: not in a view that
    /// only collects.
    private var canHoldFolders: Bool {
        switch place {
        case .inbox, .folder: return true
        case .todo, .due: return false
        }
    }

    private func footer(_ items: [WorkItem], folders: [WorkFolder]) -> some View {
        let open = items.filter { space.isLive($0) }.count
        var parts: [String] = []
        if !folders.isEmpty { parts.append(folders.count == 1 ? "1 folder" : "\(folders.count) folders") }
        parts.append(items.count == 1 ? "1 link" : "\(items.count) links")
        if open > 0 { parts.append("\(open) open") }
        if selection.count > 1 { parts.append("\(selection.count) selected") }
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
            .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private var emptyText: String {
        switch place {
        case .inbox: return "Nothing open. Pages you open show up here. Right-click for a new folder."
        case .todo: return "Nothing to do."
        case .due: return "Nothing due this week."
        case .folder: return "This folder is empty. Drag links here, or right-click for a new folder."
        }
    }

    // MARK: the list

    private func list(_ items: [WorkItem], folders: [WorkFolder]) -> some View {
        List(selection: $selection) {
            ForEach(folders) { folder in
                folderLine(folder)
                    .listRowSeparator(.visible)
            }
            ForEach(items) { item in
                line(item)
                    .tag(item.id)
                    .draggable(WorkDrag(items: dragIDs(item)))
                    .listRowSeparator(.visible)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: WorkItem.ID.self) { ids in
            if let first = ids.first.flatMap({ space.item($0) }) {
                menu(first, ids: Array(ids))
            } else if hunt.isEmpty && canHoldFolders {
                newFolderButton
            }
        } primaryAction: { ids in
            if let first = ids.first.flatMap({ space.item($0) }) { open(first) }
        }
    }

    private func folderLine(_ folder: WorkFolder) -> some View {
        HStack(spacing: 10) {
            Image(systemName: folder.glyph).foregroundStyle(Palette.muted).frame(width: 16)
            Text(folder.name).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
            Spacer()
            let count = space.count(in: folder.id)
            if count > 0 { Text("\(count)").font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }
        .padding(.vertical, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(targetedFolder == folder.id ? 1 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { place = .folder(folder.id); selection = [] }
        .draggable(WorkDrag(folder: folder.id))
        .contextMenu {
                                    FolderIconMenu(space: space, folder: folder)
                                    Divider()
                                    Button("Delete Folder…", role: .destructive) { removingFolder = folder.id }
                                }
        .dropDestination(for: WorkDrag.self) { drags, _ in
            drop(drags, onto: folder.id)
        } isTargeted: { on in
            if on { targetedFolder = folder.id } else if targetedFolder == folder.id { targetedFolder = nil }
        }
    }

    private func line(_ item: WorkItem) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(space.isLive(item) ? Palette.safe : Palette.faint)
                .frame(width: 7, height: 7)
                .help(space.isLive(item) ? "Open in a tab" : "Closed")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.system(size: 13)).foregroundStyle(Palette.ink).lineLimit(1)
                Text(detail(item)).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let status = item.status {
                Text(status.title)
                    .font(.system(size: 11))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Palette.wash)
                    .clipShape(Capsule())
                    .foregroundStyle(status == .done ? Palette.muted : Palette.ink)
            }
            if item.priority > 0 {
                Text(String(repeating: "!", count: item.priority))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.unsafe)
                    .frame(width: 24, alignment: .trailing)
            }
            if let due = item.due {
                Text(due.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.system(size: 12))
                    .foregroundStyle(item.isOpen && due < Calendar.current.startOfDay(for: Date()) ? Palette.unsafe : Palette.muted)
                    .frame(width: 54, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
        .opacity(space.isLive(item) ? 1 : 0.6)
        .contentShape(Rectangle())
    }

    private func detail(_ item: WorkItem) -> String {
        var parts = [item.host ?? item.url]
        if place == .todo || place == .due || !hunt.isEmpty { parts.append(space.path(of: item.folder)) }
        if !item.tags.isEmpty { parts.append(item.tags.map { "#" + $0 }.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    // MARK: the grid, of icons or of pictures

    private func grid(_ items: [WorkItem], folders: [WorkFolder], pictures: Bool) -> some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: pictures ? 172 : 104), spacing: 6, alignment: .top)],
                              spacing: 6) {
                        ForEach(folders) { folder in
                            tile(symbol: folder.tileGlyph, letter: nil, picture: nil, wide: pictures, status: nil,
                                 label: folder.name, picked: targetedFolder == folder.id,
                                 cursor: keyed && gridCursor == folder.id, live: true)
                                .background(frameReader(folder.id))
                                .id(folder.id)
                                .onTapGesture(count: 2) { place = .folder(folder.id); selection = [] }
                                .onTapGesture { gridCursor = folder.id; selection = []; nav.go(.links) }
                                .draggable(WorkDrag(folder: folder.id))
                                .contextMenu {
                                    FolderIconMenu(space: space, folder: folder)
                                    Divider()
                                    Button("Delete Folder…", role: .destructive) { removingFolder = folder.id }
                                }
                                .dropDestination(for: WorkDrag.self) { drags, _ in
                                    drop(drags, onto: folder.id)
                                } isTargeted: { on in
                                    if on { targetedFolder = folder.id } else if targetedFolder == folder.id { targetedFolder = nil }
                                }
                        }
                        ForEach(items) { item in
                            tile(symbol: nil, letter: initial(item), picture: pictures ? thumbs.image(for: item.id) : nil,
                                 wide: pictures, status: item.status, label: item.label,
                                 picked: selection.contains(item.id), cursor: keyed && gridCursor == item.id,
                                 live: space.isLive(item))
                                .background(frameReader(item.id))
                                .id(item.id)
                                .onTapGesture(count: 2) { open(item) }
                                .onTapGesture { click(item, among: items) }
                                .draggable(WorkDrag(items: dragIDs(item)))
                                .contextMenu {
                                    // A right-click on a tile outside the selection is
                                    // on that tile alone, as in the Finder.
                                    menu(item, ids: selection.contains(item.id) ? Array(selection) : [item.id])
                                }
                                .help(item.url)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    .background(
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { selection = []; gridCursor = nil }
                            .gesture(rubberBand)
                            .contextMenu { if hunt.isEmpty && canHoldFolders { newFolderButton } }
                    )
                    .overlay(alignment: .topLeading) {
                        if let band {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.14))
                                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                                .frame(width: band.width, height: band.height)
                                .offset(x: band.minX, y: band.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(name: "grid")
                }
                .onChange(of: gridCursor) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .onPreferenceChange(TileFrames.self) { frames = $0 }
    }

    private func frameReader(_ id: UUID) -> some View {
        GeometryReader { box in
            Color.clear.preference(key: TileFrames.self, value: [id: box.frame(in: .named("grid"))])
        }
    }

    /// A drag that starts on empty ground picks what its rectangle touches;
    /// with ⌘ held it adds to what was picked.
    private var rubberBand: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("grid"))
            .onChanged { drag in
                if band == nil {
                    bandBase = NSEvent.modifierFlags.contains(.command) ? selection : []
                }
                let rect = CGRect(x: min(drag.startLocation.x, drag.location.x),
                                  y: min(drag.startLocation.y, drag.location.y),
                                  width: abs(drag.location.x - drag.startLocation.x),
                                  height: abs(drag.location.y - drag.startLocation.y))
                band = rect
                let links = Set(shown.map(\.id))
                selection = bandBase.union(frames.filter { links.contains($0.key) && $0.value.intersects(rect) }.map(\.key))
            }
            .onEnded { _ in band = nil }
    }

    /// The arrows among the icons: left and right to the one beside, up and
    /// down to the nearest one in the row above or below, Return to open it
    /// or go into the folder, and left from the first of a row back to the
    /// sections. In a list there is no row beside: up and down go line to
    /// line, and left goes back. Gives back whether the key was taken.
    private func handleLinks(_ key: WorkspaceKeys.Key) -> Bool {
        let items = shown
        let folders = subfolders
        let ids = folders.map(\.id) + items.map(\.id)
        guard !ids.isEmpty else {
            guard key == .left else { return false }
            nav.go(.sections)
            return true
        }
        func pick(_ id: UUID) {
            gridCursor = id
            selection = items.contains { $0.id == id } ? [id] : []
            anchor = id
        }
        let at = gridCursor.flatMap { ids.firstIndex(of: $0) }
        let list = mode == .list
        switch key {
        case .right:
            if !list { pick(ids[at.map { min($0 + 1, ids.count - 1) } ?? 0]) }
        case .left:
            guard let at, !list, beside(ids[at], in: ids, to: .leading) else { nav.go(.sections); break }
            pick(ids[max(at - 1, 0)])
        case .down:
            guard let at else { pick(ids[0]); break }
            if list { pick(ids[min(at + 1, ids.count - 1)]) } else if let next = nearest(from: ids[at], in: ids, down: true) { pick(next) }
        case .up:
            guard let at else { pick(ids[0]); break }
            if list { pick(ids[max(at - 1, 0)]) } else if let next = nearest(from: ids[at], in: ids, down: false) { pick(next) }
        case .delete:
            if selection.isEmpty, let id = gridCursor, folders.contains(where: { $0.id == id }) {
                removingFolder = id
                return true
            }
            return askToRemove()
        case .enter:
            guard let id = gridCursor else { return false }
            if let item = items.first(where: { $0.id == id }) {
                open(item)
            } else if folders.contains(where: { $0.id == id }) {
                place = .folder(id)
            }
        }
        return true
    }

    /// Whether another icon is beside this one, on its left, in the same row.
    private func beside(_ id: UUID, in ids: [UUID], to side: HorizontalEdge) -> Bool {
        guard let mine = frames[id] else { return false }
        return ids.contains { other in
            guard other != id, let frame = frames[other], abs(frame.midY - mine.midY) < 8 else { return false }
            return side == .leading ? frame.midX < mine.midX : frame.midX > mine.midX
        }
    }

    /// The icon in the nearest row below or above, the one closest across.
    private func nearest(from id: UUID, in ids: [UUID], down: Bool) -> UUID? {
        guard let mine = frames[id] else { return nil }
        let others = ids.compactMap { other in frames[other].map { (other, $0) } }
            .filter { down ? $0.1.midY > mine.midY + 8 : $0.1.midY < mine.midY - 8 }
        guard let row = down ? others.map({ $0.1.midY }).min() : others.map({ $0.1.midY }).max() else { return nil }
        return others.filter { abs($0.1.midY - row) < 8 }
            .min { abs($0.1.midX - mine.midX) < abs($1.1.midX - mine.midX) }?.0
    }

    /// A click as the Finder takes it: one picks, ⌘ adds or takes away, ⇧
    /// picks everything from the last one to this one.
    private func click(_ item: WorkItem, among items: [WorkItem]) {
        let flags = NSEvent.modifierFlags
        nav.go(.links)
        gridCursor = item.id
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else if flags.contains(.shift), let anchor,
                  let from = items.firstIndex(where: { $0.id == anchor }),
                  let to = items.firstIndex(where: { $0.id == item.id }) {
            selection = Set(items[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [item.id]
            anchor = item.id
        }
    }

    private func initial(_ item: WorkItem) -> String {
        let name = (item.host ?? item.label).replacingOccurrences(of: "www.", with: "")
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    /// One link or folder in the grid: a square with a letter, or a wide
    /// frame with the page's picture in it.
    private func tile(symbol: String?, letter: String?, picture: NSImage?, wide: Bool, status: WorkStatus?,
                      label: String, picked: Bool, cursor: Bool, live: Bool) -> some View {
        let width: CGFloat = wide ? 150 : 56
        let height: CGFloat = wide ? 94 : 56
        let corner: CGFloat = wide ? 8 : 12
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Palette.wash)
                    .frame(width: width, height: height)
                    .overlay {
                        if let picture {
                            // The top of the page, filling the frame.
                            Image(nsImage: picture)
                                .resizable()
                                .scaledToFill()
                                .frame(width: width, height: height, alignment: .top)
                                .clipped()
                        } else if let symbol {
                            Image(systemName: symbol).font(.system(size: wide ? 34 : 26)).foregroundStyle(Palette.muted)
                        } else if let letter {
                            Text(letter).font(.system(size: wide ? 30 : 22, weight: .medium)).foregroundStyle(Palette.muted)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                if let status {
                    Circle()
                        .fill(status == .done ? Palette.safe : status == .doing ? Color.accentColor : Palette.unsafe)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Palette.ground, lineWidth: 2))
                        .offset(x: 3, y: -3)
                        .help(status.title)
                }
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: wide ? 160 : 96)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .opacity(live ? 1 : 0.55)
        .background(picked || cursor ? Color.accentColor.opacity(0.28) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(picked || cursor ? Color.accentColor : Color.clear, lineWidth: cursor ? 2.5 : 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: actions

    /// What a right-click offers for the links `ids`, the one clicked first.
    private func menu(_ item: WorkItem, ids: [WorkItem.ID]) -> some View {
        WorkItemMenu(tools: tools, item: item, ids: ids, ask: { ask(parent: $0, moving: $1) }, removed: { selection = [] })
    }

    private func open(_ item: WorkItem) { tools.open(item) }

    /// ⌫ asks whether to take the links picked out of the Workspace.
    @discardableResult
    private func askToRemove() -> Bool {
        let picked = selection.filter { space.item($0) != nil }
        guard !picked.isEmpty else { return false }
        removing = Array(picked)
        return true
    }

    /// What the question says goes with the links: a page open in a tab is
    /// closed too, since the Workspace only shows what is open or kept.
    private var removalNote: String {
        let open = removing.compactMap { space.item($0) }.filter { space.isLive($0) }.count
        if open == 0 { return "They are taken out of the Workspace." }
        return "They are taken out of the Workspace, and \(open == 1 ? "the page open in a tab is" : "the \(open) pages open in tabs are") closed."
    }

    private func removeFolderConfirmed() {
        guard let id = removingFolder else { return }
        removingFolder = nil
        if place == .folder(id) { place = .inbox }
        gridCursor = nil
        space.removeFolder(id)
    }

    private func removeConfirmed() {
        for id in removing {
            guard let item = space.item(id) else { continue }
            if let open = tab(for: item) { browser.close(open) }
            space.remove(id)
        }
        removing = []
        selection = []
        gridCursor = nil
    }
}
