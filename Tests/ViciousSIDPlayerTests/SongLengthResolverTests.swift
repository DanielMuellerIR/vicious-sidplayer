import XCTest
@testable import ViciousSIDPlayerCore

// ============================================================================
// Tests der Songlaengen-Reihenfolge.
//
// Bis v1.9.8 stand diese Regel doppelt in den beiden Oberflaechen und war damit
// ungetestet: `MainView` (Mac) und `AppModel+Playback` (iPhone) liegen in
// executableTargets bzw. im Xcode-Projekt und sind aus dieser Suite gar nicht
// erreichbar. Seit dem Rueckbau in `SongLengthResolver` gilt: Wer die
// Reihenfolge aendert, faellt hier um.
//
// Die Berechnung selbst (`SongLengthEstimator`) hat eigene Tests. Hier geht es
// ausschliesslich um die Entscheidung — welche Quelle gewinnt, wann gerechnet
// wird, und welches Ergebnis noch angenommen werden darf.
//
// Die Tests laufen ohne Actor-Isolation, weil der Resolver keine verlangt: Er
// schuetzt seine Buchfuehrung mit einer Sperre. Ein `@MainActor` am Core-Typ
// waere hier teuer erkauft — unter Linux ist `XCTestCase` nicht
// MainActor-isoliert, und die dort erzeugte Testliste kann eine
// MainActor-gebundene Testmethode gar nicht aufrufen.
// ============================================================================
final class SongLengthResolverTests: XCTestCase {

    private var directory: URL!
    private var cache: SongLengthCache!

    /// Beliebige Datei-URL; angefasst wird sie in diesen Tests nie, weil
    /// `plan(...)` nur entscheidet und nicht liest.
    private let file = URL(fileURLWithPath: "/tmp/nicht-gelesen.sid")
    private let md5 = "0123456789ABCDEF0123456789ABCDEF"

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("songlength-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = SongLengthCache(fileURL: directory.appendingPathComponent("cache.json"))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    /// Frischer Resolver auf dem Cache dieses Tests.
    private func makeResolver() -> SongLengthResolver {
        return SongLengthResolver(cache: cache)
    }

    // MARK: - Die Reihenfolge

    /// Stufe 1: Steht die Laenge in der HVSC-Datenbank, wird nichts gerechnet.
    func testDatabaseLengthWinsOverEverythingElse() {
        // Auch wenn im Cache ein abweichender Wert liegt: die DB hat Vorrang.
        cache.store(md5: md5, subtune: 0, seconds: 99.0)
        let resolver = makeResolver()

        let plan = resolver.plan(md5: md5, subtune: 0,
                                 databaseLengths: [12.5, 34.0], fileURL: file)

        XCTAssertEqual(plan, .databaseProvidesLength)
        XCTAssertFalse(resolver.isEstimating, "Bei DB-Treffer darf keine Rechnung laufen")
    }

    /// Die DB kennt die Datei, aber nicht diesen Subtune — dann greift die
    /// naechste Stufe. Genau hier lag der Grund fuer die `subtune < count`-Pruefung.
    func testDatabaseWithFewerEntriesThanSubtunesFallsThrough() {
        let plan = makeResolver().plan(md5: md5, subtune: 3,
                                       databaseLengths: [12.5, 34.0], fileURL: file)

        guard case .estimate = plan else {
            return XCTFail("Fehlender DB-Eintrag fuer diesen Subtune muss zur Berechnung fuehren, war: \(plan)")
        }
    }

    /// Ein negativer Subtune darf nicht in das Array greifen.
    func testNegativeSubtuneDoesNotIndexIntoDatabaseLengths() {
        let plan = makeResolver().plan(md5: md5, subtune: -1,
                                       databaseLengths: [12.5], fileURL: file)

        guard case .estimate = plan else {
            return XCTFail("Negativer Subtune darf keinen DB-Treffer ergeben, war: \(plan)")
        }
    }

    /// Stufe 2: Ohne DB-Eintrag zaehlt der berechnete Cache.
    func testCachedLengthIsUsedWhenDatabaseHasNothing() {
        cache.store(md5: md5, subtune: 1, seconds: 42.25)
        let resolver = makeResolver()

        let plan = resolver.plan(md5: md5, subtune: 1,
                                 databaseLengths: nil, fileURL: file)

        XCTAssertEqual(plan, .cached(42.25))
        XCTAssertFalse(resolver.isEstimating, "Ein Cache-Treffer darf keine Rechnung ausloesen")
    }

    /// Der Cache ist gegen Gross-/Kleinschreibung unempfindlich — sonst wuerde
    /// derselbe Tune je nach Schreibweise des MD5 zweimal gerechnet.
    func testCacheLookupIgnoresMD5Case() {
        cache.store(md5: md5.lowercased(), subtune: 0, seconds: 17.0)

        let plan = makeResolver().plan(md5: md5.uppercased(), subtune: 0,
                                       databaseLengths: nil, fileURL: file)

        XCTAssertEqual(plan, .cached(17.0))
    }

    /// Das gecachte -1 heisst „schon gerechnet, kein Ende gefunden". Es MUSS
    /// eine erneute Rechnung verhindern — sonst rechnet jeder Loop-Tune bei
    /// jedem Abspielen sechs Minuten lang neu.
    func testNegativeCacheEntryPreventsRecomputation() {
        cache.store(md5: md5, subtune: 0, seconds: -1)
        let resolver = makeResolver()

        let plan = resolver.plan(md5: md5, subtune: 0,
                                 databaseLengths: nil, fileURL: file)

        XCTAssertEqual(plan, .noLengthKnown)
        XCTAssertFalse(resolver.isEstimating, "Ein Loop-Tune darf nicht erneut gerechnet werden")
    }

    /// Stufe 3: Weder DB noch Cache — dann wird gerechnet.
    func testEstimateIsRequestedWhenNothingIsKnown() {
        let resolver = makeResolver()

        let plan = resolver.plan(md5: md5, subtune: 2,
                                 databaseLengths: nil, fileURL: file)

        guard case .estimate(let ticket) = plan else {
            return XCTFail("Ohne jede Quelle muss gerechnet werden, war: \(plan)")
        }
        XCTAssertEqual(ticket.md5, md5)
        XCTAssertEqual(ticket.subtune, 2)
        XCTAssertEqual(ticket.fileURL, file)
        XCTAssertTrue(resolver.isEstimating)
    }

    /// Stufe 4 gehoert der App: ohne MD5 oder ohne erreichbare Datei gibt es
    /// nichts zu tun, und es darf auch nichts gestartet werden.
    func testMissingInputsYieldNoLengthAndNoEstimate() {
        let resolver = makeResolver()

        XCTAssertEqual(resolver.plan(md5: nil, subtune: 0,
                                     databaseLengths: nil, fileURL: file), .trackNotReady)
        XCTAssertEqual(resolver.plan(md5: md5, subtune: 0,
                                     databaseLengths: nil, fileURL: nil), .trackNotReady)
        XCTAssertFalse(resolver.isEstimating)
    }

    /// Der Unterschied zwischen `.trackNotReady` und `.noLengthKnown` ist keine
    /// Wortklauberei, sondern der Grund fuer die beiden Faelle: Waehrend eines
    /// Titelwechsels steht kurz weder MD5 noch Datei-URL bereit. Wuerde die App
    /// dabei die laufende Rechnung abbrechen, bekaeme ein Tune ohne DB-Eintrag
    /// seine Laenge nie — die alte Fassung hat diesen Zustand deshalb
    /// ausdruecklich unangetastet gelassen.
    func testIncompleteInputsDoNotCancelARunningEstimate() {
        let resolver = makeResolver()
        guard case .estimate(let ticket) = resolver.plan(md5: md5, subtune: 0,
                                                         databaseLengths: nil, fileURL: file) else {
            return XCTFail("Aufruf muss rechnen")
        }

        XCTAssertEqual(resolver.plan(md5: nil, subtune: 0,
                                     databaseLengths: nil, fileURL: nil), .trackNotReady)

        XCTAssertTrue(resolver.isEstimating, "Die laufende Rechnung muss den Zwischenzustand ueberleben")
        XCTAssertEqual(resolver.accept(64.0, ticket: ticket,
                                       currentMD5: md5, currentSubtune: 0), 64.0,
                       "Ihr Ergebnis muss danach noch gelten")
    }

    /// Der negative Cache-Treffer dagegen entwertet eine laufende Rechnung —
    /// hier darf die App ihren Task abbrechen.
    func testNegativeCacheHitCancelsARunningEstimate() {
        let resolver = makeResolver()
        guard case .estimate(let ticket) = resolver.plan(md5: md5, subtune: 0,
                                                         databaseLengths: nil, fileURL: file) else {
            return XCTFail("Aufruf muss rechnen")
        }
        // Ein anderer Subtune desselben Titels ist als Loop bekannt.
        cache.store(md5: md5, subtune: 1, seconds: -1)

        XCTAssertEqual(resolver.plan(md5: md5, subtune: 1,
                                     databaseLengths: nil, fileURL: file), .noLengthKnown)

        XCTAssertFalse(resolver.isEstimating)
        XCTAssertNil(resolver.accept(64.0, ticket: ticket,
                                     currentMD5: md5, currentSubtune: 0))
    }

    // MARK: - Die Buchfuehrung ueber laufende Rechnungen

    /// Zwei unmittelbar aufeinanderfolgende Ereignisse aus der Oberflaeche
    /// duerfen dieselbe Analyse nicht zweimal starten.
    func testSameRequestTwiceReportsAlreadyRunning() {
        let resolver = makeResolver()
        let first = resolver.plan(md5: md5, subtune: 0,
                                  databaseLengths: nil, fileURL: file)
        guard case .estimate = first else { return XCTFail("erster Aufruf muss rechnen") }

        let second = resolver.plan(md5: md5, subtune: 0,
                                   databaseLengths: nil, fileURL: file)

        XCTAssertEqual(second, .alreadyRunning)
    }

    /// Ein anderer Subtune ist eine andere Rechnung — die alte wird ersetzt.
    func testDifferentSubtuneStartsANewEstimate() {
        let resolver = makeResolver()
        guard case .estimate(let first) = resolver.plan(md5: md5, subtune: 0,
                                                        databaseLengths: nil, fileURL: file) else {
            return XCTFail("erster Aufruf muss rechnen")
        }
        guard case .estimate(let second) = resolver.plan(md5: md5, subtune: 1,
                                                         databaseLengths: nil, fileURL: file) else {
            return XCTFail("anderer Subtune muss neu rechnen")
        }

        XCTAssertNotEqual(first, second)
        // Das alte Ticket ist entwertet: sein Ergebnis darf nichts mehr setzen.
        XCTAssertNil(resolver.accept(120.0, ticket: first,
                                     currentMD5: md5, currentSubtune: 0))
    }

    /// Der eigentliche Zweck des Generationszaehlers: Der Nutzer wechselt
    /// waehrend der Rechnung den Titel, das spaete Ergebnis darf den neuen
    /// Titel nicht ueberschreiben.
    func testStaleResultFromPreviousTrackIsRejected() {
        let resolver = makeResolver()
        guard case .estimate(let old) = resolver.plan(md5: md5, subtune: 0,
                                                      databaseLengths: nil, fileURL: file) else {
            return XCTFail("erster Aufruf muss rechnen")
        }

        // Titelwechsel: andere Datei, andere Rechnung.
        let otherMD5 = "FEDCBA9876543210FEDCBA9876543210"
        guard case .estimate = resolver.plan(md5: otherMD5, subtune: 0,
                                             databaseLengths: nil, fileURL: file) else {
            return XCTFail("neuer Titel muss rechnen")
        }

        XCTAssertNil(resolver.accept(200.0, ticket: old,
                                     currentMD5: otherMD5, currentSubtune: 0),
                     "Das Ergebnis des vorigen Titels darf nicht uebernommen werden")
    }

    /// Ein gueltiges Ergebnis wird angenommen und beendet die Rechnung.
    func testCurrentResultIsAccepted() {
        let resolver = makeResolver()
        guard case .estimate(let ticket) = resolver.plan(md5: md5, subtune: 0,
                                                         databaseLengths: nil, fileURL: file) else {
            return XCTFail("Aufruf muss rechnen")
        }

        XCTAssertEqual(resolver.accept(88.5, ticket: ticket,
                                       currentMD5: md5, currentSubtune: 0), 88.5)
        XCTAssertFalse(resolver.isEstimating, "Nach Annahme laeuft keine Rechnung mehr")
    }

    /// Passendes Ticket, aber der Nutzer hat inzwischen den Subtune gewechselt:
    /// Die Buchfuehrung wird geraeumt, angezeigt wird das Ergebnis nicht.
    func testResultForOldSubtuneIsNotDisplayed() {
        let resolver = makeResolver()
        guard case .estimate(let ticket) = resolver.plan(md5: md5, subtune: 0,
                                                         databaseLengths: nil, fileURL: file) else {
            return XCTFail("Aufruf muss rechnen")
        }

        XCTAssertNil(resolver.accept(88.5, ticket: ticket,
                                     currentMD5: md5, currentSubtune: 4))
        XCTAssertFalse(resolver.isEstimating)
    }

    /// Ein "kein Ende gefunden" (nil) beendet die Rechnung, ohne eine Laenge zu
    /// liefern — die App bleibt beim Fallback.
    func testNilResultEndsEstimateWithoutLength() {
        let resolver = makeResolver()
        guard case .estimate(let ticket) = resolver.plan(md5: md5, subtune: 0,
                                                         databaseLengths: nil, fileURL: file) else {
            return XCTFail("Aufruf muss rechnen")
        }

        XCTAssertNil(resolver.accept(nil, ticket: ticket,
                                     currentMD5: md5, currentSubtune: 0))
        XCTAssertFalse(resolver.isEstimating)
    }

    /// Nach einem Fehlschlag (Datei unlesbar) muss ein neuer Anlauf moeglich
    /// sein — sonst bliebe der Resolver dauerhaft auf „laeuft schon" stehen.
    func testFailedEstimateAllowsANewAttempt() {
        let resolver = makeResolver()
        guard case .estimate(let ticket) = resolver.plan(md5: md5, subtune: 0,
                                                         databaseLengths: nil, fileURL: file) else {
            return XCTFail("Aufruf muss rechnen")
        }
        resolver.fail(ticket: ticket)
        XCTAssertFalse(resolver.isEstimating)

        guard case .estimate = resolver.plan(md5: md5, subtune: 0,
                                             databaseLengths: nil, fileURL: file) else {
            return XCTFail("Nach einem Fehlschlag muss ein neuer Anlauf moeglich sein")
        }
    }

    /// Ein DB-Treffer nach dem Start einer Rechnung (die Datenbank wird im
    /// Hintergrund geladen und kann spaeter eintreffen) bricht sie ab.
    func testDatabaseArrivingLaterCancelsARunningEstimate() {
        let resolver = makeResolver()
        guard case .estimate(let ticket) = resolver.plan(md5: md5, subtune: 0,
                                                         databaseLengths: nil, fileURL: file) else {
            return XCTFail("Aufruf muss rechnen")
        }

        XCTAssertEqual(resolver.plan(md5: md5, subtune: 0,
                                     databaseLengths: [55.0], fileURL: file),
                       .databaseProvidesLength)
        XCTAssertFalse(resolver.isEstimating)
        XCTAssertNil(resolver.accept(88.5, ticket: ticket,
                                     currentMD5: md5, currentSubtune: 0),
                     "Nach dem Abbruch darf das Ergebnis nicht mehr wirken")
    }

    // MARK: - Die effektive Dauer

    func testDurationLadderPrefersDatabaseThenComputedThenFallback() {
        XCTAssertEqual(SongLengthSelection.duration(databaseLengths: [10, 20],
                                                    subtune: 1,
                                                    computed: 99),
                       20.0, "Die Datenbank hat Vorrang")
        XCTAssertEqual(SongLengthSelection.duration(databaseLengths: nil,
                                                    subtune: 0,
                                                    computed: 99),
                       99.0, "Ohne DB gilt die berechnete Laenge")
        XCTAssertEqual(SongLengthSelection.duration(databaseLengths: nil,
                                                    subtune: 0,
                                                    computed: nil),
                       360.0, "Ohne alles gilt das Fallback-Limit")
    }

    /// Dieselbe Grenzpruefung wie oben, nun auf der Anzeigeseite: ein Subtune
    /// jenseits der DB-Eintraege darf nicht ins Array greifen.
    func testDurationLadderIgnoresOutOfRangeSubtunes() {
        XCTAssertEqual(SongLengthSelection.duration(databaseLengths: [10, 20],
                                                    subtune: 5,
                                                    computed: 77),
                       77.0)
        XCTAssertEqual(SongLengthSelection.duration(databaseLengths: [10, 20],
                                                    subtune: -1,
                                                    computed: nil),
                       360.0)
    }
}
