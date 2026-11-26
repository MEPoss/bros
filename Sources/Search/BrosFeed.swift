import CryptoKit
import Foundation

// How Bros knows an update is its own. Search checks that a release is signed
// by Office Commun's Apple certificate; Bros is signed ad hoc, with no
// certificate to check, so its releases carry an Ed25519 signature instead
// (tools/bros-feed.swift makes it, with a key that stays on its author's Mac).
// The feed is one small JSON file on the latest GitHub release. Its signature
// covers the version, the build, both download addresses and both hashes, so
// a changed file, a changed address or a swapped download is refused before
// anything is run, and the hash of the ZIP ties the download to the feed.

enum BrosFeed {
    /// The public half of the release key. Whoever has the private half can
    /// make this app install anything; whoever doesn't, can't.
    static let publicKey = "QaFBARD0cfAJoR5QrgAKU1ZtIuDGTzNy81s8feHQyKU="

    /// The feed of the latest release: GitHub sends this address to the
    /// appcast.json attached to it.
    static let feed = URL(string: "https://github.com/MEPoss/bros/releases/latest/download/appcast.json")!

    /// Every download comes from this repository's releases, and only from it.
    static let downloads = "/MEPoss/bros/releases/download/"

    /// The text that was signed: what a change to any of it would break.
    static func message(version: String, build: Int, url: String, sha256: String, dmg: String, dmgSha256: String) -> Data {
        Data(["bros-update", version, String(build), url, sha256, dmg, dmgSha256].joined(separator: "\n").utf8)
    }

    static func valid(signature: String, for message: Data, key: String = publicKey) -> Bool {
        guard let raw = Data(base64Encoded: key), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              let signature = Data(base64Encoded: signature)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// A download address of this repository's releases, over https.
    static func isOurs(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix(downloads)
            && url.query == nil && url.fragment == nil
    }

    /// The release the feed describes, when its signature holds and its
    /// addresses are ours; nil for anything else.
    static func release(from data: Data, key: String = publicKey) -> Updater.Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              let build = (json["build"] as? Int) ?? Int(json["build"] as? String ?? ""),
              let archive = (json["url"] as? String).flatMap(URL.init(string:)),
              let dmg = (json["dmg"] as? String).flatMap(URL.init(string:)),
              let sha = (json["sha256"] as? String)?.lowercased(), sha.count == 64,
              let dmgSha = (json["dmgSha256"] as? String)?.lowercased(), dmgSha.count == 64,
              let signature = json["signature"] as? String,
              isOurs(archive), isOurs(dmg),
              valid(signature: signature,
                    for: message(version: version, build: build, url: archive.absoluteString, sha256: sha,
                                 dmg: dmg.absoluteString, dmgSha256: dmgSha),
                    key: key)
        else { return nil }
        let notes = (json["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var release = Updater.Release(version: version, build: build, archive: archive, dmg: dmg, sha256: sha,
                                      notes: notes.flatMap { $0.isEmpty ? nil : $0 },
                                      minimumSystemVersion: json["minimumSystemVersion"] as? String)
        release.dmgSha256 = dmgSha
        return release
    }
}
