import Foundation
import ViciousSIDPlayerCore

// Die STIL-Haelfte des AppModels: die "SID Tune Information List" der HVSC.
//
// Was das ist: Eine SID-Datei nennt im Kopf nur Titel, Autor und Jahr. Welche
// Vorlage ein Tune covert, wer die Melodie geschrieben hat oder was es zu einem
// einzelnen Subtune zu sagen gibt, pflegt die HVSC von Hand in
// `DOCUMENTS/STIL.txt`. Parser und Zuordnung stehen im Core (`STIL.swift`) und
// sind dort getestet; diese Datei ist nur die Bruecke ins App-Modell.
//
// Anders als auf dem Mac gibt es hier KEINEN Auto-Fund: Die Bibliothek liegt auf
// iOS immer in `Documents/`, eine HVSC-Ordnerstruktur mit `DOCUMENTS/` darueber
// gibt es nicht. Der Nutzer waehlt die Datei deshalb einmal aus, genau wie die
// Songlaengen-Datenbank; die Zuordnung laeuft dann ueber ein eindeutiges
// Pfadende (`STILDatabase.resolvedPath`).
extension AppModel {

    /// Text ohne importierte Datei.
    static var missingSTILStatus: String { "Keine STIL-Datei importiert" }

    /// Ablageort der importierten STIL.txt.
    ///
    /// Wie bei den Songlaengen im internen Support-Ordner und als KOPIE: In
    /// `Documents/` laege sie fuer den Nutzer sichtbar zwischen seiner Musik,
    /// und die URL aus dem Dateiauswahl-Dialog ist beim naechsten Start wertlos.
    var stilFileURL: URL? {
        services.library?.supportDirectory.appendingPathComponent("stil.txt")
    }

    /// Uebernimmt eine vom Nutzer gewaehlte `STIL.txt` in die App.
    ///
    /// Der Kopiervorgang lief frueher als losgelassener `Task.detached`. Zwei
    /// kurz aufeinanderfolgende Auswahlen schrieben beide dasselbe Ziel, und
    /// zuletzt gewann der LANGSAMERE — die App arbeitete danach mit einer
    /// anderen Datei als der zuletzt gewaehlten (Review-Fund 2026-08-25).
    /// Jetzt gilt: Der neue Auftrag bricht den alten ab, wartet dessen Ende ab
    /// (damit die Schreibvorgaenge nicht ueberholen) und nur die juengste
    /// Generation darf Status setzen und laden.
    func importSTIL(from url: URL) {
        guard let destination = stilFileURL else {
            errorMessage = "Der interne Ordner der App ist nicht erreichbar."
            return
        }
        services.stilLoadTask?.cancel()
        services.stilLoadTask = nil
        services.stilImportTask?.cancel()
        let previous = services.stilImportTask
        services.stilImportGeneration &+= 1
        let generation = services.stilImportGeneration
        setSTILStatus("Datei wird übernommen …")

        services.stilImportTask = Task.detached(priority: .utility) { [self] in
            // Erst wenn der abgebrochene Vorgaenger wirklich durch ist, darf
            // hier geschrieben werden — sonst landete seine Datei zuletzt.
            await previous?.value
            // Der Sicherheits-Scope gilt prozessweit, nicht pro Thread — er darf
            // deshalb hier geoeffnet und geschlossen werden.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try Task.checkCancellation()
                try data.write(to: destination, options: .atomic)
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard self.services.stilImportGeneration == generation else { return }
                    self.services.stilImportTask = nil
                    self.setSTILStatus(AppModel.missingSTILStatus)
                    self.errorMessage = "STIL-Datei konnte nicht übernommen werden: \(message)"
                }
                return
            }
            await MainActor.run {
                guard self.services.stilImportGeneration == generation else { return }
                self.services.stilImportTask = nil
                self.loadSTIL()
            }
        }
    }

    /// Laedt die zuvor importierte STIL.txt im Hintergrund.
    ///
    /// Die echte Datei der HVSC hat ueber 200.000 Zeilen — im Hauptthread
    /// geparst stuende die Oberflaeche dabei.
    func loadSTIL() {
        services.stilLoadTask?.cancel()
        services.stilLoadTask = nil

        guard let fileURL = stilFileURL,
              fileManager.fileExists(atPath: fileURL.path) else {
            stilDB = nil
            setSTILStatus(AppModel.missingSTILStatus)
            return
        }

        services.stilLoadTask = Task { [self] in
            let database = await Task.detached(priority: .utility) { () -> STILDatabase? in
                try? STILDatabase.loadCancellable(url: fileURL)
            }.value

            guard !Task.isCancelled else { return }
            services.stilLoadTask = nil
            stilDB = database

            guard let database else {
                setSTILStatus("Datei konnte nicht gelesen werden")
                return
            }
            setSTILStatus("\(database.count) Titel, \(database.folderCount) Ordner")
        }
    }

    /// Was die STIL zum laufenden Titel und Subtune sagt — `nil`, wenn sie ihn
    /// nicht kennt.
    ///
    /// Die Titel-ID ist auf iOS der Pfad relativ zu `Documents/`. Ob daraus ein
    /// STIL-Eintrag wird, entscheidet der Core: Er nimmt nur ein EINDEUTIGES
    /// Pfadende. In der HVSC heissen dutzende Dateien gleich; lieber keine
    /// Anmerkung als die eines fremden Titels.
    var currentSTILInfo: STILInfo? {
        guard let stilDB, let id = currentTrackID else { return nil }
        guard let path = stilDB.resolvedPath(forFileURL: nil,
                                             hvscRoot: nil,
                                             relativePath: id) else { return nil }
        let info = stilDB.info(forHVSCPath: path, subtune: coordinator.currentSubtune)
        return info.isEmpty ? nil : info
    }
}
