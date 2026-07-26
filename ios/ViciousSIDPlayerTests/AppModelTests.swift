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
