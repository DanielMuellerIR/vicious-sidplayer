import Foundation

// Spielzeit als Text — eine Fassung für alle Oberflächen.
//
// Warum das im Core steht und nicht je Frontend: Es gab drei Fassungen derselben
// Umwandlung — in der Mac-App, in der iPhone-App und noch einmal direkt in der
// Quick-Look-Vorschau. Sie waren nicht gleich gut:
//
//   * Nur die iPhone-Fassung fing negative und nicht-endliche Werte ab. Auf dem
//     Mac erschien bei einem negativen Zwischenwert "0:-5".
//   * Nur die iPhone-Fassung kannte Stunden; die anderen zeigten "61:01" statt
//     "1:01:01".
//   * Quick Look rechnete ohne jede Prüfung `Int(seconds)`. Das ist in Swift
//     kein Schönheitsfehler, sondern ein Absturz, sobald der Wert unendlich
//     oder NaN ist.
//
// Solche Zwischenwerte entstehen tatsächlich: Der Positionsregler liefert
// während des Ziehens gelegentlich NaN oder kurzzeitig negative Werte.
//
// Der Typ ist bewusst winzig und ohne Abhängigkeiten — genau wie `ThemeMode`
// nebenan, das aus demselben Grund hier liegt.
public enum PlaytimeFormat {

    /// Sekunden als „M:SS", ab einer Stunde als „H:MM:SS".
    ///
    /// Nicht-endliche und negative Werte ergeben „0:00" statt einer unsinnigen
    /// Anzeige oder eines Absturzes. Es wird abgerundet: 59,9 s sind „0:59",
    /// nicht „1:00" — sonst stünde am Ende eines Titels kurz eine Zeit, die
    /// größer ist als seine Dauer.
    public static func string(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        // Vor der Umwandlung nach Int deckeln: Ohne die Grenze stürzt `Int(...)`
        // bei absurd großen Werten ab. 100 Stunden sind jenseits von allem, was
        // ein SID-Tune je erreicht, und bleiben sicher im Int-Bereich.
        let total = Int(min(seconds, 360_000).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
