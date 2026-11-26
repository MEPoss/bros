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

    // MARK: - pictures of pages that are not open

    private var asked = Set<UUID>()
    private var running = 0

    /// A link nothing has pictured yet gets its page's own picture (the
    /// og:image or twitter:image it declares), fetched without opening the
    /// page in a tab. At most three at a time; one try per link per run.
    func fetchPreview(for item: WorkItem) {
        guard image(for: item.id) == nil, running < 3, !asked.contains(item.id),
              let page = URL(string: item.url), page.scheme == "https" || page.scheme == "http"
        else { return }
        asked.insert(item.id)
        running += 1
        let id = item.id
        Task { [weak self] in
            let image = await WorkspaceThumbs.remotePicture(of: page)
            guard let self else { return }
            self.running -= 1
            if let image, self.image(for: id) == nil { self.store(image, for: id) }
        }
    }

    /// The picture a page declares for itself, nil when it has none.
    nonisolated static func remotePicture(of page: URL) async -> NSImage? {
        var request = URLRequest(url: page, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let html = String(data: data.prefix(600_000), encoding: .utf8) ?? String(data: data.prefix(600_000), encoding: .isoLatin1),
              let address = declaredPicture(in: html, base: response.url ?? page)
        else { return nil }
        var pictureRequest = URLRequest(url: address, timeoutInterval: 12)
        pictureRequest.setValue(request.value(forHTTPHeaderField: "User-Agent"), forHTTPHeaderField: "User-Agent")
        guard let (bytes, answer) = try? await URLSession.shared.data(for: pictureRequest),
              (answer as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              bytes.count < 8_000_000, let image = NSImage(data: bytes), image.size.width > 40, image.size.height > 40
        else { return nil }
        return image
    }

    /// The og:image / twitter:image of a page's source, as an absolute address.
    nonisolated static func declaredPicture(in html: String, base: URL) -> URL? {
        let head = String(html.prefix(400_000))
        let found = (try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: .caseInsensitive))
            .map { $0.matches(in: head, range: NSRange(head.startIndex..., in: head)) } ?? []
        let tags = found.compactMap { Range($0.range, in: head).map { String(head[$0]) } }
        for wanted in ["og:image:secure_url", "og:image", "twitter:image", "twitter:image:src"] {
            for tag in tags {
                guard let name = attribute("property", in: tag) ?? attribute("name", in: tag),
                      name.lowercased() == wanted, let content = attribute("content", in: tag), !content.isEmpty
                else { continue }
                let text = content.replacingOccurrences(of: "&amp;", with: "&")
                if let url = URL(string: text, relativeTo: base)?.absoluteURL,
                   url.scheme == "https" || url.scheme == "http" { return url }
            }
        }
        return nil
    }

    nonisolated private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b" + name + "\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
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
