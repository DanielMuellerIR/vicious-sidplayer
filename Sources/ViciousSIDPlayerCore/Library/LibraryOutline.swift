import Foundation

// Der Ordnerbaum als flache Liste sichtbarer Zeilen.
//
// Warum flach und nicht verschachtelt: SwiftUI-Ansichten koennen sich nicht
// ohne Weiteres selbst enthalten — der Typ einer solchen Ansicht waere unendlich
// tief, und der Compiler laeuft sich daran fest. Der uebliche Ausweg ist
// Typloeschung mit `AnyView`, die aber jede Zeile teuer macht.
//
// Deshalb dieser Weg: Vor dem Zeichnen wird der Baum in eine flache Liste von
// Zeilen uebersetzt, jede mit ihrer Einruecktiefe. Das kostet nur einen
// Durchlauf durch die AUFGEKLAPPTEN Ordner — zugeklappte werden gar nicht erst
// betreten. Bei einer HVSC-Sammlung mit ueber 50.000 Dateien ist das der
// Unterschied zwischen "laeuft" und "steht".
//
// Die Rechnung stand bis 2026-08-23 im iOS-App-Ziel und war damit aus den Tests
// nicht erreichbar. Hier im Core benutzen beide Apps dieselbe Fassung, und sie
// ist geprueft.

/// Eine Ordnerzeile des Baums.
public struct LibraryOutlineFolder: Sendable, Hashable {
    /// Relativer Pfad des Ordners — zugleich der Schluessel fuer "aufgeklappt".
    public let path: String
    public let name: String
    /// Verschachtelungstiefe; steuert nur den Einzug.
    public let depth: Int
    /// Titel in diesem Ordner einschliesslich aller Unterordner.
    public let trackCount: Int
    public let isExpanded: Bool

    public init(path: String, name: String, depth: Int, trackCount: Int, isExpanded: Bool) {
        self.path = path
        self.name = name
        self.depth = depth
        self.trackCount = trackCount
        self.isExpanded = isExpanded
    }
}

/// Eine Titelzeile des Baums.
public struct LibraryOutlineTrack: Sendable, Hashable {
    /// Relativer Pfad des Titels — die stabile ID, ueber die ihn Playlist und
    /// Favoriten kennen.
    public let relativePath: String
    /// Angezeigter Name (Dateiname ohne Endung).
    public let name: String
    public let depth: Int

    public init(relativePath: String, name: String, depth: Int) {
        self.relativePath = relativePath
        self.name = name
        self.depth = depth
    }
}

/// Eine sichtbare Zeile: entweder ein Ordner oder ein Titel.
public enum LibraryOutlineItem: Sendable, Hashable, Identifiable {
    case folder(LibraryOutlineFolder)
    case track(LibraryOutlineTrack)

    /// Eindeutig ueber beide Arten hinweg: Ein Ordner und eine Datei koennen
    /// denselben Pfad nicht haben, aber der Praefix macht es augenfaellig.
    public var id: String {
        switch self {
        case .folder(let row): return "d:" + row.path
        case .track(let row): return "f:" + row.relativePath
        }
    }

    public var depth: Int {
        switch self {
        case .folder(let row): return row.depth
        case .track(let row): return row.depth
        }
    }
}

public enum LibraryOutline {

    /// Uebersetzt den Ordnerbaum in die sichtbaren Zeilen.
    ///
    /// Sortiert wird natuerlich (`localizedStandardCompare`, also "Track2" vor
    /// "Track10") — genau wie die flache Titelliste. Der gespeicherte Index
    /// sortiert bewusst stur nach Zeichen, weil er reproduzierbar sein muss;
    /// wie die Liste dem Nutzer praesentiert wird, entscheidet erst diese Stelle.
    ///
    /// - Parameters:
    ///   - folder: Der Knoten, dessen INHALT aufgelistet wird. Die Wurzel selbst
    ///     bekommt keine eigene Zeile.
    ///   - depth: Einruecktiefe der direkten Kinder.
    ///   - expanded: Pfade der aufgeklappten Ordner.
    public static func rows(of folder: MusicLibraryFolder,
                            depth: Int = 0,
                            expanded: Set<String>) -> [LibraryOutlineItem] {
        var result: [LibraryOutlineItem] = []

        // Ordner zuerst, dann die Titel dieses Ordners — sonst verschwaenden
        // die Unterordner zwischen den Dateien.
        let subfolders = folder.subfolders.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        for subfolder in subfolders {
            let isExpanded = expanded.contains(subfolder.path)
            result.append(.folder(LibraryOutlineFolder(path: subfolder.path,
                                                       name: subfolder.name,
                                                       depth: depth,
                                                       trackCount: subfolder.totalEntryCount,
                                                       isExpanded: isExpanded)))
            // Zugeklappte Ordner werden gar nicht erst betreten.
            if isExpanded {
                result.append(contentsOf: rows(of: subfolder,
                                               depth: depth + 1,
                                               expanded: expanded))
            }
        }

        let entries = folder.entries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        for entry in entries {
            result.append(.track(LibraryOutlineTrack(relativePath: entry.relativePath,
                                                     name: entry.displayName,
                                                     depth: depth)))
        }
        return result
    }

    /// Alle Ordnerpfade des Baums — fuer "alles aufklappen".
    public static func allFolderPaths(of folder: MusicLibraryFolder) -> Set<String> {
        var result: Set<String> = []
        for subfolder in folder.subfolders {
            result.insert(subfolder.path)
            result.formUnion(allFolderPaths(of: subfolder))
        }
        return result
    }
}
