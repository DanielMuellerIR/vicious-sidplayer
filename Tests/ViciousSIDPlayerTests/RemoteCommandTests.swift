import XCTest
@testable import ViciousSIDPlayerCore

// Tests fuer die Fernsteuerung ueber das URL-Schema.
//
// Der Schwerpunkt liegt auf dem, was NICHT durchkommen darf: Ein URL-Schema
// kann jede Webseite ausloesen, und die Pruefung hier ist die einzige Huerde
// davor.
final class RemoteCommandTests: XCTestCase {

    private func parse(_ string: String) -> RemoteCommand? {
        guard let url = URL(string: string) else { return nil }
        return RemoteCommand.parse(url)
    }

    // MARK: - Wiedergabesteuerung

    func testPlaybackCommands() {
        XCTAssertEqual(parse("vicioussid://play"), .play)
        XCTAssertEqual(parse("vicioussid://pause"), .pause)
        XCTAssertEqual(parse("vicioussid://playpause"), .playPause)
        XCTAssertEqual(parse("vicioussid://toggle"), .playPause)
        XCTAssertEqual(parse("vicioussid://stop"), .stop)
        XCTAssertEqual(parse("vicioussid://next"), .next)
        XCTAssertEqual(parse("vicioussid://previous"), .previous)
        XCTAssertEqual(parse("vicioussid://prev"), .previous)
    }

    func testCommandNameIsCaseInsensitive() {
        XCTAssertEqual(parse("VICIOUSSID://Next"), .next)
    }

    // Ohne Doppelschraegstrich steht der Name im Pfad statt im Host — beide
    // Schreibweisen kommen aus Skripten und Kurzbefehlen.
    func testCommandWithoutDoubleSlashWorksToo() {
        XCTAssertEqual(parse("vicioussid:next"), .next)
    }

    func testUnknownCommandIsRejected() {
        XCTAssertNil(parse("vicioussid://quit"))
        XCTAssertNil(parse("vicioussid://"))
        XCTAssertNil(parse("https://example.com/next"))
    }

    // MARK: - Sprung und Subtune

    func testSeekTakesSeconds() {
        XCTAssertEqual(parse("vicioussid://seek?seconds=90.5"), .seek(seconds: 90.5))
        XCTAssertEqual(parse("vicioussid://seek?seconds=0"), .seek(seconds: 0))
    }

    func testSeekRejectsNonsense() {
        XCTAssertNil(parse("vicioussid://seek"), "ohne Wert kein Sprung")
        XCTAssertNil(parse("vicioussid://seek?seconds=-5"))
        XCTAssertNil(parse("vicioussid://seek?seconds=abc"))
        XCTAssertNil(parse("vicioussid://seek?seconds=inf"))
        XCTAssertNil(parse("vicioussid://seek?seconds=999999999"),
                     "Laenger als ein Tag ist kein Musikstueck")
    }

    func testSubtuneIsZeroBasedAndBounded() {
        XCTAssertEqual(parse("vicioussid://subtune?index=0"), .subtune(index: 0))
        XCTAssertEqual(parse("vicioussid://subtune?index=255"), .subtune(index: 255))
        XCTAssertNil(parse("vicioussid://subtune?index=-1"))
        XCTAssertNil(parse("vicioussid://subtune?index=256"))
        XCTAssertNil(parse("vicioussid://subtune?index=zwei"))
    }

    // MARK: - Titelauswahl: die sicherheitsrelevante Stelle

    func testTrackTakesAPathInsideTheLibrary() {
        XCTAssertEqual(parse("vicioussid://track?path=Hubbard_Rob/Commando.sid"),
                       .track(id: "Hubbard_Rob/Commando.sid"))
        XCTAssertEqual(parse("vicioussid://track?path=Commando.sid"),
                       .track(id: "Commando.sid"))
    }

    func testTrackWithPercentEncodingIsDecoded() {
        XCTAssertEqual(parse("vicioussid://track?path=Martin%20Galway/Wizball.sid"),
                       .track(id: "Martin Galway/Wizball.sid"))
    }

    // Der Kern der Absicherung: Aus dem Autoplay-Ordner darf keine URL
    // herausfuehren, und etwas anderes als eine SID-Datei gibt es nicht.
    func testTrackRejectsEverythingThatLeavesTheLibrary() {
        XCTAssertNil(parse("vicioussid://track?path=/etc/passwd"))
        XCTAssertNil(parse("vicioussid://track?path=../../geheim.sid"))
        XCTAssertNil(parse("vicioussid://track?path=Ordner/../../weg.sid"))
        XCTAssertNil(parse("vicioussid://track?path=~/Musik/x.sid"))
        XCTAssertNil(parse("vicioussid://track?path="))
        XCTAssertNil(parse("vicioussid://track"))
    }

    func testTrackRejectsAnythingThatIsNotASIDFile() {
        XCTAssertNil(parse("vicioussid://track?path=Dokumente/steuer.pdf"))
        XCTAssertNil(parse("vicioussid://track?path=Ordner/"))
        XCTAssertEqual(parse("vicioussid://track?path=Gross.SID"), .track(id: "Gross.SID"),
                       "Sammlungen aus dem Netz mischen .sid und .SID")
    }

    // Doppelte Angaben: der erste Wert gilt, still den zweiten zu nehmen waere
    // ueberraschend.
    func testFirstValueOfARepeatedParameterWins() {
        XCTAssertEqual(parse("vicioussid://subtune?index=1&index=9"), .subtune(index: 1))
    }
}
