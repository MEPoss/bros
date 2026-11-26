import Foundation
import Observation

// Workspace: links kept like files. Every link, open in a tab or saved for
// later, is an item that lives in a folder (or in the Inbox, when it has
// none) and can carry a status, a priority, a due date, tags and a note.
//
// This is a layer beside Bookmarks and Pins, not a replacement for them: it
// holds only what those don't, and is kept in a file of its own so that
// nothing here can disturb them. An item with no status is a reference, to
// be found again; one with a status is something still to do.
//
// It is first of all another view of the tabs that are open: every ordinary
// open page is an item in the Inbox (see `sync`), like a file that is open.
// Closing the tab closes the file. What was only open and never touched goes
// with it; what was kept, put in a folder or given a status, a priority, a
// date, a tag or a note stays, as a closed file.

enum WorkStatus: String, Codable, CaseIterable {
    case todo, doing, done

    var title: String {
        switch self {
        case .todo: return "To do"
        case .doing: return "Doing"
        case .done: return "Done"
        }
    }
}

struct WorkFolder: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// The folder that holds this one; nil at the top.
    var parent: UUID?
    /// The name of the SF Symbol picked for it (`WorkFolder.icons`); nil is
    /// the plain folder.
    var symbol: String?

    init(id: UUID = UUID(), name: String, parent: UUID? = nil, symbol: String? = nil) {
        self.id = id
        self.name = name
        self.parent = parent
        self.symbol = symbol
    }

    /// What it is drawn with: the one picked, or a folder.
    var glyph: String { symbol.flatMap { Self.icon(named: $0) } ?? "folder" }
    /// The same for a big tile, where the plain folder is the filled one.
    var tileGlyph: String { symbol.flatMap { Self.icon(named: $0) } ?? "folder.fill" }

    /// The icons to choose from: the symbol's name and what the menu calls it.
    static let icons: [(symbol: String, name: String)] = [
        ("briefcase", "Work"), ("house", "Home"), ("star", "Favourites"), ("heart", "Heart"),
        ("book", "Reading"), ("graduationcap", "Study"), ("lightbulb", "Ideas"), ("flag", "Flag"),
        ("bookmark", "Saved"), ("tag", "Tag"), ("pin", "Pinned"), ("bolt", "Quick"),
        ("cart", "Shopping"), ("creditcard", "Money"), ("airplane", "Travel"), ("map", "Places"),
        ("camera", "Photos"), ("film", "Video"), ("music.note", "Music"), ("gamecontroller", "Games"),
        ("paintbrush", "Design"), ("hammer", "Build"), ("chevron.left.forwardslash.chevron.right", "Code"),
        ("chart.bar", "Data"), ("envelope", "Mail"), ("person.2", "People"), ("globe", "Web"),
        ("leaf", "Nature"), ("cup.and.saucer", "Break"), ("archivebox", "Archive"),
    ]

    /// A stored name only if it is one of the icons: a file edited by hand
    /// cannot put anything else on screen.
    static func icon(named name: String) -> String? {
        icons.contains { $0.symbol == name } ? name : nil
    }
}

struct WorkItem: Codable, Identifiable, Equatable {
    var id: UUID
    /// As `Workspace.normalized` leaves it: the same page is one item.
    var url: String
    var title: String
    /// The folder that holds it; nil is the Inbox.
    var folder: UUID?
    /// Nil for a reference: a link kept, with nothing to do about it.
    var status: WorkStatus?
    /// 0 for none, up to 3 for the most urgent.
    var priority: Int
    var due: Date?
    var tags: [String]
    var notes: String
    var added: Date
    /// Kept on purpose, so it stays when its tab closes. An item that came
    /// only from a tab being open is not.
    var kept: Bool

    init(id: UUID = UUID(), url: String, title: String, folder: UUID? = nil, status: WorkStatus? = nil,
         priority: Int = 0, due: Date? = nil, tags: [String] = [], notes: String = "", added: Date = Date(),
         kept: Bool = true) {
        self.id = id
        self.url = url
        self.title = title
        self.folder = folder
        self.status = status
        self.priority = max(0, min(3, priority))
        self.due = due
        self.tags = tags
        self.notes = notes
        self.added = added
        self.kept = kept
    }

    /// Whether anything has been done with it beyond opening it.
    var isFiled: Bool {
        folder != nil || status != nil || priority > 0 || due != nil || !tags.isEmpty
            || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether it outlives its tab.
    var isWorthKeeping: Bool { kept || isFiled }

    /// Whether it is still to be done.
    var isOpen: Bool { status == .todo || status == .doing }

    /// What a list reads it as: its name, or its address when it has none.
    var label: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? url : title }

    var host: String? { URL(string: url)?.host()?.lowercased() }
}

extension WorkItem {
    private enum Keys: String, CodingKey { case id, url, title, folder, status, priority, due, tags, notes, added, kept }

    /// Leniently, as the other files are read: a field this version doesn't
    /// know is left out, and one that doesn't read is its default, so a file
    /// written by a later version is never thrown away for one new field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? ""
        folder = try? c.decodeIfPresent(UUID.self, forKey: .folder)
        status = try? c.decodeIfPresent(WorkStatus.self, forKey: .status)
        priority = max(0, min(3, (try? c.decodeIfPresent(Int.self, forKey: .priority)) ?? 0))
        due = try? c.decodeIfPresent(Date.self, forKey: .due)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        added = (try? c.decodeIfPresent(Date.self, forKey: .added)) ?? Date()
        // One written before there was a flag was put there by hand.
        kept = (try? c.decodeIfPresent(Bool.self, forKey: .kept)) ?? true
    }
}

extension WorkFolder {
    private enum Keys: String, CodingKey { case id, name, parent, symbol }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parent = try? c.decodeIfPresent(UUID.self, forKey: .parent)
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)).flatMap { $0 }
    }
}

/// What is written to disk.
struct WorkspaceFile: Codable, Equatable {
    var folders: [WorkFolder] = []
    var items: [WorkItem] = []
}

@MainActor @Observable
final class Workspace {
    private(set) var folders: [WorkFolder] = []
    private(set) var items: [WorkItem] = []

    /// The pages open in a tab now, as `sync` last saw them. Not kept on disk:
    /// no tab survives a launch.
    private(set) var live: Set<String> = []

    /// Where it is kept; nil keeps nothing, for a test.
    private let file: URL?

    /// Personal's list, which is the one every window had before profiles
    /// had lists of their own (and what a test uses).
    static let shared = Workspace.of(Profile.personalID)

    private static var made: [UUID: Workspace] = [:]

    /// Each profile keeps its own Workspace, in its own file: Personal's in
    /// workspace.json as ever, the others in workspace-<id>.json.
    static func fileName(of profile: UUID) -> String {
        profile == Profile.personalID ? "workspace.json" : "workspace-\(profile.uuidString).json"
    }

    static func of(_ profile: UUID) -> Workspace {
        if let held = made[profile] { return held }
        let space = Workspace(file: fileName(of: profile))
        made[profile] = space
        return space
    }

    /// A profile deleted: its Workspace and its file go with it.
    static func forget(profile: UUID) {
        made.removeValue(forKey: profile)?.retired = true
        Disk.remove(Store.file(fileName(of: profile)))
    }

    private var retired = false

    init(file name: String? = "workspace.json") {
        file = name.map { Store.file($0) }
        load()
    }

    // MARK: - Items

    /// The address as one item knows it: without the tracking parameters
    /// and the fragment a link carries on the way, so the same page kept
    /// twice is one item. Nil for anything that isn't a web page.
    nonisolated static func normalized(_ text: String) -> String? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.host?.isEmpty == false
        else { return nil }
        parts.scheme = scheme
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        if let query = parts.queryItems {
            let kept = query.filter { item in
                let name = item.name.lowercased()
                return !(name.hasPrefix("utm_") || ["fbclid", "gclid", "mc_cid", "mc_eid", "igshid"].contains(name))
            }
            parts.queryItems = kept.isEmpty ? nil : kept
        }
        if parts.path == "/" && parts.query == nil { parts.path = "" }
        return parts.string
    }

    func item(_ id: UUID) -> WorkItem? { items.first { $0.id == id } }

    /// Whether the item's page is open in a tab.
    func isLive(_ item: WorkItem) -> Bool { live.contains(item.url) }

    /// Makes the items follow the tabs: a page open and not yet an item
    /// becomes one in the Inbox, a title that has changed is taken, and an
    /// item whose tab is gone leaves with it unless it was kept or filed.
    /// `pages` is every ordinary open page; what isn't a web page is left
    /// out. Returns whether anything changed.
    @discardableResult
    func sync(open pages: [(url: String, title: String)], now: Date = Date()) -> Bool {
        var changed = false
        var seen = Set<String>()
        for page in pages {
            guard let key = Workspace.normalized(page.url) else { continue }
            seen.insert(key)
            if let at = items.firstIndex(where: { $0.url == key }) {
                if !page.title.isEmpty, items[at].title != page.title {
                    items[at].title = page.title
                    changed = true
                }
            } else {
                items.append(WorkItem(url: key, title: page.title, added: now, kept: false))
                changed = true
            }
        }
        let before = items.count
        items.removeAll { !seen.contains($0.url) && !$0.isWorthKeeping }
        if items.count != before { changed = true }
        if live != seen { live = seen }
        if changed { save() }
        return changed
    }

    /// Keeps a page on purpose, so it stays when its tab closes.
    @discardableResult
    func keep(url: String, title: String) -> WorkItem? {
        guard let key = Workspace.normalized(url) else { return nil }
        if let at = items.firstIndex(where: { $0.url == key }) {
            if !items[at].kept { items[at].kept = true; save() }
            return items[at]
        }
        return add(url: url, title: title)
    }

    /// The item for this page, if it is kept.
    func item(for url: String) -> WorkItem? {
        guard let key = Workspace.normalized(url) else { return nil }
        return items.first { $0.url == key }
    }

    /// Keeps a page. A page already kept is not kept twice: the one there
    /// is returned, and moved only if a folder is named. Nil when the
    /// address isn't a web page.
    @discardableResult
    func add(url: String, title: String, folder: UUID? = nil, status: WorkStatus? = nil, now: Date = Date()) -> WorkItem? {
        guard let key = Workspace.normalized(url) else { return nil }
        if let at = items.firstIndex(where: { $0.url == key }) {
            if let folder, self.folder(folder) != nil { items[at].folder = folder; save() }
            return items[at]
        }
        let made = WorkItem(url: key, title: title, folder: folder.flatMap { self.folder($0) == nil ? nil : $0 },
                            status: status, added: now)
        items.append(made)
        save()
        return made
    }

    /// Changes one item in place; a priority is kept within 0...3.
    func update(_ id: UUID, _ change: (inout WorkItem) -> Void) {
        guard let at = items.firstIndex(where: { $0.id == id }) else { return }
        var edited = items[at]
        change(&edited)
        edited.priority = max(0, min(3, edited.priority))
        if let folder = edited.folder, self.folder(folder) == nil { edited.folder = nil }
        edited.tags = Workspace.cleaned(edited.tags)
        guard edited != items[at] else { return }
        items[at] = edited
        save()
    }

    func move(_ id: UUID, to folder: UUID?) {
        update(id) { $0.folder = folder }
    }

    func remove(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        save()
    }

    /// Tags as typed: trimmed, lowercased, without a leading #, once each.
    nonisolated static func cleaned(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { raw in
            var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while tag.hasPrefix("#") { tag.removeFirst() }
            return tag.isEmpty || !seen.insert(tag).inserted ? nil : tag
        }
    }

    // MARK: - Folders

    func folder(_ id: UUID) -> WorkFolder? { folders.first { $0.id == id } }

    func children(of parent: UUID?) -> [WorkFolder] {
        folders.filter { $0.parent == parent }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every folder under `parent`, each followed by what is in it, in the
    /// order a tree is read.
    func flattened(from parent: UUID? = nil) -> [WorkFolder] {
        children(of: parent).flatMap { [$0] + flattened(from: $0.id) }
    }

    @discardableResult
    func addFolder(_ name: String, in parent: UUID? = nil) -> WorkFolder? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let parent = parent.flatMap { folder($0) == nil ? nil : $0 }
        let made = WorkFolder(name: name, parent: parent)
        folders.append(made)
        save()
        return made
    }

    /// Gives a folder an icon from `WorkFolder.icons`; nil, or any other
    /// name, is the plain folder.
    func setIcon(_ id: UUID, to symbol: String?) {
        let symbol = symbol.flatMap { WorkFolder.icon(named: $0) }
        guard let at = folders.firstIndex(where: { $0.id == id }), folders[at].symbol != symbol else { return }
        folders[at].symbol = symbol
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let at = folders.firstIndex(where: { $0.id == id }), folders[at].name != name else { return }
        folders[at].name = name
        save()
    }

    /// A folder and what is in it go: its subfolders to the one above, its
    /// items to the Inbox, so deleting a folder never deletes a link.
    func removeFolder(_ id: UUID) {
        guard let gone = folder(id) else { return }
        for at in folders.indices where folders[at].parent == id { folders[at].parent = gone.parent }
        for at in items.indices where items[at].folder == id { items[at].folder = nil }
        folders.removeAll { $0.id == id }
        save()
    }

    /// Whether `folder` is `ancestor` or lies inside it; a folder is never
    /// put inside itself.
    func lies(_ folder: UUID?, within ancestor: UUID) -> Bool {
        var at = folder
        var steps = 0
        while let id = at, steps <= folders.count {
            if id == ancestor { return true }
            at = self.folder(id)?.parent
            steps += 1
        }
        return false
    }

    func moveFolder(_ id: UUID, to parent: UUID?) {
        guard let at = folders.firstIndex(where: { $0.id == id }), folders[at].parent != parent else { return }
        if let parent, lies(parent, within: id) { return }
        if let parent, folder(parent) == nil { return }
        folders[at].parent = parent
        save()
    }

    /// "Work / Alpha", for a list that shows where something is.
    func path(of folder: UUID?) -> String {
        var names: [String] = []
        var at = folder
        var steps = 0
        while let id = at, let found = self.folder(id), steps <= folders.count {
            names.insert(found.name, at: 0)
            at = found.parent
            steps += 1
        }
        return names.isEmpty ? "Inbox" : names.joined(separator: " / ")
    }

    // MARK: - Views

    /// What is in one folder, or in the Inbox for nil, newest first.
    func items(in folder: UUID?) -> [WorkItem] {
        items.filter { $0.folder == folder }.sorted { $0.added > $1.added }
    }

    /// What is still to do, anywhere: the most urgent first, then the
    /// soonest due, the ones with no date after those that have one.
    func todo() -> [WorkItem] {
        items.filter(\.isOpen).sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.added > b.added
            }
        }
    }

    /// What is due within `days` days of `now`, or already late, and not
    /// done, the soonest first.
    func due(within days: Int = 7, now: Date = Date()) -> [WorkItem] {
        let limit = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        return items.filter { $0.status != .done && ($0.due.map { $0 <= limit } ?? false) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// Items whose name, address, tags or note hold every word typed.
    func search(_ text: String) -> [WorkItem] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return items.filter { item in
            let hay = ([item.title, item.url, item.notes] + item.tags).joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    /// Folders whose path holds every word typed, the ones nearest the top
    /// first.
    func searchFolders(_ text: String) -> [WorkFolder] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return flattened().filter { folder in
            let hay = path(of: folder.id).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    func tags() -> [String] {
        Array(Set(items.flatMap(\.tags))).sorted()
    }

    func count(in folder: UUID?) -> Int { items.lazy.filter { $0.folder == folder }.count }

    // MARK: - Disk

    private func load() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        guard let kept = try? JSONDecoder.workspace.decode(WorkspaceFile.self, from: data) else {
            Store.quarantine(file)
            return
        }
        folders = kept.folders
        items = kept.items
    }

    private func save() {
        guard let file, !retired else { return }
        let snapshot = WorkspaceFile(folders: folders, items: items)
        Disk.write(file) { try? JSONEncoder.workspace.encode(snapshot) }
    }
}

private extension JSONEncoder {
    static var workspace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var workspace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
