import AppKit

// The pictures of the Workspace's links: the last view of each site, kept on
// disk so that a closed file still shows how its page looked. Taken from the
// tab while it is open, as the tab switcher's cards are (Tab.preview), and
// taken again from time to time while it is on screen, which is as near to
// live as a page in another tab can be.

@MainActor
final class WorkspaceThumbs: ObservableObject {
    static let shared = WorkspaceThumbs()

    /// Bumped whenever a picture is new, for what draws them to draw again.
    @Published private(set) var revision = 0

    private var cache: [UUID: NSImage] = [:]
    private var taken: [UUID: Date] = [:]
    private var busy = Set<UUID>()
    /// Where they are kept; nil keeps nothing, for a test.
    private let folder: URL?

    init(folder: URL? = Store.file("workspace-thumbs")) {
        self.folder = folder
    }

    private func file(_ id: UUID) -> URL? {
        folder?.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// The last picture of the page, from memory or from disk.
    func image(for id: UUID) -> NSImage? {
        if let hit = cache[id] { return hit }
        guard let url = file(id), let image = NSImage(contentsOf: url) else { return nil }
        cache[id] = image
        return image
    }

    /// Whether the page is worth pictured again: it has no picture, or its
    /// picture is older than `every` seconds, and none is being taken.
    func wants(_ id: UUID, now: Date = Date(), every: TimeInterval = 20) -> Bool {
        if busy.contains(id) { return false }
        guard let last = taken[id] else { return true }
        return now.timeIntervalSince(last) > every
    }

    /// Takes the picture of an open tab's page, if it has drawn one yet.
    func capture(_ tab: Tab, for id: UUID) {
        guard tab.painted, busy.insert(id).inserted else { return }
        tab.preview(width: 360) { [weak self] image in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.busy.remove(id)
                guard let image, image.size.width > 1, image.size.height > 1 else { return }
                self.store(image, for: id)
            }
        }
    }

    /// Keeps a picture: in memory and on disk.
    func store(_ image: NSImage, for id: UUID, now: Date = Date()) {
        taken[id] = now
        cache[id] = image
        revision &+= 1
        guard let url = file(id), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return }
        Disk.write(url) { data }
    }

    /// Pictures of links that are gone are taken away with them.
    func prune(keeping ids: Set<UUID>) {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !ids.contains(id) else { continue }
            cache[id] = nil
            taken[id] = nil
            Disk.remove(file)
        }
    }
}
