import Foundation
import ViciousSIDPlayerCore

// Ablage fuer die Bausteine, die Bibliothek und Wiedergabe brauchen, die aber
// nicht ins `AppModel` selbst gehoeren.
//
// WARUM DIESE DATEI ueberhaupt existiert:
// `AppModel+Library.swift` und `AppModel+Playback.swift` sind Swift-Extensions,
// und Extensions duerfen keine gespeicherten Eigenschaften hinzufuegen. Beide
// brauchen aber langlebigen Zustand — die geoeffnete Bibliothek, die beiden
// System-Controller, den Hintergrund-Timer. Diese Sachen liegen deshalb hier in
// einem eigenen Objekt, das ueber `model.services` erreichbar ist.
//
// WARUM KEIN SINGLETON:
// Im laufenden Programm gibt es genau ein `AppModel` (der App-Einstiegspunkt
// erzeugt es als `@StateObject`). Ein `static let shared` waere also fast
// richtig — aber SwiftUI-Previews und Tests koennen weitere Modelle bauen, und
// die duerfen sich weder Bibliothek noch Now-Playing-Zustand teilen. Deshalb
// haelt jedes Modell seinen eigenen Satz: `AppModel.services` ist eine
// gespeicherte Eigenschaft und lebt und stirbt mit dem Modell.
@MainActor
final class PlayerServices {

    /// Die Musikbibliothek an ihrem echten Ort (`Documents/` plus interner
    /// Support-Ordner fuer Index und Caches). `nil` heisst: das System hat die
    /// Ordner nicht herausgerueckt — dann kann die App nur noch eine
    /// Fehlermeldung zeigen, raten waere schlimmer.
    let library: MusicLibrary? = MusicLibrary.standard()

    /// Kategorie, Unterbrechungen (Anruf), Routenwechsel (Kopfhoerer raus).
    let audioSession = AudioSessionController()

    /// Sperrbildschirm, Kontrollzentrum, AirPods-Tasten.
    let nowPlaying = NowPlayingController()

    /// Wurde `start()` schon einmal ausgefuehrt? `start()` muss idempotent sein,
    /// weil SwiftUI `onAppear`/`task` mehrfach ausloesen kann.
    var didStart = false

    /// Der sparsame 1-Hz-Lauf, der Auto-Next und den Sperrbildschirm bedient.
    /// Haengt bewusst NICHT an der Szenenphase — er muss bei ausgeschaltetem
    /// Display weiterlaufen, sonst endet die Wiedergabe am ersten Songende.
    var playbackLoop: Task<Void, Never>?

    /// Laeuft gerade ein Bibliotheks-Abgleich? Verhindert, dass mehrere Scans
    /// derselben Sammlung nebeneinander laufen (z.B. App-Start plus sofortiger
    /// Wechsel in den Vordergrund).
    var libraryReloadTask: Task<Void, Never>?

    /// Wurde die Bibliothek seit dem Start schon einmal geladen? Erst danach
    /// darf die Sitzungswiederherstellung greifen — vorher gibt es keine Titel,
    /// gegen die sich die gespeicherte ID pruefen liesse.
    var didLoadLibraryOnce = false

    /// Laufender Ladevorgang der HVSC-Songlaengen-Datenbank.
    var songlengthLoadTask: Task<Void, Never>?

    /// „Datei:Subtune", fuer den gerade eine Laenge berechnet wird. Verhindert,
    /// dass dieselbe Berechnung doppelt startet.
    var lengthEstimateKey: String?

    /// Letzter gespeicherter 5-Sekunden-Abschnitt der Sitzung. Ohne diese
    /// Drosselung schriebe die App im Sekundentakt in die Benutzereinstellungen.
    var lastSessionBucket = -1

    /// Laeuft gerade ein „Bibliothek zuruecksetzen"? Das Loeschen passiert im
    /// Hintergrund; ohne diesen Griff haette der Vorgang kein erkennbares Ende.
    var resetTask: Task<Void, Never>?

    /// Noch nicht begonnene Import-Auftraege. Es laeuft immer nur einer;
    /// waehlt der Nutzer mehrere Ordner auf einmal, warten die uebrigen hier.
    var pendingImportJobs: [PendingImportJob] = []

    /// Laufende Summe ueber alle Auftraege der aktuellen Import-Aktion.
    var importTally = ImportTally()

    init() {}
}
