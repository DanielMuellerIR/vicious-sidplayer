import Foundation
import CryptoKit

// Songlaengen-Aufloesung, Teil A: die kuratierte HVSC-Datenbank.
//
// Hintergrund: Eine SID-Datei enthaelt KEINE Spieldauer — sie ist C64-Maschinen-
// code, der endlos laufen kann (die meisten Tunes loopen). Die HVSC pflegt daher
// eine von Menschen kuratierte Datenbank "Songlengths.md5": pro Datei (identifiziert
// ueber den MD5-Hash des kompletten Datei-Inhalts) eine Laenge je Subtune.
// Format (INI-artig):
//   [Database]
//   ; /MUSICIANS/T/Tel_Jeroen/Cybernoid.sid
//   c2a01b2e5a55278e6b37b1d63a11e19c=2:51 1:07 0:45
// Laengen als M:SS oder M:SS.mmm, optional mit Attribut in Klammern (z.B. "(G)").
public struct SonglengthDB: Sendable {
    // md5 (lowercase hex) -> Sekunden je Subtune (Index 0 = Subtune 1)
    private let entries: [String: [Double]]

    public var count: Int { entries.count }

    public init(entries: [String: [Double]]) {
        self.entries = entries
    }

    // Laedt und parst eine Songlengths.md5-Datei (HVSC: DOCUMENTS/Songlengths.md5).
    public static func load(url: URL) throws -> SonglengthDB {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text: text)
    }

    // Parser separat und pur — headless testbar ohne Dateisystem.
    public static func parse(text: String) -> SonglengthDB {
        var entries: [String: [Double]] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Kommentare (Datei-Pfade) und Sektions-Kopf ueberspringen.
            if trimmed.isEmpty || trimmed.hasPrefix(";") || trimmed.hasPrefix("[") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let md5 = trimmed[..<eq].lowercased()
            guard md5.count == 32 else { continue }
            // Rechte Seite: Laengen-Tokens, whitespace-getrennt.
            let lengths = trimmed[trimmed.index(after: eq)...]
                .split(separator: " ", omittingEmptySubsequences: true)
                .compactMap { parseLength(String($0)) }
            if !lengths.isEmpty {
                entries[md5] = lengths
            }
        }
        return SonglengthDB(entries: entries)
    }

    // Ein Laengen-Token "M:SS", "M:SS.mmm", optional mit "(Attr)"-Anhang.
    static func parseLength(_ token: String) -> Double? {
        // Attribut in Klammern abschneiden: "0:32(G)" -> "0:32"
        let core = token.split(separator: "(").first.map(String.init) ?? token
        let parts = core.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]),
              minutes >= 0, seconds >= 0 else { return nil }
        return minutes * 60.0 + seconds
    }

    // Laengen je Subtune fuer eine Datei (Lookup ueber den Datei-MD5), nil = unbekannt.
    public func lengths(forMD5 md5: String) -> [Double]? {
        return entries[md5.lowercased()]
    }

    // MD5-Hex des kompletten Datei-Inhalts — der Schluessel der HVSC-DB.
    public static func md5Hex(of data: Data) -> String {
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Auto-Fund der DB relativ zu einem Musik-Ordner: HVSC legt sie unter
    // <HVSC-Root>/DOCUMENTS/Songlengths.md5 ab. Geprueft werden der Ordner selbst
    // und bis zu 3 Eltern-Ebenen (Autoplay-Ordner kann z.B. MUSICIANS/ sein).
    public static func autodetect(nearFolder folder: URL, fm: FileManager = .default) -> URL? {
        var dir = folder
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("DOCUMENTS/Songlengths.md5")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
