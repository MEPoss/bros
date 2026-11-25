import Foundation

// What this copy of the app is called. Bros is this checkout's own build of
// Search (MIT, Office Commun): the same code under a name, a bundle
// identifier, a folder for its data and an icon of its own, so that it sits
// beside Search without sharing its settings or its files, and takes no
// updates from it. Anything else, including a test run, is Search.

enum Brand {
    /// The bundle identifier build.sh gives Bros.
    static let forkIdentifier = "app.bros.browser"

    static var isFork: Bool { Bundle.main.bundleIdentifier == forkIdentifier }

    /// The name shown in the app's own menus and windows.
    static var name: String { isFork ? "Bros" : "Search" }
}
