import CryptoKit
import Foundation

// Eigenständige Prüfung des CI-Verifizierers; die Signaturen entstehen unabhängig
// vom Produktionscode. Keine Schlüsselbundzugriffe und keine echten Musikdateien.
let verifier = CommandLine.arguments[1]
let root = URL(fileURLWithPath: CommandLine.arguments[2])
let key = Curve25519.Signing.PrivateKey()
let archive = Data("synthetic update archive".utf8)
let archiveURL = root.appendingPathComponent("update.dmg")
let publicKeyURL = root.appendingPathComponent("public-key.txt")
let feedURL = root.appendingPathComponent("appcast.xml")
try archive.write(to: archiveURL)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: publicKeyURL, atomically: true, encoding: .utf8)
let download = "https://example.invalid/Vicious%20SID%20Player.dmg"
let archiveSignature = try key.signature(for: archive).base64EncodedString()
let xml = """
<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><title>Änderungen</title><item><sparkle:version>1.9.26</sparkle:version><enclosure url="\(download)" length="\(archive.count)" sparkle:edSignature="\(archiveSignature)" /></item></channel></rss>
"""

func signed(_ content: String) throws -> String {
    let data = Data(content.utf8)
    let signature = try key.signature(for: data).base64EncodedString()
    return content + "<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(data.count)\n-->\n"
}

var count = 0
func check(_ name: String, _ feed: String, succeeds: Bool) throws {
    try feed.write(to: feedURL, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: verifier)
    process.arguments = [feedURL.path, publicKeyURL.path, archiveURL.path, "1.9.26", download]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let message = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard (process.terminationStatus == 0) == succeeds else {
        fatalError("\(name): \(String(decoding: message, as: UTF8.self))")
    }
    count += 1
}

let valid = try signed(xml)
try check("Signierter Unicode-Feed ohne Umbruch vor Signatur", valid, succeeds: true)
try check("Unsigned feed", xml, succeeds: false)
try check("Manipulierter Feed", valid.replacingOccurrences(of: "Änderungen", with: "Manipuliert"), succeeds: false)
try check("Nachgestellter Inhalt", valid + "<item/>", succeeds: false)
try check("Falsche signierte Länge", valid.replacingOccurrences(of: "length: \(Data(xml.utf8).count)", with: "length: 1"), succeeds: false)
try check("Falsche Version", signed(xml.replacingOccurrences(of: "1.9.26", with: "1.9.25")), succeeds: false)
try check("Falsche Download-URL", signed(xml.replacingOccurrences(of: "example.invalid", with: "other.invalid")), succeeds: false)
try check("Falsche Archivlänge", signed(xml.replacingOccurrences(of: "length=\"\(archive.count)\"", with: "length=\"1\"")), succeeds: false)
let secondItem = "<item><sparkle:version>1.9.25</sparkle:version></item>"
try check("Mehrere Updates", signed(xml.replacingOccurrences(of: "</channel>", with: secondItem + "</channel>")), succeeds: false)
var tamperedArchive = archive
tamperedArchive[0] ^= 1
try tamperedArchive.write(to: archiveURL)
try check("Manipuliertes Archiv gleicher Länge", valid, succeeds: false)
try archive.write(to: archiveURL)
try Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    .write(to: publicKeyURL, atomically: true, encoding: .utf8)
try check("Falscher CI-Signierschlüssel", valid, succeeds: false)
print("\(count) Appcast-Prüfungen bestanden.")
