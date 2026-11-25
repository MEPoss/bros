import AppKit
import XCTest
@testable import Search

/// The Workspace's arrow keys (WorkspaceKeys.swift): which keys they are, and
/// when the Workspace has them and when a page or a field does.
@MainActor
final class WorkspaceKeysTests: XCTestCase {
    override class func setUp() {
        TestWorld.enter()
        super.setUp()
    }

    /// A key press as the arrows send it, with the function and numeric-pad
    /// flags they carry.
    private func event(_ code: UInt16, flags: NSEvent.ModifierFlags = [.numericPad, .function],
                       repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: repeating,
                         keyCode: code)!
    }

    func testTheArrowsAndReturnAreTheWorkspacesAndNothingHeldWithThem() {
        XCTAssertEqual(WorkspaceKeys.key(of: event(126)), .up)
        XCTAssertEqual(WorkspaceKeys.key(of: event(125)), .down)
        XCTAssertEqual(WorkspaceKeys.key(of: event(123)), .left)
        XCTAssertEqual(WorkspaceKeys.key(of: event(124)), .right)
        XCTAssertEqual(WorkspaceKeys.key(of: event(125, repeating: true)), .down, "a held arrow goes on")
        XCTAssertEqual(WorkspaceKeys.key(of: event(36, flags: [])), .enter)
        XCTAssertNil(WorkspaceKeys.key(of: event(36, flags: [], repeating: true)), "Return once, not repeated")
        XCTAssertNil(WorkspaceKeys.key(of: event(125, flags: [.numericPad, .function, .command])), "⌘↓ is a command's")
        XCTAssertNil(WorkspaceKeys.key(of: event(125, flags: [.numericPad, .function, .option])))
        XCTAssertNil(WorkspaceKeys.key(of: event(125, flags: [.numericPad, .function, .shift])))
        XCTAssertNil(WorkspaceKeys.key(of: event(0, flags: [])), "a letter is the page's")
        XCTAssertNil(WorkspaceKeys.key(of: event(49, flags: [])), "and so is Space")
    }

    func testDeleteIsTheWorkspacesOnceAndNothingHeldWithIt() {
        XCTAssertEqual(WorkspaceKeys.key(of: event(51, flags: [])), .delete)
        XCTAssertEqual(WorkspaceKeys.key(of: event(117, flags: [.function])), .delete, "forward delete too")
        XCTAssertNil(WorkspaceKeys.key(of: event(51, flags: [], repeating: true)), "once, not repeated")
        XCTAssertNil(WorkspaceKeys.key(of: event(51, flags: [.shift])), "⇧⌫ clears browsing data")
        XCTAssertNil(WorkspaceKeys.key(of: event(51, flags: [.command])))
    }

    func testCommandKOpensTheWorkspaceAndSearchTabsIsGone() {
        let store = ShortcutStore.shared
        XCTAssertEqual(Command.named("workspace.show")?.defaultKey, KeyCombo("k"))
        XCTAssertNil(Command.named("tabs.search"))
        XCTAssertEqual(store.key(for: "workspace.show"), KeyCombo("k"))
    }

    func testAViewThatGoesAwayTakesOnlyItsOwnAnswer() {
        let keys = WorkspaceKeys.shared
        let first = UUID(), second = UUID()
        keys.register(.links, token: first) { _ in false }
        keys.register(.links, token: second) { _ in true }
        keys.unregister(.links, token: first)
        XCTAssertEqual(keys.answer(.links)?(.down), true, "the one that came after is still there")
        keys.unregister(.links, token: second)
        XCTAssertNil(keys.answer(.links))
    }

    func testTheWorkspaceHasTheKeysFromTheMomentItIsAskedAndKeepsThemUntilGivenBack() {
        let nav = WorkspaceNav.shared
        nav.keysOwned = false
        nav.go(.links)
        XCTAssertTrue(nav.keysOwned)
        XCTAssertEqual(nav.zone, .links)
        nav.go(.sections)
        XCTAssertEqual(nav.zone, .sections)
        nav.keysOwned = false
    }

    func testTheBrowserOffersAKeyOnlyWhileTheWorkspaceHasThem() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let nav = WorkspaceNav.shared
        let keys = WorkspaceKeys.shared
        let token = UUID()
        var seen: [WorkspaceKeys.Key] = []
        keys.register(.sections, token: token) { seen.append($0); return true }
        defer {
            keys.unregister(.sections, token: token)
            nav.keysOwned = false
            browser.editing = false
        }

        nav.go(.sections)
        XCTAssertTrue(browser.workspaceKey(event(125), in: nil))
        XCTAssertEqual(seen, [.down])

        nav.keysOwned = false
        XCTAssertFalse(browser.workspaceKey(event(125), in: nil), "given back: the page's again")
        XCTAssertEqual(seen, [.down])

        nav.go(.links)
        XCTAssertFalse(browser.workspaceKey(event(125), in: nil), "nothing answers for the links here")

        nav.go(.sections)
        browser.editing = true
        XCTAssertFalse(browser.workspaceKey(event(125), in: nil), "the address field is up: its keys")
    }

    func testAFieldWithTheCaretKeepsItsArrows() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let nav = WorkspaceNav.shared
        let keys = WorkspaceKeys.shared
        let token = UUID()
        keys.register(.sections, token: token) { _ in true }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        window.contentView?.addSubview(field)
        defer {
            keys.unregister(.sections, token: token)
            nav.keysOwned = false
            window.close()
        }
        nav.go(.sections)
        XCTAssertTrue(browser.workspaceKey(event(125), in: window), "no field has the caret")
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(browser.workspaceKey(event(125), in: window), "a field has it: its caret moves")
    }
}
