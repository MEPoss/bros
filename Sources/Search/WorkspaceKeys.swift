import AppKit
import WebKit

// The arrow keys of the Workspace. A page takes the keyboard of the window
// and keeps most of it, a text field in it included, so these are caught in
// the window's own key monitor (ContentView.watchKeys) before the page sees
// them, as the shortcuts are. The Workspace has them while it is asked to
// (WorkspaceNav.keysOwned), and gives them back on a click on a page.

@MainActor
final class WorkspaceKeys {
    static let shared = WorkspaceKeys()

    enum Key { case up, down, left, right, enter, delete }

    /// Who answers a key, for each part of the Workspace, and which view put
    /// the answer there: a view that goes away takes only its own.
    private var handlers: [WorkspaceNav.Zone: (token: UUID, answer: (Key) -> Bool)] = [:]

    func register(_ zone: WorkspaceNav.Zone, token: UUID, _ answer: @escaping (Key) -> Bool) {
        handlers[zone] = (token, answer)
    }

    func unregister(_ zone: WorkspaceNav.Zone, token: UUID) {
        if handlers[zone]?.token == token { handlers[zone] = nil }
    }

    func answer(_ zone: WorkspaceNav.Zone) -> ((Key) -> Bool)? { handlers[zone]?.answer }

    /// The key an event is, if it is one the Workspace uses: an arrow, with
    /// nothing held, or Return or Delete, once.
    nonisolated static func key(of event: NSEvent) -> Key? {
        // The arrows come with the function and numeric-pad flags set.
        let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard held.isEmpty else { return nil }
        switch event.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 36, 76: return event.isARepeat ? nil : .enter
        case 51, 117: return event.isARepeat ? nil : .delete
        default: return nil
        }
    }

    /// Whether a view is a page, or inside one.
    static func inPage(_ view: NSView?) -> Bool {
        var at = view
        while let here = at {
            if here is WKWebView { return true }
            at = here.superview
        }
        return false
    }

    /// A click: on a page, the keyboard is the page's again.
    func clicked(_ event: NSEvent) {
        guard WorkspaceNav.shared.keysOwned, let content = event.window?.contentView,
              Self.inPage(content.hitTest(event.locationInWindow)) else { return }
        WorkspaceNav.shared.keysOwned = false
    }
}

extension Browser {
    /// A key the Workspace answers, ahead of the page: the arrows and
    /// Return, while the Workspace has them. Not while a field of the
    /// window has the caret, or the address field is up, and Return is the
    /// page's when the page holds the keys, as typing in it is.
    func workspaceKey(_ event: NSEvent, in window: NSWindow?) -> Bool {
        let nav = WorkspaceNav.shared
        guard nav.keysOwned, !editing, !launching, !summoning,
              let key = WorkspaceKeys.key(of: event),
              let answer = WorkspaceKeys.shared.answer(nav.zone) else { return false }
        let responder = window?.firstResponder
        if responder is NSText { return false }
        if key == .enter, WorkspaceKeys.inPage(responder as? NSView) { return false }
        return answer(key)
    }
}
