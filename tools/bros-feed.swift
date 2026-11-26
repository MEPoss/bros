// The signing half of Bros's updater (Sources/Search/BrosFeed.swift reads it).
//
//   swift tools/bros-feed.swift keygen KEYFILE
//       makes an Ed25519 key, keeps the private half in KEYFILE (mode 600) and
//       prints the public half for Updater.brosPublicKey.
//   swift tools/bros-feed.swift public KEYFILE
//   swift tools/bros-feed.swift sign KEYFILE VERSION BUILD URL SHA256 DMG DMGSHA256 NOTES
//       prints appcast.json, signed over the same fields BrosFeed.message joins.
import CryptoKit
import Foundation

let args = CommandLine.arguments.dropFirst()
func fail(_ text: String) -> Never { FileHandle.standardError.write(Data((text + "\n").utf8)); exit(1) }
guard let command = args.first else { fail("keygen | public | sign") }
let rest = Array(args.dropFirst())

func key(at path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("cannot read the key in \(path)") }
    return key
}

switch command {
case "keygen":
    guard let path = rest.first else { fail("keygen KEYFILE") }
    if FileManager.default.fileExists(atPath: path) { fail("\(path) exists; not overwriting a key") }
    let made = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath: path, contents: Data(made.rawRepresentation.base64EncodedString().utf8),
                                   attributes: [.posixPermissions: 0o600])
    print(made.publicKey.rawRepresentation.base64EncodedString())
case "public":
    guard let path = rest.first else { fail("public KEYFILE") }
    print(key(at: path).publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard rest.count == 8, let build = Int(rest[2]) else { fail("sign KEYFILE VERSION BUILD URL SHA256 DMG DMGSHA256 NOTES") }
    let (version, url, sha, dmg, dmgSha, notes) = (rest[1], rest[3], rest[4], rest[5], rest[6], rest[7])
    let message = ["bros-update", version, String(build), url, sha, dmg, dmgSha].joined(separator: "\n")
    let signature = try key(at: rest[0]).signature(for: Data(message.utf8)).base64EncodedString()
    let json: [String: Any] = ["version": version, "build": build, "url": url, "sha256": sha, "dmg": dmg,
                               "dmgSha256": dmgSha, "notes": notes, "signature": signature]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
default:
    fail("keygen | public | sign")
}
