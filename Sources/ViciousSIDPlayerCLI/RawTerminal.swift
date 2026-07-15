// ============================================================================
// RawTerminal — Tastendruecke einzeln und sofort lesen, auf macOS UND Linux.
//
// Warum ueberhaupt etwas Eigenes?
// -------------------------------
// Ein Terminal arbeitet normalerweise im "Zeilenmodus" (canonical mode). Das
// heisst: der Kernel sammelt alles, was der Nutzer tippt, in einem Puffer und
// gibt es dem Programm erst heraus, wenn Enter gedrueckt wurde. Ausserdem
// zeigt er jedes Zeichen selbst an ("Echo"). Fuer `readLine()` ist das genau
// richtig — fuer einen Player, der auf "p" sofort pausieren soll, ist es
// unbrauchbar.
//
// Der **Rohmodus** (raw mode) schaltet beides ab:
//
//   * keine Zeilenpufferung: jedes Byte kommt an, sobald es getippt wurde,
//     ohne Enter;
//   * kein Echo: das Terminal malt die Taste nicht mehr auf den Schirm — sonst
//     stuende mitten in der Fortschrittsanzeige ein wildes "ppnnq".
//
// Umgeschaltet wird ueber `termios`, die POSIX-Struktur mit den
// Terminal-Einstellungen. Das Rezept ist auf beiden Plattformen gleich:
// alten Zustand mit `tcgetattr` sichern, Kopie veraendern, mit `tcsetattr`
// setzen — und am Ende den gesicherten Zustand exakt zurueckschreiben. Wer das
// Zurueckschreiben vergisst, hinterlaesst dem Nutzer eine Shell ohne Echo; die
// sieht "kaputt" aus und braucht ein blindes `reset`.
//
// Die drei Flags, die wir loeschen
// --------------------------------
// * `ECHO`   — Zeichen nicht mehr automatisch anzeigen (siehe oben).
// * `ICANON` — Zeilenmodus aus, also keine Pufferung bis Enter (siehe oben).
// * `ISIG`   — die Tastenkombinationen, die der Kernel in Signale uebersetzt.
//
// `ISIG` verdient eine eigene Erklaerung, denn es ist der eigentliche Grund,
// warum diese Klasse so gebaut ist:
//
//   Mit ISIG **an** erzeugt Strg-C ein SIGINT. Die Voreinstellung fuer SIGINT
//   ist "Prozess sofort beenden" — unser Programm stirbt auf der Stelle,
//   OHNE dass `restore()` je laeuft. Das Terminal bliebe damit im Rohmodus
//   zurueck: kein Echo, keine Zeilen — fuer den Nutzer unbenutzbar.
//
//   Mit ISIG **aus** ist Strg-C keine Sonderbehandlung mehr, sondern schlicht
//   das Byte 0x03. Es kommt ganz normal durch `readKey()` herein, der Aufrufer
//   erkennt es, raeumt auf (Audio stoppen, `restore()` rufen) und beendet sich
//   geordnet. Wir tauschen also "Kernel killt uns" gegen "wir bekommen ein
//   Byte und entscheiden selbst" — und nur so bleibt das Terminal heil.
//
//   Preis dieser Entscheidung: solange der Rohmodus laeuft, beendet Strg-C das
//   Programm NICHT mehr von allein. Der Aufrufer MUSS auf 0x03 reagieren,
//   sonst haengt der Player unkuendbar (ausser per `kill` von aussen).
//
// VMIN und VTIME — warum `readKey()` nicht ewig wartet
// ----------------------------------------------------
// Im Rohmodus steuern zwei Werte im Feld `c_cc`, wann ein `read` zurueckkehrt:
//
//   * `VMIN`  = wie viele Bytes mindestens da sein muessen;
//   * `VTIME` = wie lange hoechstens gewartet wird, in Zehntelsekunden.
//
// Wir setzen VMIN = 0 und VTIME = 1. Das bedeutet: "gib mir zurueck, was da
// ist, und wenn nach 1 Zehntelsekunde (~100 ms) nichts kam, kehre trotzdem
// zurueck (mit 0 Bytes)". Ohne das waere `read` ein blockierender Aufruf, der
// bis zum naechsten Tastendruck haengt — die Schleife im CLI koennte dann
// weder die Fortschrittsanzeige aktualisieren noch merken, dass das Stueck zu
// Ende ist. Mit dem Timeout ist `readKey()` ein hoeflicher Frager: "war was?
// nein? gut, gleich nochmal."
//
// Plattformunterschiede (die eigentliche Arbeit hier)
// ---------------------------------------------------
// `termios` gibt es auf macOS und Linux, aber nicht identisch:
//
//   * `c_cc` importiert Swift als grosses Tupel fester Laenge — und die Laenge
//     unterscheidet sich (Darwin NCCS = 20, Linux NCCS = 32). Ein Tupel kann
//     man in Swift nicht mit einer Variablen indizieren, `c_cc[VMIN]` ist also
//     unmoeglich. Ausweg unten: Zeiger auf das Tupel nehmen und ihn als Array
//     von `cc_t` deuten (`withMemoryRebound`) — das ist speicherlayout-gleich
//     und funktioniert bei beiden Laengen, weil wir NCCS selbst abfragen.
//   * `tcflag_t` ist verschieden breit (Darwin: unsigned long, Linux:
//     unsigned int), und die Konstanten ECHO/ICANON/ISIG kommen ebenfalls
//     unterschiedlich typisiert an. Deshalb wird unten JEDE Konstante explizit
//     nach `tcflag_t` gecastet, statt auf implizite Umwandlung zu hoffen —
//     die gibt es in Swift naemlich nicht.
// ============================================================================

import Foundation

// Import-Weiche: auf Linux liefert Glibc die POSIX-Bausteine (termios, read,
// isatty), auf Apple-Systemen Darwin. Wir fragen nach Glibc, denn Darwin ist
// hier der Normalfall und Linux die Ausnahme.
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Schaltet stdin in den Terminal-Rohmodus und liest einzelne Tasten.
///
/// Benutzung ist immer dasselbe Paar — `restore()` gehoert in ein `defer`,
/// damit es auch auf Fehlerpfaden laeuft:
///
/// ```swift
/// guard RawTerminal.isInteractive else { return }   // Pipe? dann gar nicht erst
/// let terminal = RawTerminal()
/// terminal.enter()
/// defer { terminal.restore() }
/// while let key = terminal.readKey() { ... }
/// ```
///
/// **Nicht `Sendable`, und das ist Absicht.** Die Klasse haelt veraenderlichen
/// Zustand (den gesicherten `termios`) ohne jede Absicherung und beschreibt
/// ausserdem eine prozessweite Ressource — das Terminal. Sie gehoert genau
/// einem Thread, dem, der die Tastaturschleife dreht. Ein `@unchecked Sendable`
/// waere hier eine Behauptung, die niemand einloest; deshalb bleibt es weg.
final class RawTerminal {

    /// Der Zustand, wie er vor `enter()` war. `nil` heisst: Rohmodus ist gerade
    /// nicht aktiv (nie betreten, schon zurueckgestellt — oder `tcgetattr` ist
    /// gescheitert, weil stdin gar kein Terminal ist).
    ///
    /// Dieses eine Feld ist zugleich unser "laeuft der Rohmodus?"-Merker. So
    /// koennen `enter()` und `restore()` gefahrlos mehrfach gerufen werden.
    private var original: termios?

    /// `true`, wenn stdin wirklich an einem Terminal haengt.
    ///
    /// Bei `vicious-sid x.sid --stdout | aplay ...`, bei `< /dev/null` oder in
    /// einem CI-Job ist stdin eine Pipe bzw. eine Datei — dort gibt es keine
    /// Tastatur, und der Rohmodus waere sinnlos (`tcsetattr` scheiterte ohnehin).
    /// Der Aufrufer fragt das ab und laesst die Tastatursteuerung dann einfach weg.
    static var isInteractive: Bool {
        // isatty() beantwortet genau diese Frage und gibt 1 fuer "ja" zurueck.
        return isatty(STDIN_FILENO) == 1
    }

    /// Schaltet stdin in den Rohmodus.
    ///
    /// Mehrfacher Aufruf ist harmlos: ab dem zweiten Mal passiert nichts, weil
    /// sonst der bereits veraenderte Zustand als "Original" gesichert wuerde —
    /// und `restore()` dann den Rohmodus wiederherstellte statt ihn zu beenden.
    ///
    /// Ist stdin kein Terminal (Pipe, `/dev/null`), tut die Methode nichts und
    /// meldet das auch nicht als Fehler: `readKey()` liefert dann eben nie etwas.
    /// Ein CLI soll nicht abstuerzen, nur weil es in einer Pipe laeuft.
    func enter() {
        guard original == nil else { return }

        // 1) Ist-Zustand holen. Schlaegt fehl, wenn stdin kein Terminal ist —
        //    dann bleibt `original` nil und alles Weitere wird zum No-Op.
        var current = termios()
        guard tcgetattr(STDIN_FILENO, &current) == 0 else { return }

        // 2) Original wegsichern, BEVOR wir irgendetwas veraendern. Nur diese
        //    unberuehrte Kopie schreibt `restore()` spaeter zurueck.
        original = current

        // 3) Auf der Kopie die drei Flags loeschen (Begruendung im Kopf der Datei).
        //    `c_lflag` ist das "local flags"-Feld: alles, was das Terminal an
        //    Komfort selbst erledigt — Echo, Zeilenmodus, Signaltasten.
        //    Der explizite `tcflag_t(...)`-Cast ist die Plattformbruecke: die
        //    Konstanten sind auf Darwin und Linux verschieden typisiert.
        let localFlagsToClear = tcflag_t(ECHO) | tcflag_t(ICANON) | tcflag_t(ISIG)
        current.c_lflag &= ~localFlagsToClear

        // 4) VMIN/VTIME setzen, damit `read` nach ~100 ms aufgibt.
        //
        //    `c_cc` ist in Swift ein Tupel — nicht indizierbar. Deshalb der
        //    Umweg ueber den Zeiger: `withUnsafeMutablePointer` gibt uns die
        //    Adresse des Tupels, `withMemoryRebound` deutet denselben Speicher
        //    als Feld aus `NCCS` Stueck `cc_t`. Genau so liegt es im Speicher
        //    ohnehin, wir sagen dem Compiler also nichts Falsches. Weil wir
        //    `NCCS` abfragen statt eine Zahl hinzuschreiben, stimmt die Laenge
        //    auf beiden Plattformen (Darwin 20, Linux 32).
        withUnsafeMutablePointer(to: &current.c_cc) { ccTuplePointer in
            ccTuplePointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { controlChars in
                controlChars[Int(VMIN)] = 0   // 0 Bytes genuegen — nie auf ein Byte warten
                controlChars[Int(VTIME)] = 1  // 1 = eine Zehntelsekunde Geduld (~100 ms)
            }
        }

        // 5) Uebernehmen. TCSAFLUSH heisst: erst noch ausstehende Ausgabe
        //    fertig schreiben, dann alles verwerfen, was schon getippt, aber
        //    noch nicht gelesen wurde. Damit landet ein vor dem Start
        //    versehentlich gedruecktes Enter nicht als erste "Taste" im Player.
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &current)
    }

    /// Stellt den Zustand von vor `enter()` wieder her — Byte fuer Byte den
    /// gesicherten `termios`, nichts "ungefaehr Aehnliches".
    ///
    /// Mehrfacher Aufruf ist harmlos, und wenn `enter()` nie lief (oder mangels
    /// Terminal nichts tat), ist die Methode ein No-Op. Genau deshalb darf sie
    /// bedenkenlos in ein `defer` oder in einen Fehlerpfad.
    func restore() {
        guard var saved = original else { return }

        // Erst den Merker loeschen, dann zurueckschreiben: selbst wenn
        // `tcsetattr` scheitert, gilt der Rohmodus danach als beendet. Ein
        // zweiter `restore()`-Versuch wuerde ohnehin am selben Fehler scheitern.
        original = nil
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
    }

    /// Liest eine einzelne Taste und wartet dabei hoechstens ~100 ms.
    ///
    /// - Returns: das gelesene Byte, oder `nil`, wenn in dieser Zeit nichts kam
    ///   (bzw. stdin am Ende oder kaputt ist). `nil` ist der Normalfall und kein
    ///   Fehler — der Aufrufer nutzt die Rueckkehr, um seine Schleife weiter zu
    ///   drehen (Fortschritt zeichnen, Ende pruefen) und fragt danach erneut.
    ///
    /// Es kommt immer nur EIN Byte zurueck. Fuer die einfachen Tasten des CLI
    /// (p, n, q, Strg-C = 0x03) genuegt das. Pfeiltasten senden dagegen mehrere
    /// Bytes (Escape-Sequenz `0x1B [ A`); wer die auswerten will, muss die
    /// Folgebytes selbst mit weiteren `readKey()`-Aufrufen einsammeln.
    func readKey() -> UInt8? {
        var byte: UInt8 = 0

        while true {
            let count = read(STDIN_FILENO, &byte, 1)

            if count == 1 {
                return byte
            }

            if count == 0 {
                // Dank VTIME der uebliche Fall: 100 ms um, niemand hat getippt.
                // (Auch das Dateiende sieht so aus — beides heisst "nichts da".)
                return nil
            }

            // count < 0, also Fehler. EINTR heisst nur "ein Signal kam
            // dazwischen, bevor Daten da waren" — das ist kein echter Fehler,
            // sondern ein Hinweis, den Aufruf schlicht zu wiederholen. Wer das
            // nicht tut, verliert bei jedem harmlosen Signal (etwa
            // SIGWINCH beim Groessenaendern des Fensters) einen Tastendruck.
            if errno == EINTR { continue }

            // Alles andere: aufgeben. Ein defektes stdin wird durch Nachbohren
            // nicht besser — der Aufrufer sieht `nil` und macht weiter wie bei
            // einem Timeout.
            return nil
        }
    }
}
