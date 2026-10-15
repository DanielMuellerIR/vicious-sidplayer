import CryptoKit
import Foundation

enum VerificationError: Error { case invalid(String) }

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw VerificationError.invalid(message) }
}

// Der Schlüssel stammt aus dem geprüften Release-Bundle, nicht aus dem
// Signierschlüssel: Ein falsch gesetztes CI-Secret muss hier scheitern.
func verify(feed: URL, publicKeyFile: URL, archive: URL, version: String, downloadURL: String) throws {
    let keyText = try String(contentsOf: publicKeyFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let keyData = Data(base64Encoded: keyText) else {
        throw VerificationError.invalid("Ungültiger öffentlicher Schlüssel")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let data = try Data(contentsOf: feed)
    // Sparkle hängt den Block unmittelbar an </rss> an, ohne Zeilenumbruch.
    guard let marker = data.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards),
          let block = String(data: data[marker.lowerBound...], encoding: .utf8) else {
        throw VerificationError.invalid("Feed-Signatur fehlt")
    }
    let pattern = #"\A<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*\z"#
    let regex = try NSRegularExpression(pattern: pattern)
    guard let match = regex.firstMatch(in: block, range: NSRange(block.startIndex..., in: block)),
          let signatureRange = Range(match.range(at: 1), in: block),
          let lengthRange = Range(match.range(at: 2), in: block),
          let signature = Data(base64Encoded: String(block[signatureRange])),
          let length = Int(block[lengthRange]) else {
        throw VerificationError.invalid("Ungültiger Feed-Signaturblock")
    }
    try require(length == marker.lowerBound && length > 0, "Signierte Länge umfasst nicht den vollständigen Feed")
    let content = data.prefix(length)
    try require(key.isValidSignature(signature, for: content), "Feed-Signatur passt nicht zu SUPublicEDKey")
    let xml = try XMLDocument(data: content, options: .nodeLoadExternalEntitiesNever)
    let items = try xml.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "Feed muss genau ein Vollupdate enthalten")
    let item = items[0]
    func value(_ path: String) throws -> String? {
        let nodes = try item.nodes(forXPath: path)
        try require(nodes.count == 1, "Fehlendes oder mehrdeutiges Feld: \(path)")
        return nodes[0].stringValue
    }
    try require(try value("sparkle:version") == version, "Bundle-Version stimmt nicht")
    try require(try value("enclosure/@url") == downloadURL, "Download-URL stimmt nicht")
    let archiveData = try Data(contentsOf: archive, options: .mappedIfSafe)
    try require(try value("enclosure/@length") == String(archiveData.count), "Archivlänge stimmt nicht")
    guard let archiveSignatureText = try value("enclosure/@sparkle:edSignature"),
          let archiveSignature = Data(base64Encoded: archiveSignatureText) else {
        throw VerificationError.invalid("Archivsignatur fehlt")
    }
    try require(key.isValidSignature(archiveSignature, for: archiveData), "Archivsignatur passt nicht zu SUPublicEDKey")
}

do {
    let args = CommandLine.arguments
    try require(args.count == 6, "Aufruf: verify-appcast.swift <Feed> <Public-Key-Datei> <DMG> <Version> <Download-URL>")
    try verify(feed: URL(fileURLWithPath: args[1]), publicKeyFile: URL(fileURLWithPath: args[2]),
               archive: URL(fileURLWithPath: args[3]), version: args[4], downloadURL: args[5])
    print("Feed, Archivsignatur, Version und Download-URL geprüft.")
} catch {
    FileHandle.standardError.write(Data("Appcast-Prüfung fehlgeschlagen: \(error)\n".utf8))
    exit(1)
}
