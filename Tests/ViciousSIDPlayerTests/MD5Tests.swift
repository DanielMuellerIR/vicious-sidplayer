import XCTest
@testable import ViciousSIDPlayerCore

#if canImport(CryptoKit)
import CryptoKit
#endif

// Tests fuer die eigene MD5-Implementierung (Sources/ViciousSIDPlayerCore/MD5.swift).
// Sie ersetzt CryptoKit, damit der Core auch auf Linux baut — und sie liefert den
// Lookup-Schluessel der HVSC-DB. Ein falscher Hash hiesse: keine Songlaengen mehr.
final class MD5Tests: XCTestCase {

    // Hilfsfunktion: Hex-Hash eines UTF-8-Strings.
    private func md5(_ string: String) -> String {
        return MD5.hexString(of: Data(string.utf8))
    }

    // Die offizielle Test-Suite aus RFC 1321, Anhang A.5. Deckt u.a. den leeren
    // Eingang und Laengen quer ueber die Blockgrenze (80 Byte = 1 voller Block + 16) ab.
    func testRFC1321TestSuite() {
        XCTAssertEqual(md5(""), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(md5("a"), "0cc175b9c0f1b6a831c399e269772661")
        XCTAssertEqual(md5("abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(md5("message digest"), "f96b697d7cb7938d525a2f31aaf161d0")
        XCTAssertEqual(md5("abcdefghijklmnopqrstuvwxyz"), "c3fcd3d76192e4007dfb496cca67e13b")
        XCTAssertEqual(
            md5("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
            "d174ab98d277d9f5a5611c2c9f419d9f"
        )
        XCTAssertEqual(
            md5(String(repeating: "1234567890", count: 8)),
            "57edf4a22be3c955ac49da2e2107b67a"
        )
    }

    // Rueckgabeformat: 16 Bytes roh, 32 Zeichen lowercase Hex ohne Trenner.
    // Die HVSC-DB-Schluessel haengen exakt daran.
    func testDigestShapeAndHexFormat() {
        let digest = MD5.hash(data: Data("abc".utf8))
        XCTAssertEqual(digest.count, 16)
        XCTAssertEqual(digest.first, 0x90)
        XCTAssertEqual(digest.last, 0x72)

        let hex = md5("abc")
        XCTAssertEqual(hex.count, 32)
        XCTAssertEqual(hex, hex.lowercased())
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit })
    }

    // Der oeffentliche Einstiegspunkt der DB muss dasselbe liefern wie MD5 direkt.
    func testSonglengthDBMD5HexMatches() {
        let data = Data("message digest".utf8)
        XCTAssertEqual(SonglengthDB.md5Hex(of: data), "f96b697d7cb7938d525a2f31aaf161d0")
        XCTAssertEqual(SonglengthDB.md5Hex(of: data), MD5.hexString(of: data))
    }

    // Deterministische Testdaten fuer den Laengen-Sweep: byte = i % 251
    // (251 ist prim und teilerfremd zu 64 — so wiederholt sich kein Blockmuster).
    private func sweepData(length: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for i in 0..<length {
            bytes.append(UInt8(i % 251))
        }
        return Data(bytes)
    }

    // Laengen-Sweep 0...130 Byte: trifft jede Padding-Variante, insbesondere die
    // Sonderfaelle an der Blockgrenze — 55 (Laenge passt noch in den Block),
    // 56 (Laengenfeld passt NICHT mehr, ein Zusatzblock entsteht), 63, 64
    // (exakt voll), 119/120 und 128. Gegengeprueft wird gegen die Referenz-Hashes
    // aus einer unabhaengigen Implementierung.
    func testLengthSweepAgainstKnownDigests() {
        // Referenzwerte, unabhaengig erzeugt (Python hashlib.md5) — also NICHT von
        // der zu testenden Implementierung selbst. Die Laengen sind genau die
        // Padding-Sonderfaelle: 55/56 an der 56er-Grenze, 63/64 an der Blockgrenze,
        // 119/120 und 127/128 an der naechsten.
        let expected: [Int: String] = [
            0:   "d41d8cd98f00b204e9800998ecf8427e",
            1:   "93b885adfe0da089cdf634904fd59f71",
            55:  "6912ee65fff2d9f9ce2508cddf8bcda0",
            56:  "51fdd1acda72405dfdfa03fcb85896d7",
            63:  "48a6295221902e8e0938f773a7185e72",
            64:  "b2d3f56bc197fd985d5965079b5e7148",
            65:  "8bd7053801c768420faf816fadba971c",
            119: "1c772251899a7ff007400b888d6b2042",
            120: "b7ba1efc6022e9ed272f00b8831e26e6",
            127: "8402b21e7bc7906493bae0dac017f1f9",
            128: "37eff01866ba3f538421b30b7cbefcac",
            130: "7c05c285d0263c40a0437421b387a2a1",
        ]
        for (length, hex) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(
                MD5.hexString(of: sweepData(length: length)),
                hex,
                "Laenge \(length): Hash weicht vom Referenzwert ab"
            )
        }

        // Jede Laenge muss einen wohlgeformten, eindeutigen Hash liefern.
        // Verschiedene Laengen duerfen nie kollidieren — genau das passiert bei
        // kaputtem Padding (z.B. wenn das Laengenfeld vergessen wird).
        var seen = Set<String>()
        for length in 0...130 {
            let hex = MD5.hexString(of: sweepData(length: length))
            XCTAssertEqual(hex.count, 32, "Laenge \(length): Hex-Laenge falsch")
            XCTAssertTrue(seen.insert(hex).inserted, "Laenge \(length): Hash-Kollision")
        }
    }

    // KREUZVERGLEICH gegen CryptoKit — der eigentliche Korrektheitsbeweis.
    // Laeuft nur auf Apple-Plattformen; auf Linux existiert CryptoKit nicht.
    // Deckt denselben Laengen-Sweep 0...130 ab, also alle Padding-Sonderfaelle.
    #if canImport(CryptoKit)
    func testCrossCheckAgainstCryptoKit() {
        for length in 0...130 {
            let data = sweepData(length: length)
            let reference = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(
                MD5.hexString(of: data),
                reference,
                "Eigene MD5 weicht bei Laenge \(length) von CryptoKit ab"
            )
        }
    }

    // Kreuzvergleich mit groesseren, unregelmaessigen Laengen: mehrere volle
    // Bloecke plus krummer Rest — so wie echte SID-Dateien aussehen.
    func testCrossCheckAgainstCryptoKitLargeInputs() {
        for length in [255, 256, 257, 511, 512, 513, 1000, 4096, 65535] {
            let data = sweepData(length: length)
            let reference = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(
                MD5.hexString(of: data),
                reference,
                "Eigene MD5 weicht bei Laenge \(length) von CryptoKit ab"
            )
        }
    }
    #endif
}
