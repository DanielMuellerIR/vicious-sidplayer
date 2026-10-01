import Foundation

// STIL — die "SID Tune Information List" der HVSC.
//
// Was das ist: Eine SID-Datei enthaelt im Kopf nur Titel, Autor und Jahr. Alles
// Weitere — welche Vorlage ein Tune covert, wer die Melodie geschrieben hat,
// Anmerkungen der Kuratoren zu einzelnen Subtunes — pflegt die HVSC von Hand in
// einer einzigen grossen Textdatei: `DOCUMENTS/STIL.txt`. Diese Datei gehoert
// dem HVSC-Projekt und wird hier bewusst NICHT mitgeliefert; die App liest die
// Fassung, die der Nutzer selbst neben seiner Sammlung liegen hat.
//
// Aufbau der Datei (verkuerzt):
//
//     (Kopftext, viele Zeilen, keine davon beginnt mit "/")
//
//     /MUSICIANS/H/Hubbard_Rob/
//     COMMENT: Gilt fuer alle Dateien in diesem Ordner.
//
//     /MUSICIANS/H/Hubbard_Rob/Commando.sid
//     COMMENT: Eine Anmerkung zur ganzen Datei.
//     (#2)
//       TITLE: Titel des zweiten Subtunes
//       ARTIST: wer die Vorlage geschrieben hat
//
// Regeln, die der Parser daraus ableitet:
//  - Eine Zeile, die in Spalte 1 mit "/" beginnt, eroeffnet einen neuen Eintrag.
//    Endet sie auf "/", gilt der Eintrag fuer einen ganzen ORDNER.
//  - "(#n)" schaltet auf den n-ten Subtune um; davor gelesene Felder gelten fuer
//    die ganze Datei.
//  - "LABEL: Wert" beginnt ein Feld, eingerueckte Folgezeilen gehoeren dazu.
//    Die HVSC bricht ihre Absaetze hart bei rund 78 Zeichen um; deshalb werden
//    Folgezeilen mit einem Leerzeichen angehaengt und nicht als eigene Zeilen
//    behalten — sonst stuenden in der App lauter kurze Stummelzeilen.

/// Ein einzelnes Feld eines STIL-Eintrags, etwa `COMMENT` oder `TITLE`.
public struct STILField: Sendable, Equatable {
    /// Das Schlagwort ohne Doppelpunkt, in Grossbuchstaben wie in der Datei.
    public let label: String
    /// Der Wert, mehrzeilige Absaetze bereits zusammengefuegt.
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Alles, was die STIL zu einem Pfad weiss.
public struct STILEntry: Sendable, Equatable {
    /// Der Pfad, wie er in der Datei steht (mit fuehrendem "/").
    public let path: String
    /// Felder, die fuer die ganze Datei gelten.
    public let global: [STILField]
    /// Felder je Subtune. Schluessel ist die Subtune-Nummer aus "(#n)", also
    /// EINSBASIERT — genau wie in der Datei und in der Oberflaeche.
    public let subtunes: [Int: [STILField]]

    public init(path: String,
                global: [STILField] = [],
                subtunes: [Int: [STILField]] = [:]) {
        self.path = path
        self.global = global
        self.subtunes = subtunes
    }

    public var isEmpty: Bool { global.isEmpty && subtunes.isEmpty }
}

/// Was die App zu einem konkreten Titel und Subtune anzeigt.
public struct STILInfo: Sendable, Equatable {
    /// Anmerkungen zum Ordner (gelten fuer alle Titel darin).
    public let folder: [STILField]
    /// Anmerkungen zur Datei als Ganzes.
    public let file: [STILField]
    /// Anmerkungen zum gerade laufenden Subtune.
    public let subtune: [STILField]

    public init(folder: [STILField] = [], file: [STILField] = [], subtune: [STILField] = []) {
        self.folder = folder
        self.file = file
        self.subtune = subtune
    }

    public var isEmpty: Bool { folder.isEmpty && file.isEmpty && subtune.isEmpty }

    /// Alle Felder in Anzeigereihenfolge: erst der Subtune (am genauesten), dann
    /// die Datei, zuletzt der Ordner (am allgemeinsten).
    public var orderedFields: [STILField] {
        subtune + file + folder
    }
}

/// Die geparste STIL-Datei.
public struct STILDatabase: Sendable {

    /// Eintraege zu einzelnen Dateien, Schluessel kleingeschrieben.
    private let files: [String: STILEntry]
    /// Eintraege zu ganzen Ordnern, Schluessel kleingeschrieben MIT Schlussschraegstrich.
    private let folders: [String: STILEntry]
    /// Dateiname (kleingeschrieben) -> alle Pfade, die so heissen.
    ///
    /// Damit findet `resolvedPath` einen Titel auch dann, wenn er nicht mehr an
    /// seinem HVSC-Platz liegt. Gebaut wird der Index einmal beim Parsen: Eine
    /// Suche ueber alle 50.000 Schluessel bei jedem Bildaufbau waere zu teuer.
    private let pathsByFileName: [String: [String]]

    /// Anzahl der Datei-Eintraege — was der Nutzer als "so viele Titel kennt die
    /// Datenbank" versteht.
    public var count: Int { files.count }

    /// Anzahl der Ordner-Eintraege.
    public var folderCount: Int { folders.count }

    public var isEmpty: Bool { files.isEmpty && folders.isEmpty }

    public init(files: [String: STILEntry] = [:], folders: [String: STILEntry] = [:]) {
        self.files = files
        self.folders = folders
        var byName: [String: [String]] = [:]
        for key in files.keys {
            guard let slash = key.lastIndex(of: "/") else { continue }
            let name = String(key[key.index(after: slash)...])
            byName[name, default: []].append(key)
        }
        self.pathsByFileName = byName
    }

    // MARK: - Laden

    /// Laedt und parst eine STIL.txt.
    ///
    /// Die HVSC liefert die Datei nicht in UTF-8 aus, sondern in einer
    /// 8-Bit-Kodierung (ISO-8859-1). Deshalb wird nach UTF-8 auf Latin-1
    /// zurueckgefallen, statt mit einem Fehler abzubrechen: Ein einzelner
    /// Umlaut in einem Kommentar darf nicht die ganze Datenbank kosten.
    public static func load(url: URL) throws -> STILDatabase {
        let data = try Data(contentsOf: url)
        return parse(text: decode(data))
    }

    /// Variante fuer verwaltete Hintergrund-Tasks: reagiert auch waehrend des
    /// Parsens regelmaessig auf Abbruch. Die echte STIL.txt hat ueber 200.000
    /// Zeilen, das Parsen dauert also messbar.
    public static func loadCancellable(url: URL) throws -> STILDatabase {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        return try parse(text: decode(data), cancellationCheck: { try Task.checkCancellation() })
    }

    static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        // Foundation unter Linux kann .isoLatin1 ablehnen. ISO-8859-1 bildet
        // jedes Byte direkt auf denselben Unicode-Codepunkt ab; diese Abbildung
        // funktioniert unabhängig von den verfügbaren Foundation-Decodern.
        return String(String.UnicodeScalarView(data.map { UnicodeScalar(UInt32($0))! }))
    }

    // MARK: - Parser

    /// Reine Funktion ohne Dateisystem — so ist der Parser headless testbar.
    public static func parse(text: String) -> STILDatabase {
        (try? parse(text: text, cancellationCheck: {})) ?? STILDatabase()
    }

    static func parse(text: String,
                      cancellationCheck: () throws -> Void) throws -> STILDatabase {
        var files: [String: STILEntry] = [:]
        var folders: [String: STILEntry] = [:]

        // Der gerade offene Eintrag.
        var path: String? = nil
        var global: [STILField] = []
        var subtunes: [Int: [STILField]] = [:]
        // In welchem Abschnitt stehen wir: nil = noch vor dem ersten "(#n)".
        var currentSubtune: Int? = nil
        // Das Feld, an das eingerueckte Folgezeilen angehaengt werden.
        var openLabel: String? = nil
        var openValue = ""

        func closeField() {
            guard let label = openLabel else { return }
            let field = STILField(label: label,
                                  value: openValue.trimmingCharacters(in: .whitespaces))
            if let sub = currentSubtune {
                subtunes[sub, default: []].append(field)
            } else {
                global.append(field)
            }
            openLabel = nil
            openValue = ""
        }

        func closeEntry() {
            closeField()
            defer {
                path = nil
                global = []
                subtunes = [:]
                currentSubtune = nil
            }
            guard let path else { return }
            let entry = STILEntry(path: path, global: global, subtunes: subtunes)
            guard !entry.isEmpty else { return }
            let key = Self.normalizedKey(path)
            if path.hasSuffix("/") {
                folders[key] = entry
            } else {
                files[key] = entry
            }
        }

        // An JEDEM Zeilenumbruch trennen, nicht nur an "\n": Die HVSC liefert
        // ihre Textdateien mit Windows-Zeilenenden aus, und in Swift ist "\r\n"
        // EIN Character. `split(separator: "\n")` faende darin gar keine Zeilen.
        // Leere Zeilen bleiben erhalten, weil sie einen Absatz beenden.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        for (index, rawLine) in lines.enumerated() {
            if index % 4096 == 0 { try cancellationCheck() }
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Eine Leerzeile beendet den Absatz, nicht den Eintrag: Der
                // laeuft bis zur naechsten Pfadzeile weiter.
                closeField()
                continue
            }

            // Eine Pfadzeile beginnt in Spalte 1 mit "/". Eingerueckte Zeilen
            // sind Fortsetzungen und duerfen deshalb auch mit "/" anfangen.
            if line.hasPrefix("/") {
                closeEntry()
                path = trimmed
                continue
            }

            // Vor dem ersten Eintrag steht der Kopftext der Datei — verwerfen.
            guard path != nil else { continue }

            if let subtune = Self.subtuneNumber(trimmed) {
                closeField()
                currentSubtune = subtune
                continue
            }

            if let (label, value) = Self.field(trimmed) {
                closeField()
                openLabel = label
                openValue = value
                continue
            }

            // Fortsetzung des laufenden Feldes. Die HVSC bricht Absaetze hart
            // um; mit einem Leerzeichen angehaengt ergibt das wieder Fliesstext.
            if openLabel != nil {
                openValue += openValue.isEmpty ? trimmed : " " + trimmed
            }
        }
        closeEntry()

        return STILDatabase(files: files, folders: folders)
    }

    /// "(#3)" -> 3. Alles andere -> nil.
    static func subtuneNumber(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("(#"), trimmed.hasSuffix(")") else { return nil }
        let digits = trimmed.dropFirst(2).dropLast()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// "COMMENT: text" -> ("COMMENT", "text").
    ///
    /// Als Schlagwort gilt nur, was VOR dem ersten Doppelpunkt steht und dabei
    /// aus Grossbuchstaben besteht. Ohne diese Bedingung waere jede Textzeile
    /// mit Doppelpunkt ("Siehe auch: ...") ein neues Feld.
    static func field(_ trimmed: String) -> (String, String)? {
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let label = String(trimmed[trimmed.startIndex..<colon])
        guard !label.isEmpty, label.count <= 16 else { return nil }
        guard label.allSatisfy({ $0.isUppercase || $0 == " " || $0 == "-" }) else { return nil }
        let value = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (label.trimmingCharacters(in: .whitespaces), value)
    }

    // MARK: - Abfrage

    /// Der Eintrag zu einem HVSC-Pfad wie "/MUSICIANS/H/Hubbard_Rob/Commando.sid".
    public func entry(forHVSCPath path: String) -> STILEntry? {
        files[Self.normalizedKey(path)]
    }

    /// Der Eintrag zum ORDNER eines HVSC-Pfades.
    public func folderEntry(forHVSCPath path: String) -> STILEntry? {
        let key = Self.normalizedKey(path)
        guard let slash = key.lastIndex(of: "/") else { return nil }
        return folders[String(key[key.startIndex...slash])]
    }

    /// Was zu einem Titel und einem Subtune anzuzeigen ist.
    ///
    /// - Parameter subtune: NULLBASIERT wie im Player; die Datei zaehlt ab 1.
    public func info(forHVSCPath path: String, subtune: Int) -> STILInfo {
        let entry = entry(forHVSCPath: path)
        let folder = folderEntry(forHVSCPath: path)
        return STILInfo(folder: folder?.global ?? [],
                        file: entry?.global ?? [],
                        subtune: entry?.subtunes[subtune + 1] ?? [])
    }

    /// Der Eintrag zu einem Pfad, dessen ENDE bekannt ist.
    ///
    /// Wozu das noetig ist: Viele Sammlungen sind aus der HVSC herauskopiert.
    /// Ein Titel steht dann unter "Hubbard_Rob/Commando.sid" statt unter seinem
    /// vollen HVSC-Pfad, und der exakte Schluessel trifft nicht mehr. Gesucht
    /// wird deshalb nach einem Eintrag, dessen Pfad auf genau diese Komponenten
    /// endet — aber NUR, wenn es genau einen gibt. In der HVSC heissen dutzende
    /// Dateien "Commando.sid"; eine falsch zugeordnete Anmerkung waere
    /// schlechter als gar keine.
    public func path(matchingSuffix relativePath: String) -> String? {
        let key = Self.normalizedKey(relativePath)
        let components = key.split(separator: "/").map(String.init)
        guard let name = components.last, let candidates = pathsByFileName[name] else { return nil }

        // Vom laengsten Ende zum kuerzesten: "Hubbard_Rob/Commando.sid" ist
        // eindeutiger als "Commando.sid". Genommen wird das erste Ende, auf das
        // GENAU EIN Eintrag passt. Bleiben mehrere uebrig, wird nichts
        // zugeordnet — in der HVSC heissen dutzende Dateien gleich, und eine
        // falsche Anmerkung ist schlechter als keine.
        for length in stride(from: components.count, through: 1, by: -1) {
            let suffix = "/" + components.suffix(length).joined(separator: "/")
            let matches = candidates.filter { $0.hasSuffix(suffix) }
            if matches.count == 1 { return matches[0] }
        }
        return nil
    }

    /// Unter welchem Schluessel die STIL diesen Titel kennt — oder `nil`.
    ///
    /// Zwei Wege, in dieser Reihenfolge:
    ///  1. Der volle Pfad relativ zur HVSC-Wurzel. Das ist der sichere Fall und
    ///     gilt, solange die Sammlung die HVSC selbst ist.
    ///  2. Ein eindeutiges Pfadende (siehe `path(matchingSuffix:)`) fuer
    ///     Sammlungen, die aus der HVSC herauskopiert wurden. Auf iOS ist das
    ///     der Normalfall, weil die Bibliothek dort immer in `Documents/` liegt.
    ///
    /// - Parameters:
    ///   - fileURL: die Datei auf der Platte; `nil`, wenn nur der relative Pfad
    ///     bekannt ist.
    ///   - hvscRoot: Wurzel der HVSC (der Ordner ueber `DOCUMENTS/`); `nil`,
    ///     wenn sie nicht bekannt ist.
    ///   - relativePath: der Pfad des Titels in der Bibliothek des Nutzers.
    public func resolvedPath(forFileURL fileURL: URL?,
                             hvscRoot: URL?,
                             relativePath: String?) -> String? {
        if let fileURL, let hvscRoot,
           let exact = STILDatabase.hvscPath(for: fileURL, root: hvscRoot),
           files[Self.normalizedKey(exact)] != nil {
            return exact
        }
        if let relativePath, let matched = path(matchingSuffix: relativePath) {
            return matched
        }
        return nil
    }

    /// Vergleichbar machen: Gross-/Kleinschreibung egal, fuehrender Schraegstrich
    /// erzwungen, Rueckwaertsschraegstriche von Windows-Pfaden gedreht.
    static func normalizedKey(_ path: String) -> String {
        var key = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        if !key.hasPrefix("/") { key = "/" + key }
        return key
    }

    // MARK: - Finden der Datei

    /// Sucht `DOCUMENTS/STIL.txt` im Ordner selbst und in bis zu drei
    /// Elternebenen — dasselbe Muster wie beim Auto-Fund der Songlaengen, damit
    /// beides gemeinsam gefunden wird, wenn die Sammlung eine HVSC ist.
    public static func autodetect(nearFolder folder: URL, fm: FileManager = .default) -> URL? {
        var dir = folder
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("DOCUMENTS/STIL.txt")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Die HVSC-Wurzel zu einer gefundenen STIL-Datei: Sie liegt in `DOCUMENTS/`
    /// direkt unter der Wurzel.
    ///
    /// Diese Wurzel ist der Schluessel zur ganzen Zuordnung: Die STIL kennt ihre
    /// Titel unter Pfaden wie "/MUSICIANS/H/Hubbard_Rob/Commando.sid", und nur
    /// relativ zur HVSC-Wurzel laesst sich eine Datei auf der Platte in genau
    /// diesen Pfad umrechnen.
    public static func hvscRoot(forSTILFile url: URL) -> URL {
        url.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Rechnet eine Datei auf der Platte in ihren HVSC-Pfad um.
    ///
    /// - Returns: `nil`, wenn die Datei gar nicht unterhalb der Wurzel liegt —
    ///   dann kennt die STIL sie nicht, und Raten waere schlechter als nichts.
    public static func hvscPath(for fileURL: URL, root: URL) -> String? {
        guard let relative = LibraryPath.relativePath(
            of: fileURL,
            underRootComponents: LibraryPath.normalizedComponents(root)
        ) else { return nil }
        return "/" + relative
    }
}
