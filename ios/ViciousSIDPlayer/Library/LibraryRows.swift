import SwiftUI
import ViciousSIDPlayerCore

// Zeilenmodell und Zeilenansichten des Bibliotheks-Browsers.
//
// Warum der Ordnerbaum flachgeklopft wird, statt Ansichten ineinander zu
// schachteln: SwiftUI-Ansichten koennen sich nicht ohne Weiteres selbst
// enthalten — der Typ einer solchen View waere unendlich tief und der Compiler
// laeuft sich daran fest. Der uebliche Ausweg ist Typloeschung mit `AnyView`,
// die aber jede Zeile teuer macht.
//
// Deshalb dieser Weg: der Baum wird vor dem Zeichnen in eine flache Liste von
// Zeilen uebersetzt, jede mit ihrer Einrücktiefe. Das kostet nur einen Durchlauf
// durch die AUFGEKLAPPTEN Ordner (zugeklappte werden uebersprungen), und die
// Liste selbst laedt ihre Zeilen ohnehin nur bei Bedarf. Bei einer
// HVSC-Sammlung mit zehntausenden Dateien ist das der Unterschied zwischen
// „laeuft" und „ruckelt".
enum LibraryRowItem: Identifiable, Hashable {
    case folder(LibraryFolderRow)
    case track(LibraryTrackRow)

    var id: String {
        switch self {
        case .folder(let row): return "d:" + row.id
        case .track(let row): return "f:" + row.track.id
        }
    }
}

/// Eine Ordnerzeile.
struct LibraryFolderRow: Hashable {
    /// Relativer Pfad des Ordners — zugleich der Schluessel fuer „aufgeklappt".
    let id: String
    let name: String
    /// Verschachtelungstiefe, steuert nur den Einzug.
    let depth: Int
    /// Titel in diesem Ordner einschliesslich aller Unterordner.
    let trackCount: Int
    let isExpanded: Bool
}

/// Eine Titelzeile.
struct LibraryTrackRow: Hashable {
    let track: LibraryTrack
    let depth: Int
}

enum LibraryTree {
    /// Uebersetzt den Ordnerbaum in die sichtbaren Zeilen.
    ///
    /// Die eigentliche Rechnung steht seit 2026-08-23 im Core
    /// (`LibraryOutline`) und ist dort getestet; hier bleibt nur die
    /// Uebersetzung in die Zeilentypen dieser Ansicht. Vorher stand dieselbe
    /// Rekursion ein zweites Mal in diesem Ziel — und war aus XCTest gar nicht
    /// erreichbar.
    ///
    /// - Parameters:
    ///   - folder: Der Knoten, dessen Inhalt aufgelistet wird (die Wurzel selbst
    ///     bekommt keine eigene Zeile).
    ///   - expanded: Pfade der aufgeklappten Ordner.
    ///   - trackIndex: Nachschlagetabelle Pfad -> Titel.
    static func rows(of folder: MusicLibraryFolder,
                     expanded: Set<String>,
                     trackIndex: [String: LibraryTrack]) -> [LibraryRowItem] {
        LibraryOutline.rows(of: folder, expanded: expanded).compactMap { item in
            switch item {
            case .folder(let row):
                return .folder(LibraryFolderRow(id: row.path,
                                                name: row.name,
                                                depth: row.depth,
                                                trackCount: row.trackCount,
                                                isExpanded: row.isExpanded))
            case .track(let row):
                // Ein Titel, den die Liste (noch) nicht kennt, faellt weg —
                // antippen liesse er sich ohnehin nicht.
                guard let track = trackIndex[row.relativePath] else { return nil }
                return .track(LibraryTrackRow(track: track, depth: row.depth))
            }
        }
    }

    /// Sammelt die Pfade aller Ordner des Baums — Grundlage fuer „alle
    /// aufklappen".
    static func allFolderIDs(of folder: MusicLibraryFolder) -> Set<String> {
        LibraryOutline.allFolderPaths(of: folder)
    }
}

// MARK: - Zeilenansichten

/// Ordnerzeile mit Aufklapp-Pfeil und Titelzahl.
struct FolderRowView: View {
    let row: LibraryFolderRow
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: row.isExpanded ? "folder.fill" : "folder")
                    .foregroundStyle(.tint)
                Text(row.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // Reine Zahl, deshalb ohne Uebersetzung.
                Text(row.trackCount.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Ordner \(row.name)"))
        // Der Auf-/Zu-Zustand gehoert in den Wert: VoiceOver-Nutzer muessen vor
        // dem Aktivieren wissen, ob der Ordner sich oeffnet oder schliesst.
        .accessibilityValue(Text(row.isExpanded
                                 ? "aufgeklappt, \(row.trackCount) Titel"
                                 : "zugeklappt, \(row.trackCount) Titel"))
    }
}

/// Titelzeile. Antippen laedt und startet den Titel.
struct TrackRowView: View {
    let row: LibraryTrackRow
    let isCurrent: Bool
    let isFavorite: Bool
    /// In der Suchergebnisliste steht der Ordner unter dem Namen, im Baum nicht —
    /// dort ergibt er sich aus der Verschachtelung.
    let showsFolderPath: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "play.circle.fill" : "music.note")
                    .font(.footnote)
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.track.name)
                        .lineLimit(1)
                    if showsFolderPath, !row.track.folderPath.isEmpty {
                        Text(row.track.folderPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 8)
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                        .accessibilityLabel(Text("Favorit"))
                }
            }
            .padding(.leading, CGFloat(row.depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(isCurrent ? .semibold : .regular)
    }
}
