import Foundation

// Fernsteuerung der Mac-App ueber ein URL-Schema.
//
// Wozu: Ein Skript, ein Kurzbefehl oder ein Agent soll die laufende App steuern
// koennen, ohne dass jemand ins Fenster klickt. `open vicioussid://next` reicht
// dafuer — kein Netzwerkdienst, kein offener Port, keine Rechteverwaltung.
//
// Warum bewusst KEIN HTTP-Server: Der macht die App von aussen erreichbar und
// verlangt Bindeadresse, Zugangsschutz und Pflege. Ein URL-Schema wird
// ausschliesslich lokal von LaunchServices zugestellt; das ist der deutlich
// kleinere Angriffsflaeche.
//
// Was das Schema trotzdem NICHT kann, und zwar mit Absicht: Ein URL-Schema kann
// jede Webseite ausloesen. Deshalb gibt es hier nur Wiedergabesteuerung und die
// Auswahl eines Titels AUS DER BIBLIOTHEK. Kein Zugriff auf beliebige Dateien,
// keine Einstellungen, kein Export, kein Beenden.

/// Ein Befehl, den die App ueber ihr URL-Schema entgegennimmt.
public enum RemoteCommand: Equatable, Sendable {
    case play
    case pause
    case playPause
    case stop
    case next
    case previous
    /// An eine Position springen (Sekunden ab Anfang).
    case seek(seconds: Double)
    /// Subtune waehlen — NULLBASIERT wie im Player.
    case subtune(index: Int)
    /// Titel aus der Bibliothek waehlen, ueber seinen Pfad UNTERHALB des
    /// Autoplay-Ordners (die stabile Titel-ID).
    case track(id: String)

    /// Das Schema, das die App bei LaunchServices anmeldet.
    public static let urlScheme = "vicioussid"

    /// Was mit einem `track`-Befehl geschehen soll.
    public enum TrackResolution: Equatable, Sendable {
        /// Titel steht in der Liste — diesen Index waehlen.
        case select(index: Int)
        /// Noch nicht auffindbar, aber ein Bibliotheks-Scan laeuft gerade:
        /// zuruecklegen und nach dem Scan erneut versuchen.
        case deferUntilScanFinished
        /// Endgueltig unbekannt — verwerfen statt raten.
        case unknown
    }

    /// Entscheidet ohne Oberflaeche, was mit einem `track`-Befehl passiert.
    ///
    /// Beim Kaltstart ohne gespeicherten Index ist die Playlist noch leer,
    /// waehrend der erste Bibliotheks-Scan laeuft. Frueher wurde der Befehl in
    /// genau diesem Moment verworfen, und `vicioussid://track?path=...` waehlte
    /// beim Kaltstart nichts aus, obwohl die Datei im Autoplay-Ordner lag
    /// (Review-Fund 2026-08-25).
    public static func resolveTrack(index: Int?,
                                    isScanningLibrary: Bool) -> TrackResolution {
        if let index { return .select(index: index) }
        return isScanningLibrary ? .deferUntilScanFinished : .unknown
    }

    /// Groesste erlaubte Sprungweite. Laenger als ein Tag ist kein Musikstueck,
    /// und ohne Obergrenze landete eine absurde Zahl im Positionsregler.
    public static let maximumSeekSeconds: Double = 24 * 60 * 60

    /// Hoechste Subtune-Nummer. Das PSID-Format haelt die Anzahl in einem Byte.
    public static let maximumSubtuneIndex = 255

    /// Liest einen Befehl aus einer URL — oder `nil`, wenn sie nicht passt.
    ///
    /// Streng absichtlich: Alles, was nicht genau einem bekannten Befehl mit
    /// gueltigem Wert entspricht, wird verworfen. Eine halb verstandene URL
    /// auszufuehren waere schlimmer, als sie zu ignorieren.
    public static func parse(_ url: URL) -> RemoteCommand? {
        guard url.scheme?.lowercased() == urlScheme else { return nil }

        // "vicioussid://next" -> host "next"; "vicioussid:next" -> path "next".
        // Beide Schreibweisen kommen in freier Wildbahn vor.
        let name = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .lowercased()
        let query = queryItems(of: url)

        switch name {
        case "play": return .play
        case "pause": return .pause
        case "playpause", "toggle": return .playPause
        case "stop": return .stop
        case "next": return .next
        case "previous", "prev": return .previous

        case "seek":
            guard let raw = query["seconds"], let seconds = Double(raw),
                  seconds.isFinite, seconds >= 0, seconds <= maximumSeekSeconds else { return nil }
            return .seek(seconds: seconds)

        case "subtune":
            guard let raw = query["index"], let index = Int(raw),
                  index >= 0, index <= maximumSubtuneIndex else { return nil }
            return .subtune(index: index)

        case "track":
            guard let raw = query["path"], let id = sanitizedTrackID(raw) else { return nil }
            return .track(id: id)

        default:
            return nil
        }
    }

    /// Prueft den Titelpfad, bevor er die App erreicht.
    ///
    /// Erlaubt ist ausschliesslich ein Pfad UNTERHALB des Autoplay-Ordners.
    /// Alles, womit man dort herauskaeme, wird verworfen: absolute Pfade,
    /// "..", ein fuehrendes "~" und leere Angaben. Damit kann eine Webseite die
    /// App hoechstens dazu bringen, Musik zu spielen, die der Nutzer ohnehin in
    /// seiner Sammlung hat.
    static func sanitizedTrackID(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"), !trimmed.contains("\\") else { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(""), !parts.contains("..") else { return nil }
        // Nur SID-Dateien: Der Player kann ohnehin nichts anderes, und so wird
        // aus dem Schema kein Weg, beliebige Dateien anzufassen.
        guard SidFileType.matches(URL(fileURLWithPath: trimmed)) else { return nil }
        return trimmed
    }

    private static func queryItems(of url: URL) -> [String: String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in items where item.value != nil {
            // Der erste Wert gewinnt: "?index=1&index=9" ist keine gueltige
            // Angabe, und die zweite still zu nehmen waere ueberraschend.
            if result[item.name.lowercased()] == nil {
                result[item.name.lowercased()] = item.value
            }
        }
        return result
    }
}
