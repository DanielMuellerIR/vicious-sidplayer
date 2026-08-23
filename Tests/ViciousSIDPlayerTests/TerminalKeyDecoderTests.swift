import XCTest
@testable import ViciousSIDPlayerCore

// Tests fuer das Zusammensetzen von Terminaltasten aus einzelnen Bytes.
final class TerminalKeyDecoderTests: XCTestCase {

    /// Schickt eine Folge von Bytes durch und sammelt, was dabei herauskommt.
    private func decode(_ bytes: [UInt8]) -> [TerminalKeyDecoder.Key] {
        var decoder = TerminalKeyDecoder()
        return bytes.compactMap { decoder.feed($0) }
    }

    func testPlainBytesComeThroughUnchanged() {
        XCTAssertEqual(decode(Array("np q".utf8)),
                       [.byte(UInt8(ascii: "n")), .byte(UInt8(ascii: "p")),
                        .byte(UInt8(ascii: " ")), .byte(UInt8(ascii: "q"))])
    }

    func testControlCStaysAPlainByte() {
        XCTAssertEqual(decode([0x03]), [.byte(0x03)],
                       "Im Rohmodus kommt Strg-C als Byte herein, nicht als Signal")
    }

    // Der eigentliche Anlass: Ohne Zusammensetzen landete bei „links" ein „D"
    // als Buchstabe in der Tastenauswertung.
    func testArrowKeysAreAssembledFromTheirEscapeSequence() {
        XCTAssertEqual(decode([0x1B, 0x5B, 0x41]), [.up])
        XCTAssertEqual(decode([0x1B, 0x5B, 0x42]), [.down])
        XCTAssertEqual(decode([0x1B, 0x5B, 0x43]), [.right])
        XCTAssertEqual(decode([0x1B, 0x5B, 0x44]), [.left])
    }

    // Manche Terminals schicken die Pfeiltasten im Anwendungsmodus mit „O"
    // statt „[".
    func testApplicationModeSequencesWorkToo() {
        XCTAssertEqual(decode([0x1B, 0x4F, 0x43]), [.right])
    }

    func testTwoArrowsInARowAreBothRecognized() {
        XCTAssertEqual(decode([0x1B, 0x5B, 0x43, 0x1B, 0x5B, 0x44]), [.right, .left])
    }

    func testKeyRightAfterAnArrowIsNotSwallowed() {
        XCTAssertEqual(decode([0x1B, 0x5B, 0x43, UInt8(ascii: "q")]),
                       [.right, .byte(UInt8(ascii: "q"))])
    }

    func testUnknownSequenceIsSwallowedInsteadOfBecomingALetter() {
        // "Bild auf" ist 0x1B [ 5 ~ — das „5" darf nicht als Ziffer durchgehen.
        XCTAssertEqual(decode([0x1B, 0x5B, 0x35]), [])
    }

    // Ohne die Zeitmeldung haengt ein einzelner Druck auf Escape ewig in der
    // Maschine.
    func testALonePressOnEscapeIsReportedAfterTheTimeout() {
        var decoder = TerminalKeyDecoder()
        XCTAssertNil(decoder.feed(0x1B))
        XCTAssertEqual(decoder.idleTimeout(), .byte(0x1B))
        XCTAssertNil(decoder.idleTimeout(), "Nur einmal — danach ist die Maschine leer")
    }

    func testAHalfReadSequenceIsDroppedAfterTheTimeout() {
        var decoder = TerminalKeyDecoder()
        XCTAssertNil(decoder.feed(0x1B))
        XCTAssertNil(decoder.feed(0x5B))
        XCTAssertNil(decoder.idleTimeout(), "Eine offene Klammer allein ist keine Taste")
        XCTAssertEqual(decoder.feed(UInt8(ascii: "n")), .byte(UInt8(ascii: "n")),
                       "Danach geht es normal weiter")
    }

    // Alt+Taste schickt Escape und dann das Zeichen. Das Zeichen soll gelten.
    func testEscapeFollowedByALetterYieldsTheLetter() {
        XCTAssertEqual(decode([0x1B, UInt8(ascii: "n")]), [.byte(UInt8(ascii: "n"))])
    }
}
