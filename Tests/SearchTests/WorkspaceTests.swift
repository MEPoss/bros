import AppKit
import XCTest
@testable import Search

/// Workspace (Workspace.swift): links kept as files in folders, with a
/// status, a priority and a due date. Nothing here touches the disk: every
/// case builds a Workspace with no file.
@MainActor
final class WorkspaceTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func day(_ offset: Int, from now: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: now)!
    }

    // MARK: addresses

    func testTrackingParametersAndFragmentAreDropped() {
        XCTAssertEqual(
            Workspace.normalized("https://Example.com/a?utm_source=x&id=7&fbclid=z#top"),
            "https://example.com/a?id=7")
    }

    func testBareHostLosesItsSlashAndOtherSchemesAreRefused() {
        XCTAssertEqual(Workspace.normalized("https://example.com/"), "https://example.com")
        XCTAssertNil(Workspace.normalized("search://settings"))
        XCTAssertNil(Workspace.normalized("file:///tmp/a.html"))
        XCTAssertNil(Workspace.normalized("not a link"))
    }

    func testTheSamePageIsOneItem() {
        let space = Workspace(file: nil)
        let first = space.add(url: "https://example.com/p?utm_medium=mail", title: "P")
        let again = space.add(url: "https://example.com/p#section", title: "P again")
        XCTAssertEqual(first?.id, again?.id)
        XCTAssertEqual(space.items.count, 1)
    }

    func testAnAddressThatIsNotAPageIsNotKept() {
        let space = Workspace(file: nil)
        XCTAssertNil(space.add(url: "search://history", title: "History"))
        XCTAssertTrue(space.items.isEmpty)
    }

    // MARK: folders

    func testANewItemStartsInTheInbox() {
        let space = Workspace(file: nil)
        let item = space.add(url: "https://example.com", title: "E")!
        XCTAssertNil(item.folder)
        XCTAssertEqual(space.items(in: nil).map(\.id), [item.id])
    }

    func testAskingForAFolderThatIsGoneKeepsItInTheInbox() {
        let space = Workspace(file: nil)
        let item = space.add(url: "https://example.com", title: "E", folder: UUID())!
        XCTAssertNil(item.folder)
    }

    func testDeletingAFolderNeverDeletesALink() {
        let space = Workspace(file: nil)
        let work = space.addFolder("Work")!
        let alpha = space.addFolder("Alpha", in: work.id)!
        let item = space.add(url: "https://example.com", title: "E", folder: alpha.id)!
        space.removeFolder(alpha.id)
        XCTAssertEqual(space.item(item.id)?.folder, nil)
        space.removeFolder(work.id)
        XCTAssertEqual(space.items.count, 1)
        XCTAssertTrue(space.folders.isEmpty)
    }

    func testDeletingAFolderLiftsItsSubfolders() {
        let space = Workspace(file: nil)
        let top = space.addFolder("Top")!
        let middle = space.addFolder("Middle", in: top.id)!
        let low = space.addFolder("Low", in: middle.id)!
        space.removeFolder(middle.id)
        XCTAssertEqual(space.folder(low.id)?.parent, top.id)
    }

    func testAFolderCannotGoInsideItself() {
        let space = Workspace(file: nil)
        let top = space.addFolder("Top")!
        let low = space.addFolder("Low", in: top.id)!
        space.moveFolder(top.id, to: low.id)
        XCTAssertNil(space.folder(top.id)?.parent)
        space.moveFolder(top.id, to: top.id)
        XCTAssertNil(space.folder(top.id)?.parent)
    }

    func testPathNamesWhereAFolderIs() {
        let space = Workspace(file: nil)
        let work = space.addFolder("Work")!
        let alpha = space.addFolder("Alpha", in: work.id)!
        XCTAssertEqual(space.path(of: alpha.id), "Work / Alpha")
        XCTAssertEqual(space.path(of: nil), "Inbox")
    }

    func testAnEmptyFolderNameIsRefused() {
        let space = Workspace(file: nil)
        XCTAssertNil(space.addFolder("   "))
    }

    // MARK: status, priority, tags

    func testPriorityStaysWithinItsRange() {
        let space = Workspace(file: nil)
        let item = space.add(url: "https://example.com", title: "E")!
        space.update(item.id) { $0.priority = 9 }
        XCTAssertEqual(space.item(item.id)?.priority, 3)
        space.update(item.id) { $0.priority = -4 }
        XCTAssertEqual(space.item(item.id)?.priority, 0)
    }

    func testTagsAreTidied() {
        XCTAssertEqual(Workspace.cleaned([" #Client ", "client", "", "Ideas"]), ["client", "ideas"])
    }

    func testMovingToAFolderThatIsGoneSendsItToTheInbox() {
        let space = Workspace(file: nil)
        let item = space.add(url: "https://example.com", title: "E")!
        space.move(item.id, to: UUID())
        XCTAssertNil(space.item(item.id)?.folder)
    }

    // MARK: views

    func testTodoListsTheMostUrgentFirstThenTheSoonest() {
        let space = Workspace(file: nil)
        let now = Date()
        let a = space.add(url: "https://a.example", title: "a")!
        let b = space.add(url: "https://b.example", title: "b")!
        let c = space.add(url: "https://c.example", title: "c")!
        let d = space.add(url: "https://d.example", title: "d")!
        let reference = space.add(url: "https://ref.example", title: "ref")!
        space.update(a.id) { $0.status = .todo; $0.priority = 1; $0.due = day(5, from: now) }
        space.update(b.id) { $0.status = .doing; $0.priority = 3 }
        space.update(c.id) { $0.status = .todo; $0.priority = 1; $0.due = day(2, from: now) }
        space.update(d.id) { $0.status = .done; $0.priority = 3 }
        XCTAssertEqual(space.todo().map(\.id), [b.id, c.id, a.id])
        XCTAssertNil(space.item(reference.id)?.status)
    }

    func testDueIncludesLateWorkAndLeavesOutWhatIsDone() {
        let space = Workspace(file: nil)
        let now = Date()
        let late = space.add(url: "https://late.example", title: "late")!
        let soon = space.add(url: "https://soon.example", title: "soon")!
        let far = space.add(url: "https://far.example", title: "far")!
        let done = space.add(url: "https://done.example", title: "done")!
        space.update(late.id) { $0.status = .todo; $0.due = day(-3, from: now) }
        space.update(soon.id) { $0.status = .todo; $0.due = day(2, from: now) }
        space.update(far.id) { $0.status = .todo; $0.due = day(30, from: now) }
        space.update(done.id) { $0.status = .done; $0.due = day(1, from: now) }
        XCTAssertEqual(space.due(within: 7, now: now).map(\.id), [late.id, soon.id])
    }

    func testSearchNeedsEveryWordInTheNameAddressTagsOrNote() {
        let space = Workspace(file: nil)
        let item = space.add(url: "https://example.com/brief", title: "Client brief")!
        space.update(item.id) { $0.tags = ["alpha"]; $0.notes = "send on Monday" }
        XCTAssertEqual(space.search("brief alpha monday").map(\.id), [item.id])
        XCTAssertTrue(space.search("brief beta").isEmpty)
        XCTAssertTrue(space.search("   ").isEmpty)
    }

    // MARK: following the tabs

    func testAnOpenPageBecomesAnItemInTheInbox() {
        let space = Workspace(file: nil)
        space.sync(open: [("https://a.example/x?utm_source=m", "A"), ("https://b.example", "B")])
        XCTAssertEqual(Set(space.items(in: nil).map(\.url)), ["https://a.example/x", "https://b.example"])
        XCTAssertEqual(space.live, ["https://a.example/x", "https://b.example"])
        XCTAssertTrue(space.items.allSatisfy { !$0.kept })
    }

    func testSyncingAgainChangesNothingAndAddsNoDuplicate() {
        let space = Workspace(file: nil)
        let pages = [("https://a.example", "A")]
        XCTAssertTrue(space.sync(open: pages))
        XCTAssertFalse(space.sync(open: pages))
        XCTAssertEqual(space.items.count, 1)
    }

    func testATitleThatArrivesLaterIsTaken() {
        let space = Workspace(file: nil)
        space.sync(open: [("https://a.example", "")])
        space.sync(open: [("https://a.example", "A at last")])
        XCTAssertEqual(space.items.first?.title, "A at last")
        space.sync(open: [("https://a.example", "")])
        XCTAssertEqual(space.items.first?.title, "A at last", "an empty title never wipes a name")
    }

    func testClosingATabTakesAwayWhatWasOnlyOpen() {
        let space = Workspace(file: nil)
        space.sync(open: [("https://a.example", "A"), ("https://b.example", "B")])
        space.sync(open: [("https://b.example", "B")])
        XCTAssertEqual(space.items.map(\.url), ["https://b.example"])
    }

    func testWhatWasFiledOrKeptStaysAsAClosedFile() {
        let space = Workspace(file: nil)
        space.sync(open: [("https://a.example", "A"), ("https://b.example", "B"),
                          ("https://c.example", "C"), ("https://d.example", "D")])
        let a = space.item(for: "https://a.example")!
        let b = space.item(for: "https://b.example")!
        let c = space.item(for: "https://c.example")!
        space.update(a.id) { $0.status = .todo }
        space.update(b.id) { $0.notes = "call back" }
        space.keep(url: "https://c.example", title: "C")
        space.sync(open: [])
        XCTAssertEqual(Set(space.items.map(\.url)), ["https://a.example", "https://b.example", "https://c.example"])
        XCTAssertTrue(space.live.isEmpty)
        XCTAssertFalse(space.isLive(space.item(for: "https://a.example")!), "it is closed now")
    }

    func testAPageOpenAgainFindsItsItemWithItsStatus() {
        let space = Workspace(file: nil)
        space.sync(open: [("https://a.example", "A")])
        let a = space.item(for: "https://a.example")!
        space.update(a.id) { $0.status = .doing; $0.priority = 2 }
        space.sync(open: [])
        space.sync(open: [("https://a.example/#top", "A")])
        XCTAssertEqual(space.items.count, 1)
        XCTAssertEqual(space.items.first?.status, .doing)
        XCTAssertTrue(space.isLive(space.items.first!))
    }

    func testPagesThatAreNotTheWebAreLeftOut() {
        let space = Workspace(file: nil)
        space.sync(open: [("search://workspace", "Workspace"), ("file:///tmp/a.html", "A"), ("https://a.example", "A")])
        XCTAssertEqual(space.items.map(\.url), ["https://a.example"])
    }

    func testKeepingAnOpenPageMakesItStayAndNotesItWasKept() {
        let space = Workspace(file: nil)
        space.sync(open: [("https://a.example", "A")])
        XCTAssertFalse(space.item(for: "https://a.example")!.kept)
        space.keep(url: "https://a.example", title: "A")
        XCTAssertTrue(space.item(for: "https://a.example")!.kept)
        XCTAssertEqual(space.items.count, 1)
    }

    func testAnItemFromAnOlderFileCountsAsKept() throws {
        let id = UUID()
        let json = """
        {"folders":[],"items":[{"id":"\(id.uuidString)","url":"https://example.com","title":"E"}]}
        """
        let kept = try JSONDecoder().decode(WorkspaceFile.self, from: Data(json.utf8))
        XCTAssertEqual(kept.items.first?.kept, true)
    }

    // MARK: dragging

    func testWhatIsDraggedSurvivesTheTrip() throws {
        let a = UUID(), b = UUID(), folder = UUID()
        let drag = WorkDrag(items: [a, b], folder: folder)
        let back = try JSONDecoder().decode(WorkDrag.self, from: JSONEncoder().encode(drag))
        XCTAssertEqual(back.items, [a, b])
        XCTAssertEqual(back.folder, folder)
    }

    func testSeveralLinksDroppedOnAFolderAllGoThereAndStayAfterTheirTabsClose() {
        let space = Workspace(file: nil)
        space.sync(open: [("https://a.example", "A"), ("https://b.example", "B"), ("https://c.example", "C")])
        let work = space.addFolder("Work")!
        for url in ["https://a.example", "https://b.example"] {
            space.move(space.item(for: url)!.id, to: work.id)
        }
        space.sync(open: [])
        XCTAssertEqual(Set(space.items(in: work.id).map(\.url)), ["https://a.example", "https://b.example"])
        XCTAssertNil(space.item(for: "https://c.example"), "the one never filed went with its tab")
    }

    func testAFolderDroppedOnAnotherGoesInsideAndNeverInsideItself() {
        let space = Workspace(file: nil)
        let work = space.addFolder("Work")!
        let alpha = space.addFolder("Alpha")!
        space.moveFolder(alpha.id, to: work.id)
        XCTAssertEqual(space.folder(alpha.id)?.parent, work.id)
        space.moveFolder(work.id, to: alpha.id)
        XCTAssertNil(space.folder(work.id)?.parent, "a folder never goes inside what it holds")
        space.moveFolder(alpha.id, to: nil)
        XCTAssertNil(space.folder(alpha.id)?.parent, "dropped on the Inbox it comes back to the top")
    }

    // MARK: pictures

    func testAPictureKeptOnDiskComesBackAndGoesWithItsLink() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID(), gone = UUID()
        let image = NSImage(size: NSSize(width: 40, height: 25), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let thumbs = WorkspaceThumbs(folder: folder)
        thumbs.store(image, for: id)
        thumbs.store(image, for: gone)
        Disk.drain()

        let later = WorkspaceThumbs(folder: folder)
        XCTAssertNotNil(later.image(for: id), "a closed file still has its last picture")
        later.prune(keeping: [id])
        Disk.drain()
        XCTAssertNotNil(WorkspaceThumbs(folder: folder).image(for: id))
        XCTAssertNil(WorkspaceThumbs(folder: folder).image(for: gone), "the picture of a link that is gone goes too")
    }

    func testAPictureIsTakenAgainOnlyWhenItIsOld() {
        let thumbs = WorkspaceThumbs(folder: nil)
        let id = UUID()
        let now = Date()
        XCTAssertTrue(thumbs.wants(id, now: now), "none yet")
        thumbs.store(NSImage(size: NSSize(width: 2, height: 2)), for: id, now: now)
        XCTAssertFalse(thumbs.wants(id, now: now.addingTimeInterval(5)))
        XCTAssertTrue(thumbs.wants(id, now: now.addingTimeInterval(30)))
    }

    // MARK: the tree

    func testFoldersAreListedInTheOrderATreeIsRead() {
        let space = Workspace(file: nil)
        let b = space.addFolder("B")!
        let a = space.addFolder("A")!
        let a2 = space.addFolder("A2", in: a.id)!
        let a1 = space.addFolder("A1", in: a.id)!
        XCTAssertEqual(space.flattened().map(\.id), [a.id, a1.id, a2.id, b.id])
        XCTAssertEqual(space.flattened(from: a.id).map(\.id), [a1.id, a2.id])
    }

    func testTheWorkspaceKeyIsNotTakenByAnotherCommand() {
        let key = KeyCombo("o", shift: true)
        let owners = Command.all.filter { $0.defaultKey == key }.map(\.id)
        XCTAssertEqual(owners, ["workspace.sidebar"])
        XCTAssertFalse(KeyCombo.isReserved(key))
    }

    // MARK: stepping through the tabs

    func testAStepUpOrDownStopsAtTheEndsAndStartsFromTheEndsWhenNothingIsOn() {
        XCTAssertEqual(WorkspaceTree.stepIndex(of: 1, count: 4, direction: 1), 2)
        XCTAssertEqual(WorkspaceTree.stepIndex(of: 1, count: 4, direction: -1), 0)
        XCTAssertEqual(WorkspaceTree.stepIndex(of: 3, count: 4, direction: 1), 0, "past the last is the first")
        XCTAssertEqual(WorkspaceTree.stepIndex(of: 0, count: 4, direction: -1), 3, "and before the first is the last")
        XCTAssertEqual(WorkspaceTree.stepIndex(of: nil, count: 4, direction: 1), 0)
        XCTAssertEqual(WorkspaceTree.stepIndex(of: nil, count: 4, direction: -1), 3)
        XCTAssertNil(WorkspaceTree.stepIndex(of: nil, count: 0, direction: 1))
    }

    func testTheOptionCommandArrowsAreTheWorkspaceWalk() {
        let owners: [(String, String)] = [("down", "tabs.columnNext"), ("up", "tabs.columnPrevious"),
                                          ("right", "workspace.sectionNext"), ("left", "workspace.sectionPrevious")]
        for (name, id) in owners {
            let combo = KeyCombo(name, option: true)
            XCTAssertEqual(Command.all.filter { $0.defaultKey == combo }.map(\.id), [id])
            XCTAssertFalse(KeyCombo.isReserved(combo))
        }
        // The plain ⌘ arrows are the page's and the text field's again.
        for name in ["down", "up"] {
            XCTAssertTrue(Command.all.filter { $0.defaultKey == KeyCombo(name) }.isEmpty)
        }
    }

    // MARK: the tree and the arrow keys

    /// An Inbox with two open pages, and a folder, with a closed page in it
    /// and a folder of its own.
    private func treeSpace() -> (space: Workspace, folder: WorkFolder, inner: WorkFolder) {
        let space = Workspace(file: nil)
        let t = Date()
        space.sync(open: [("https://a.example", "a")], now: t)
        space.sync(open: [("https://a.example", "a"), ("https://b.example", "b")], now: t.addingTimeInterval(1))
        space.sync(open: [("https://a.example", "a"), ("https://b.example", "b"), ("https://c.example", "c")],
                   now: t.addingTimeInterval(2))
        let work = space.addFolder("Work")!
        let inner = space.addFolder("Alpha", in: work.id)!
        space.move(space.item(for: "https://c.example")!.id, to: work.id)
        space.sync(open: [("https://a.example", "a"), ("https://b.example", "b")], now: t.addingTimeInterval(3))
        return (space, work, inner)
    }

    func testTheSectionsAreTheViewsThenTheFoldersAndAClosedFoldersFoldersAreLeftOut() {
        let (space, work, inner) = treeSpace()
        let all = WorkspaceTree.sections(space, open: nil)
        XCTAssertEqual(all.map(\.place), [.inbox, .todo, .due, .folder(work.id), .folder(inner.id)])
        XCTAssertEqual(WorkspaceTree.sections(space, open: []).map(\.place), [.inbox, .todo, .due, .folder(work.id)])
        XCTAssertEqual(all.last?.depth, 1)
    }

    func testAnOpenSectionListsItsFoldersThenItsLinks() {
        let (space, work, inner) = treeSpace()
        let closed = WorkspaceTree.rows(space, open: [])
        XCTAssertEqual(closed.map(\.id), ["s/inbox", "s/todo", "s/due", "s/\(work.id.uuidString)"])
        let open = WorkspaceTree.rows(space, open: [.inbox, .folder(work.id)])
        let kinds: [String] = open.map { row in
            switch row.kind {
            case .section(let s): return "section \(s.title)"
            case .link(let item, _): return "link \(item.title)"
            }
        }
        XCTAssertEqual(kinds, ["section Inbox", "link b", "link a", "section To do", "section Due this week",
                               "section Work", "section Alpha", "link c"],
                       "Inbox's links, then Work's folder and its link")
        XCTAssertEqual(open.last.map { $0.depth }, 1)
        XCTAssertTrue(open.contains { $0.id == "s/\(inner.id.uuidString)" })
    }

    private func move(_ key: WorkspaceTree.ColumnKey, from id: String?, _ space: Workspace, open: Set<WorkspacePlace>)
        -> WorkspaceTree.TreeMove {
        WorkspaceTree.treeMove(key, from: id, in: WorkspaceTree.rows(space, open: open), open: open, space: space)
    }

    func testDownAndUpGoRowToRowAndStopAtTheEnds() {
        let (space, work, _) = treeSpace()
        XCTAssertEqual(move(.down, from: nil, space, open: []).cursor, "s/inbox")
        XCTAssertEqual(move(.down, from: "s/inbox", space, open: []).cursor, "s/todo", "Inbox, then To do")
        XCTAssertEqual(move(.down, from: "s/todo", space, open: []).cursor, "s/due")
        XCTAssertEqual(move(.up, from: "s/todo", space, open: []).cursor, "s/inbox")
        XCTAssertEqual(move(.up, from: "s/inbox", space, open: []).cursor, "s/inbox", "it stops at the top")
        let last = "s/\(work.id.uuidString)"
        XCTAssertEqual(move(.down, from: last, space, open: []).cursor, last, "and at the bottom")
    }

    func testDownFromAnOpenSectionGoesIntoItsListAndThenOnToTheNextSection() {
        let (space, _, _) = treeSpace()
        let rows = WorkspaceTree.rows(space, open: [.inbox])
        let firstLink = rows[1].id
        XCTAssertTrue(firstLink.hasPrefix("l/inbox/"))
        XCTAssertEqual(move(.down, from: "s/inbox", space, open: [.inbox]).cursor, firstLink)
        XCTAssertEqual(move(.down, from: rows[2].id, space, open: [.inbox]).cursor, "s/todo", "past the last link")
    }

    func testRightOpensASectionThatHasSomethingInItThenGoesIntoItAndLeavesAnEmptyOneAlone() {
        let (space, work, _) = treeSpace()
        let key = "s/\(work.id.uuidString)"
        XCTAssertEqual(move(.right, from: "s/inbox", space, open: []),
                       WorkspaceTree.TreeMove(cursor: "s/inbox", toggle: .inbox), "closed with links: it opens")
        let into = move(.right, from: "s/inbox", space, open: [.inbox])
        XCTAssertTrue(into.cursor?.hasPrefix("l/inbox/") == true, "open: into its list")
        XCTAssertNil(into.toggle)
        XCTAssertEqual(move(.right, from: key, space, open: []),
                       WorkspaceTree.TreeMove(cursor: key, toggle: .folder(work.id)), "a folder with a folder and a link")
        XCTAssertEqual(move(.right, from: "s/todo", space, open: []),
                       WorkspaceTree.TreeMove(cursor: "s/todo"), "nothing to do: nothing to open")
        let link = WorkspaceTree.rows(space, open: [.inbox])[1].id
        XCTAssertEqual(move(.right, from: link, space, open: [.inbox]), WorkspaceTree.TreeMove(cursor: link),
                       "a link has nothing to open")
    }

    func testLeftFoldsAnOpenSectionOrGoesUpToTheOneThatHoldsTheRow() {
        let (space, work, inner) = treeSpace()
        let open: Set<WorkspacePlace> = [.inbox, .folder(work.id)]
        XCTAssertEqual(move(.left, from: "s/inbox", space, open: open),
                       WorkspaceTree.TreeMove(cursor: "s/inbox", toggle: .inbox), "open: it folds")
        let link = WorkspaceTree.rows(space, open: open)[1].id
        XCTAssertEqual(move(.left, from: link, space, open: open).cursor, "s/inbox", "a link goes up to its section")
        XCTAssertEqual(move(.left, from: "s/\(inner.id.uuidString)", space, open: open).cursor,
                       "s/\(work.id.uuidString)", "a folder goes up to the one that holds it")
        XCTAssertEqual(move(.left, from: "s/todo", space, open: open), WorkspaceTree.TreeMove(cursor: "s/todo"),
                       "closed at the top: nowhere to go")
    }

    func testAPlaceThatIsGoneStartsAtTheFirstRow() {
        let (space, _, _) = treeSpace()
        XCTAssertEqual(move(.down, from: "s/\(UUID().uuidString)", space, open: []).cursor, "s/inbox")
        XCTAssertEqual(WorkspaceTree.treeMove(.down, from: nil, in: [], open: [], space: space), WorkspaceTree.TreeMove())
    }

    // MARK: the file

    func testAFileWithAFieldFromTheFutureStillReads() throws {
        let id = UUID()
        let json = """
        {"folders":[],"items":[{"id":"\(id.uuidString)","url":"https://example.com","status":"someday","color":"red"}]}
        """
        let kept = try JSONDecoder().decode(WorkspaceFile.self, from: Data(json.utf8))
        XCTAssertEqual(kept.items.first?.id, id)
        XCTAssertNil(kept.items.first?.status)
        XCTAssertEqual(kept.items.first?.priority, 0)
    }

    func testWhatIsKeptComesBackAsItWas() throws {
        let space = Workspace(file: nil)
        let work = space.addFolder("Work")!
        let item = space.add(url: "https://example.com/p", title: "P", folder: work.id)!
        space.update(item.id) { $0.status = .doing; $0.priority = 2; $0.tags = ["a"]; $0.notes = "n" }
        let file = WorkspaceFile(folders: space.folders, items: space.items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(WorkspaceFile.self, from: encoder.encode(file))
        XCTAssertEqual(back.folders, file.folders)
        XCTAssertEqual(back.items.map(\.url), file.items.map(\.url))
        XCTAssertEqual(back.items.first?.status, .doing)
        XCTAssertEqual(back.items.first?.folder, work.id)
    }
}
