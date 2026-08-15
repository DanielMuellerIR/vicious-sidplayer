import XCTest
import ViciousSIDPlayerCore
@testable import ViciousSIDPlayer

// Tests der iOS-Glue-Schicht.
//
// Abgrenzung zu `swift test`: dort liegen Parser, Emulation und die
// plattformneutrale Bibliothekslogik. Hier steht nur das, was es ohne iOS gar
// nicht gibt — das App-Modell, seine Filterlogik und der Vertrag der
// Info.plist. Beide Suiten muessen gruen sein; die eine ersetzt die andere nicht.
//
// Keine echten `.sid`-Dateien: alle Fixtures entstehen zur Laufzeit im
// temporaeren Verzeichnis.
final class AppModelTests: XCTestCase {

    // MARK: - Zeitformatierung

    func testFormatTime() {
        XCTAssertEqual(AppModel.formatTime(0), "0:00")
        XCTAssertEqual(AppModel.formatTime(9), "0:09")
        XCTAssertEqual(AppModel.formatTime(65), "1:05")
        XCTAssertEqual(AppModel.formatTime(600), "10:00")
        XCTAssertEqual(AppModel.formatTime(3661), "1:01:01")
    }

    // Der Scrubber liefert beim Ziehen gelegentlich NaN oder negative Werte.
    // Die duerfen nicht als "nan:aN" in der Oberflaeche landen.
    func testFormatTimeRejectsInvalidValues() {
        XCTAssertEqual(AppModel.formatTime(.nan), "0:00")
        XCTAssertEqual(AppModel.formatTime(.infinity), "0:00")
        XCTAssertEqual(AppModel.formatTime(-42), "0:00")
    }

    // MARK: - Ordnerbaum

    func testFolderTreeCountsTracksRecursively() {
        let deep = LibraryFolder(id: "A/B", name: "B", subfolders: [], trackIDs: ["A/B/x.sid"])
        let middle = LibraryFolder(id: "A", name: "A", subfolders: [deep], trackIDs: ["A/y.sid", "A/z.sid"])
        let root = LibraryFolder(id: "", name: "", subfolders: [middle], trackIDs: ["top.sid"])

        XCTAssertEqual(deep.totalTrackCount, 1)
        XCTAssertEqual(middle.totalTrackCount, 3)
        XCTAssertEqual(root.totalTrackCount, 4)
        XCTAssertEqual(LibraryFolder.empty.totalTrackCount, 0)
    }

    // MARK: - Fortschritt

    func testImportProgressFraction() {
        // Solange die Gesamtzahl noch gezaehlt wird, gibt es keinen Bruchteil —
        // die UI zeigt dann einen unbestimmten Fortschritt statt "0 %".
        XCTAssertNil(ImportProgress(current: 0, total: 0, currentFile: "").fraction)
        XCTAssertEqual(ImportProgress(current: 1, total: 4, currentFile: "").fraction, 0.25)
        // Mehr Dateien als erwartet darf nicht ueber 100 % hinauslaufen.
        XCTAssertEqual(ImportProgress(current: 9, total: 4, currentFile: "").fraction, 1.0)
    }

    // MARK: - Dateityp

    func testSidFileTypeIsCaseInsensitive() {
        // Sammlungen aus dem Netz mischen ".sid" und ".SID".
        XCTAssertTrue(SidFileType.matches(URL(fileURLWithPath: "/tmp/a.sid")))
        XCTAssertTrue(SidFileType.matches(URL(fileURLWithPath: "/tmp/a.SID")))
        XCTAssertFalse(SidFileType.matches(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertFalse(SidFileType.matches(URL(fileURLWithPath: "/tmp/sid")))
    }

    // MARK: - Bibliothekswurzel

    // Auf iOS muss die Wurzel im Documents-Ordner liegen: nur der ist ueber die
    // Finder-Dateifreigabe und die Dateien-App von aussen erreichbar. Liegt sie
    // woanders, ist Import-Weg B still kaputt.
    func testLibraryRootIsInsideDocuments() throws {
        let root = try XCTUnwrap(MusicLibraryLocation.root())
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        XCTAssertEqual(root.standardizedFileURL.path, documents.standardizedFileURL.path)
    }

    // Index und Caches gehoeren NICHT in den Documents-Ordner — sonst sieht der
    // Nutzer sie in der Dateifreigabe zwischen seiner Musik liegen und loescht sie.
    func testSupportDirectoryIsNotVisibleToTheUser() throws {
        let support = try XCTUnwrap(MusicLibraryLocation.support())
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        XCTAssertFalse(support.standardizedFileURL.path.hasPrefix(documents.standardizedFileURL.path))
    }

    // MARK: - Szenenphase

    // Der Vertrag lautet: im Hintergrund steht die Visualisierung still, das
    // Audio laeuft weiter. Was hier geprueft werden kann, ist die Weiche —
    // `isSceneActive`, an dem der Zeichen-Timer haengt. Dass die Musik dabei
    // wirklich weiterspielt, ist nur auf echter Hardware belegbar (siehe
    // ios/GERAETETEST.md); der Simulator suspendiert anders.
    @MainActor
    func testScenePhaseTogglesVisualisationButNeverStopsPlayback() {
        let model = AppModel()
        XCTAssertTrue(model.isSceneActive)

        model.scenePhaseChanged(to: .background)
        XCTAssertFalse(model.isSceneActive, "Im Hintergrund darf nicht gezeichnet werden.")
        XCTAssertFalse(model.coordinator.isPaused,
                       "Der Wechsel in den Hintergrund darf die Wiedergabe NICHT pausieren.")

        model.scenePhaseChanged(to: .active)
        XCTAssertTrue(model.isSceneActive)
    }

    // MARK: - Songlaenge: die Reihenfolge ist ein Architekturvertrag

    // Die Dauer eines Titels entscheidet ueber Scrubber, Auto-Next,
    // Sperrbildschirm und WAV-Export. Sie wird in einer festen Reihenfolge
    // aufgeloest: HVSC-Datenbank, dann berechneter Cache, sonst das Fallback.
    // Diese Reihenfolge steht in den Projektregeln — bisher hielt sie kein Test
    // fest, obwohl sie sich mit einer einzigen umgestellten Zeile kippen liesse.
    @MainActor
    func testCurrentDurationFollowsTheDocumentedOrder() {
        let model = AppModel()

        // 1. Nichts bekannt -> Fallback.
        model.currentTrackLengths = nil
        model.computedLength = nil
        XCTAssertEqual(model.currentDuration, AppModel.fallbackDurationSeconds,
                       "Ohne jede Quelle muss das Fallback gelten")

        // 2. Nur eine berechnete Laenge -> die gewinnt gegen das Fallback.
        model.computedLength = 42
        XCTAssertEqual(model.currentDuration, 42)

        // 3. Die HVSC-Datenbank gewinnt gegen die berechnete Laenge.
        model.currentTrackLengths = [111, 222]
        XCTAssertEqual(model.currentDuration, 111,
                       "Der kuratierte Datenbankwert hat immer Vorrang")

        // 4. Kennt die Datenbank den laufenden Subtune nicht, faellt es auf die
        //    berechnete Laenge zurueck — nicht auf einen fremden Subtune.
        model.currentTrackLengths = []
        XCTAssertEqual(model.currentDuration, 42)
    }

    // MARK: - Sichtbare Liste

    // `visibleTracks` ist mehr als eine Anzeige: es ist zugleich die
    // Reihenfolge, in der „Weiter" und „Zurueck" laufen. Suche und
    // Favoritenfilter duerfen deshalb nicht auseinanderlaufen.
    @MainActor
    func testVisibleTracksAppliesSearchAndFavouritesTogether() {
        let model = AppModel()
        let tracks = [
            LibraryTrack(id: "Hubbard/Commando.sid", name: "Commando", folderPath: "Hubbard"),
            LibraryTrack(id: "Hubbard/Sanxion.sid", name: "Sanxion", folderPath: "Hubbard"),
            LibraryTrack(id: "Galway/Rambo.sid", name: "Rambo", folderPath: "Galway")
        ]
        model.applyLibrary(tracks: tracks, folderTree: .empty)
        XCTAssertEqual(model.visibleTracks.count, 3)

        // Suche greift auf Titel UND Ordnernamen.
        model.searchText = "galway"
        XCTAssertEqual(model.visibleTracks.map(\.name), ["Rambo"],
                       "Die Suche muss auch den Ordnernamen erfassen")
        model.searchText = "SANX"
        XCTAssertEqual(model.visibleTracks.map(\.name), ["Sanxion"],
                       "Die Suche ist unabhaengig von Gross- und Kleinschreibung")

        // Beide Filter zusammen: nur Favoriten, die auch zur Suche passen.
        model.searchText = "hubbard"
        model.setFavorites(["Hubbard/Sanxion.sid", "Galway/Rambo.sid"])
        model.favoritesOnly = true
        XCTAssertEqual(model.visibleTracks.map(\.name), ["Sanxion"],
                       "Suche und Favoritenfilter muessen gemeinsam greifen")

        // Leerraum in der Suche darf nicht alles ausfiltern.
        model.searchText = "   "
        XCTAssertEqual(model.visibleTracks.count, 2, "Nur Leerraum ist keine Suche")
    }

    // Verschwindet der laufende Titel von aussen (Dateifreigabe, Loeschen), gilt
    // kein Titel mehr als aktuell — die Wiedergabe laeuft aber weiter, bis der
    // Nutzer etwas anderes waehlt.
    @MainActor
    func testCurrentTrackIsForgottenWhenItDisappearsFromTheLibrary() {
        let model = AppModel()
        let track = LibraryTrack(id: "A/x.sid", name: "x", folderPath: "A")
        model.applyLibrary(tracks: [track], folderTree: .empty)
        model.setCurrentTrackID("A/x.sid")
        XCTAssertNotNil(model.currentTrack)

        model.applyLibrary(tracks: [], folderTree: .empty)
        XCTAssertNil(model.currentTrackID, "Ein verschwundener Titel darf nicht aktuell bleiben")
    }

    // MARK: - Favoriten

    // Favoriten haengen an RELATIVEN Pfaden, nicht an absoluten URLs: der
    // App-Container bekommt bei jeder Neuinstallation eine neue UUID.
    @MainActor
    func testFavouritesToggleRoundTrips() {
        let model = AppModel()
        let id = "Hubbard/Commando.sid"
        let previous = model.defaults.stringArray(forKey: AppModel.Keys.favorites)
        defer { model.defaults.set(previous, forKey: AppModel.Keys.favorites) }

        model.setFavorites([])
        XCTAssertFalse(model.isFavorite(id))

        model.toggleFavorite(id)
        XCTAssertTrue(model.isFavorite(id))
        XCTAssertEqual(model.defaults.stringArray(forKey: AppModel.Keys.favorites), [id],
                       "Der Favorit muss als relativer Pfad gespeichert sein")

        model.toggleFavorite(id)
        XCTAssertFalse(model.isFavorite(id))
    }

    // MARK: - Sitzungswiederherstellung

    // Ist die Wiederherstellung abgeschaltet, darf auch nichts geschrieben
    // werden — sonst taucht der Stand nach dem Wiedereinschalten aus einer
    // Sitzung auf, die der Nutzer laengst vergessen hat.
    @MainActor
    func testSessionStateIsNotWrittenWhileRestoreIsDisabled() {
        let model = AppModel()
        let defaults = model.defaults
        let previousEnabled = defaults.object(forKey: AppModel.Keys.sessionRestore)
        let previousID = defaults.object(forKey: AppModel.Keys.lastTrackID)
        defer {
            defaults.set(previousEnabled, forKey: AppModel.Keys.sessionRestore)
            defaults.set(previousID, forKey: AppModel.Keys.lastTrackID)
        }

        model.clearSessionState()
        model.setCurrentTrackID("A/x.sid")

        model.sessionRestoreEnabled = false
        model.saveSessionState()
        XCTAssertNil(defaults.string(forKey: AppModel.Keys.lastTrackID),
                     "Bei abgeschalteter Wiederherstellung darf nichts gesichert werden")

        model.sessionRestoreEnabled = true
        model.saveSessionState()
        XCTAssertEqual(defaults.string(forKey: AppModel.Keys.lastTrackID), "A/x.sid")

        model.clearSessionState()
        XCTAssertNil(defaults.string(forKey: AppModel.Keys.lastTrackID),
                     "clearSessionState muss den Stand wirklich entfernen")
    }

    // Bei aktiver Zufallswiedergabe wird bewusst NICHT wiederhergestellt — wer
    // Shuffle anlaesst, will bei jedem Start etwas anderes hoeren. Ohne einen
    // Titel in der Bibliothek passiert ohnehin nichts; genau das haelt dieser
    // Test fest, damit der Sonderfall beim Umbauen nicht verlorengeht.
    @MainActor
    func testRestoreDoesNothingWithoutTracks() {
        let model = AppModel()
        model.applyLibrary(tracks: [], folderTree: .empty)
        model.shuffle = true
        model.restoreSessionIfPossible()
        XCTAssertNil(model.currentTrackID)

        model.shuffle = false
        model.restoreSessionIfPossible()
        XCTAssertNil(model.currentTrackID)
    }

    // MARK: - Info.plist-Vertrag

    // Diese Schluessel sind keine Kosmetik: ohne sie ist die App im Kern kaputt,
    // und zwar auf eine Art, die man im Simulator nicht bemerkt. Deshalb ein Test.
    func testInfoPlistEnablesBackgroundAudio() throws {
        let modes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        )
        XCTAssertTrue(modes.contains("audio"),
                      "Ohne UIBackgroundModes=audio friert iOS die App beim Sperren ein.")
    }

    func testInfoPlistEnablesFileSharing() throws {
        // Import-Weg B: iPhone am Kabel -> Finder -> Dateien -> ganze Ordner ablegen.
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool, true)
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool,
            true
        )
    }

    func testInfoPlistDeclaresSidType() throws {
        let declarations = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]]
        )
        let identifiers = declarations.compactMap { $0["UTTypeIdentifier"] as? String }
        // Der Bezeichner muss zur zentralen Core-Konstante passen — sonst
        // filtern die Dateidialoge auf einen Typ, den das System nicht kennt.
        XCTAssertTrue(identifiers.contains(SidFileType.uti))
    }

    // MARK: - Privacy-Manifest

    func testPrivacyManifestDeclaresNoTracking() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                                "PrivacyInfo.xcprivacy fehlt im App-Bundle.")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        XCTAssertEqual((plist["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
    }
}
