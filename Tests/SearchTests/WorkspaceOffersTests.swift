import AppKit
import XCTest
@testable import Search

/// What ⌘K adds from the Workspace (WorkspaceOffers.swift). The shared list
/// is the one the test world keeps, so each case uses an address of its own
/// and takes it out again.
@MainActor
final class WorkspaceOffersTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    private func kept(_ host: String, title: String = "Kept brief") -> WorkItem {
        Workspace.shared.add(url: "https://\(host)/brief", title: title)!
    }

    func testAKeptLinkIsOfferedUnderTheOpenPages() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let host = "kept-\(UUID().uuidString.lowercased()).example"
        let item = kept(host)
        defer { Workspace.shared.remove(item.id) }

        let rows = browser.keptPages(matching: host, besides: [])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kind, .kept)
        XCTAssertEqual(rows.first?.key, "Kept brief")
        XCTAssertEqual(rows.first?.title, "Inbox", "the row says where it is kept")
        XCTAssertEqual(rows.first?.url.absoluteString, item.url)
    }

    func testAPageAlreadyOfferedAsOpenIsNotOfferedTwice() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let host = "kept-\(UUID().uuidString.lowercased()).example"
        let item = kept(host)
        defer { Workspace.shared.remove(item.id) }

        let url = URL(string: item.url)!
        let open = Suggestion(key: "Kept brief", title: host, url: url, kind: .open, tab: UUID())
        XCTAssertTrue(browser.keptPages(matching: host, besides: [open]).isEmpty)
    }

    func testNothingTypedOffersNothing() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        XCTAssertTrue(browser.keptPages(matching: "  ", besides: []).isEmpty)
    }

    func testAtMostFourAreOffered() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let word = "many\(UUID().uuidString.prefix(8).lowercased())"
        let items = (0..<6).map { kept("\(word)-\($0).example", title: "\(word) \($0)") }
        defer { items.forEach { Workspace.shared.remove($0.id) } }
        XCTAssertEqual(browser.keptPages(matching: word, besides: []).count, 4)
    }
}
