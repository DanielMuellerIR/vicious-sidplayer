import Foundation

// Wo liegt die Musikbibliothek, und wo liegen Index und Caches?
//
// Diese Frage wird auf macOS und iOS unterschiedlich beantwortet, und die
// Antwort brauchen mehrere Stellen (AutoplayFolder, MusicLibrary, Importer,
// Reset, Songlaengen-Cache). Deshalb steht sie genau einmal hier.
//
// Zwei getrennte Orte, und das ist Absicht:
//
//   root      — die Musikdateien selbst. Auf iOS bewusst `Documents/`, denn nur
//               dieser Ordner ist ueber die Finder-Dateifreigabe und die
//               iOS-Dateien-App von aussen erreichbar. Genau das ist Import-Weg
//               B: iPhone ans Kabel, ganze Ordner per Drag & Drop hineinziehen.
//   support   — Index, berechnete Songlaengen, interner Kleinkram. Bewusst
//               NICHT in `Documents/`, sonst sieht der Nutzer diese Dateien in
//               der Freigabe zwischen seiner Musik liegen und loescht sie.
//
// Daraus folgt eine Regel, die der ganze Bibliothekscode einhalten muss: der
// Nutzer kann `root` jederzeit hinter dem Ruecken der App veraendern. Der Index
// ist deshalb immer nur eine Zwischenablage, nie die einzige Wahrheit.
public enum MusicLibraryLocation {
    /// Ordnername unterhalb von "Application Support" (macOS) — identisch zum
    /// bereits vorhandenen Ablageort des Songlaengen-Caches.
    public static let supportFolderName = "Vicious SID Player"

    /// Wurzel der Musikbibliothek. Wird angelegt, falls sie noch nicht existiert.
    ///
    /// - iOS: `<App-Container>/Documents` — nutzersichtbar, siehe oben.
    /// - macOS: `~/Music/Vicious SID Player` — derselbe Standard-Ordner, den die
    ///   Mac-App seit jeher als Autoplay-Ordner benutzt. Dort bleibt er der
    ///   Vorgabewert, den der Nutzer in den Einstellungen ueberschreiben kann.
    public static func root(fm: FileManager = .default) -> URL? {
        #if os(iOS)
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ensureDirectory(documents, fm: fm)
        #else
        let home = fm.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent(AutoplayFolder.defaultRelativePath, isDirectory: true)
        return ensureDirectory(folder, fm: fm)
        #endif
    }

    /// Ablageort fuer Index und Caches — nicht nutzersichtbar.
    /// Wird angelegt, falls er noch nicht existiert.
    public static func support(fm: FileManager = .default) -> URL? {
        #if os(iOS)
        // Im App-Container ist "Application Support" schon exklusiv unser
        // Bereich; ein weiterer Unterordner mit Produktnamen waere reine
        // Verschachtelung. Der Ordner selbst existiert nach der Installation
        // aber noch nicht — anlegen muss man ihn trotzdem.
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return ensureDirectory(base, fm: fm)
        #else
        // Auf dem Mac teilen sich alle Programme "Application Support",
        // deshalb der eigene Unterordner.
        //
        // Der Notnagel unten ist fuer Linux gedacht: dort liefert Foundation
        // je nach Umgebung gar kein "Application Support". Ohne ihn landete
        // der Songlaengen-Cache im temporaeren Verzeichnis und waere nach
        // jedem Neustart weg. Der Pfad ist derselbe, den der Cache vor der
        // iOS-Portierung schon benutzt hat.
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return ensureDirectory(base.appendingPathComponent(supportFolderName, isDirectory: true), fm: fm)
        #endif
    }

    /// Legt das Verzeichnis bei Bedarf an und liefert es zurueck; `nil`, wenn
    /// das nicht gelingt (z.B. weil an der Stelle eine Datei liegt).
    private static func ensureDirectory(_ url: URL, fm: FileManager) -> URL? {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue ? url : nil
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }
}
