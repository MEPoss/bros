import CryptoKit
import XCTest
@testable import Search

/// What Bros takes for one of its own updates (BrosFeed.swift).
final class BrosFeedTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()
    private var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }

    private let zip = "https://github.com/MEPoss/bros/releases/download/v1.0.9/Bros.zip"
    private let dmg = "https://github.com/MEPoss/bros/releases/download/v1.0.9/Bros.dmg"
    private let sha = String(repeating: "a", count: 64)
    private let dmgSha = String(repeating: "b", count: 64)

    private func feed(version: String = "1.0.9", build: Int = 202612010000, zip: String? = nil, dmg: String? = nil,
                      sha: String? = nil, signedWith signer: Curve25519.Signing.PrivateKey? = nil,
                      change: ((inout [String: Any]) -> Void)? = nil) throws -> Data {
        let (zip, dmg, sha) = (zip ?? self.zip, dmg ?? self.dmg, sha ?? self.sha)
        let message = BrosFeed.message(version: version, build: build, url: zip, sha256: sha, dmg: dmg, dmgSha256: dmgSha)
        let signature = try (signer ?? key).signature(for: message).base64EncodedString()
        var json: [String: Any] = ["version": version, "build": build, "url": zip, "sha256": sha, "dmg": dmg,
                                   "dmgSha256": dmgSha, "notes": "Folder icons.", "signature": signature]
        change?(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testASignedFeedOfOurReleasesIsRead() throws {
        let release = try XCTUnwrap(BrosFeed.release(from: try feed(), key: publicKey))
        XCTAssertEqual(release.version, "1.0.9")
        XCTAssertEqual(release.build, 202612010000)
        XCTAssertEqual(release.archive.absoluteString, zip)
        XCTAssertEqual(release.sha256, sha)
        XCTAssertEqual(release.dmgSha256, dmgSha)
        XCTAssertEqual(release.notes, "Folder icons.")
    }

    func testAFeedSignedByAnotherKeyIsRefused() throws {
        let other = Curve25519.Signing.PrivateKey()
        XCTAssertNil(BrosFeed.release(from: try feed(signedWith: other), key: publicKey))
    }

    func testAnythingChangedAfterSigningIsRefused() throws {
        XCTAssertNil(BrosFeed.release(from: try feed { $0["build"] = 999999999999 }, key: publicKey), "a newer build")
        XCTAssertNil(BrosFeed.release(from: try feed { $0["version"] = "9.9" }, key: publicKey))
        XCTAssertNil(BrosFeed.release(from: try feed { $0["sha256"] = String(repeating: "c", count: 64) }, key: publicKey),
                     "another ZIP")
        XCTAssertNil(BrosFeed.release(from: try feed { $0["dmgSha256"] = String(repeating: "c", count: 64) }, key: publicKey))
        XCTAssertNil(BrosFeed.release(from: try feed { $0["url"] = "https://github.com/MEPoss/bros/releases/download/v1.0.1/Bros.zip" },
                                      key: publicKey), "an older download")
        XCTAssertNil(BrosFeed.release(from: try feed { $0.removeValue(forKey: "signature") }, key: publicKey))
        XCTAssertNil(BrosFeed.release(from: Data("not json".utf8), key: publicKey))
    }

    func testOnlyDownloadsFromOurReleasesAreFollowed() throws {
        let elsewhere = "https://example.com/MEPoss/bros/releases/download/v1.0.9/Bros.zip"
        XCTAssertNil(BrosFeed.release(from: try feed(zip: elsewhere), key: publicKey), "even signed, another host")
        XCTAssertNil(BrosFeed.release(from: try feed(zip: "http://github.com/MEPoss/bros/releases/download/v1.0.9/Bros.zip"),
                                      key: publicKey), "not over http")
        XCTAssertNil(BrosFeed.release(from: try feed(zip: "https://github.com/someone/else/releases/download/v1/Bros.zip"),
                                      key: publicKey), "another repository")
        XCTAssertNil(BrosFeed.release(from: try feed(dmg: "https://github.com/MEPoss/bros/archive/main.zip"), key: publicKey))
        XCTAssertTrue(BrosFeed.isOurs(URL(string: zip)!))
        XCTAssertFalse(BrosFeed.isOurs(URL(string: zip + "?x=1")!))
    }

    func testTheKeyInTheAppIsAValidPublicKey() {
        let raw = Data(base64Encoded: BrosFeed.publicKey)
        XCTAssertEqual(raw?.count, 32)
        XCTAssertNotNil(raw.flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) })
        XCTAssertEqual(BrosFeed.feed.host, "github.com")
    }
}
