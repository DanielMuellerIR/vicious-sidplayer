import Foundation

// MD5 nach RFC 1321 — bewusst als Eigenbau im Core.
//
// WARUM Eigenbau: Bis hierher kommt der MD5 von Apples CryptoKit
// (`Insecure.MD5`). CryptoKit gibt es auf Linux nicht, und damit liesse sich der
// Core dort ueberhaupt nicht bauen. Eine Fremdabhaengigkeit (z.B. swift-crypto)
// waere die erste des Repos — das bleibt bewusst so, das Projekt ist
// abhaengigkeitsfrei. MD5 ist hier klein genug, um ihn selbst zu halten.
//
// KEIN SICHERHEITSMERKMAL: MD5 gilt seit langem als gebrochen (Kollisionen sind
// praktisch erzeugbar) und wird hier ausdruecklich NICHT fuer Sicherheitszwecke
// benutzt. Er ist ausschliesslich der Lookup-Schluessel der HVSC-Datenbank
// `Songlengths.md5`, die jede SID-Datei ueber den MD5 ihres Inhalts adressiert.
// Das Format ist vorgegeben — deshalb MD5 und nichts Moderneres.
//
// Wie MD5 grob funktioniert (fuer Einsteiger):
//   1. Die Eingabe wird auf ein Vielfaches von 64 Byte aufgefuellt ("Padding").
//   2. Ein 128-Bit-Zustand (vier 32-Bit-Register A/B/C/D) startet auf feste Werte.
//   3. Jeder 64-Byte-Block wird als 16 kleine 32-Bit-Zahlen gelesen und in
//      64 Runden mit dem Zustand verrechnet (Mischen aus AND/OR/XOR, Addition,
//      Bit-Rotation). Danach wird das Rundenergebnis auf den alten Zustand addiert.
//   4. Am Ende sind die vier Register — little-endian aneinandergehaengt —
//      der 16-Byte-Hash.
public enum MD5 {

    // Rundenkonstanten K[i] = floor(abs(sin(i + 1)) * 2^32), fest aus RFC 1321.
    // Sie sind reine "Nothing-up-my-sleeve"-Zahlen: sie sollen die Bits gut
    // durchmischen, ohne dass jemand sie sich passend ausgesucht haben koennte.
    private static let k: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    // Rotationsweiten s[i]: je Runden-Viertel wiederholt sich ein 4er-Muster.
    // Die wechselnden Weiten sorgen dafuer, dass sich eine Bit-Aenderung schnell
    // ueber das ganze Register verteilt ("Avalanche").
    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    // Der 128-Bit-Zustand. Die Startwerte sind in RFC 1321 festgeschrieben.
    private struct State {
        var a: UInt32 = 0x67452301
        var b: UInt32 = 0xefcdab89
        var c: UInt32 = 0x98badcfe
        var d: UInt32 = 0x10325476

        // Verarbeitet genau einen 64-Byte-Block.
        // `block` zeigt auf 64 Byte Eingabe, `m` ist ein von aussen einmalig
        // bereitgestellter Scratch-Puffer fuer die 16 Woerter — so allozieren wir
        // nicht pro Block (die HVSC hat >50k Dateien, das laeppert sich).
        mutating func processBlock(_ block: UnsafeRawPointer, m: UnsafeMutablePointer<UInt32>) {
            // 64 Byte -> 16 Woerter zu je 32 Bit, little-endian.
            // Byteweise gelesen, damit auch unausgerichtete Zeiger sicher sind.
            for i in 0..<16 {
                let o = i * 4
                let b0 = UInt32(block.load(fromByteOffset: o + 0, as: UInt8.self))
                let b1 = UInt32(block.load(fromByteOffset: o + 1, as: UInt8.self))
                let b2 = UInt32(block.load(fromByteOffset: o + 2, as: UInt8.self))
                let b3 = UInt32(block.load(fromByteOffset: o + 3, as: UInt8.self))
                m[i] = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            }

            // Mit einer Kopie des Zustands rechnen; am Ende wird sie aufaddiert.
            var aa = a, bb = b, cc = c, dd = d

            for i in 0..<64 {
                var f: UInt32
                var g: Int
                // Vier Runden-Viertel mit je eigener Mischfunktion und eigener
                // Reihenfolge, in der die 16 Woerter angefasst werden. Genau das
                // verhindert, dass Wortpositionen "durchschlagen".
                switch i {
                case 0..<16:
                    f = (bb & cc) | (~bb & dd)          // F: waehlt bitweise C oder D
                    g = i                                // Woerter der Reihe nach
                case 16..<32:
                    f = (dd & bb) | (~dd & cc)          // G: waehlt bitweise B oder C
                    g = (5 * i + 1) % 16
                case 32..<48:
                    f = bb ^ cc ^ dd                    // H: reines XOR (Paritaet)
                    g = (3 * i + 5) % 16
                default:
                    f = cc ^ (bb | ~dd)                 // I
                    g = (7 * i) % 16
                }

                f = f &+ aa &+ MD5.k[i] &+ m[g]
                // Register rotieren: A<-D<-C<-B, und B bekommt das rotierte Ergebnis.
                aa = dd
                dd = cc
                cc = bb
                bb = bb &+ MD5.rotateLeft(f, by: MD5.s[i])
            }

            // Rundenergebnis auf den bisherigen Zustand addieren (mod 2^32).
            // Diese Addition macht die Blockverarbeitung nicht-umkehrbar.
            a = a &+ aa
            b = b &+ bb
            c = c &+ cc
            d = d &+ dd
        }

        // Zustand -> 16 Byte, jedes Register little-endian.
        func digest() -> [UInt8] {
            var out = [UInt8]()
            out.reserveCapacity(16)
            for word in [a, b, c, d] {
                out.append(UInt8(truncatingIfNeeded: word))
                out.append(UInt8(truncatingIfNeeded: word >> 8))
                out.append(UInt8(truncatingIfNeeded: word >> 16))
                out.append(UInt8(truncatingIfNeeded: word >> 24))
            }
            return out
        }
    }

    // Bit-Rotation nach links (die oben herausfallenden Bits kommen unten wieder rein).
    @inline(__always)
    private static func rotateLeft(_ x: UInt32, by n: UInt32) -> UInt32 {
        return (x << n) | (x >> (32 - n))
    }

    /// MD5 der Daten als 16 Bytes.
    public static func hash(data: Data) -> [UInt8] {
        var state = State()

        // Die Laenge geht in BITS ins Padding ein, nicht in Bytes.
        // `&*` weil die Multiplikation bei absurden Groessen sonst fallen wuerde;
        // RFC 1321 definiert das Feld ohnehin nur modulo 2^64.
        let bitCount = UInt64(data.count) &* 8

        // Scratch fuer die 16 Blockwoerter: einmal fuer den ganzen Hash, nicht pro Block.
        let words = UnsafeMutablePointer<UInt32>.allocate(capacity: 16)
        defer { words.deallocate() }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let count = raw.count
            var offset = 0

            // 1. Alle vollstaendigen 64-Byte-Bloecke direkt aus der Eingabe hashen.
            while offset + 64 <= count {
                state.processBlock(raw.baseAddress!.advanced(by: offset), m: words)
                offset += 64
            }

            // 2. Rest (0..63 Byte) plus Padding in einen Abschlusspuffer bauen.
            //    Padding-Regel aus RFC 1321:
            //      - ein 1-Bit anhaengen, also das Byte 0x80,
            //      - mit 0x00 auffuellen, bis die Laenge ≡ 56 (mod 64) ist,
            //      - dann 8 Byte Bit-Laenge little-endian.
            //    Wichtig: das 0x80 wird IMMER angehaengt. Ist der Rest >= 56, passt
            //    das Laengenfeld nicht mehr in denselben Block — dann werden es zwei
            //    Abschlussbloecke (deshalb 128 Byte Puffer). Bei Rest == 56 heisst
            //    das: ein voller Block Padding kommt dazu, obwohl die Laenge "passen"
            //    wuerde. Genau hier gehen naive Implementierungen kaputt.
            var tail = [UInt8](repeating: 0, count: 128)
            let rest = count - offset
            for i in 0..<rest {
                tail[i] = raw[offset + i]
            }
            tail[rest] = 0x80

            let tailBlocks = (rest < 56) ? 1 : 2
            let lengthOffset = tailBlocks * 64 - 8
            for i in 0..<8 {
                tail[lengthOffset + i] = UInt8(truncatingIfNeeded: bitCount >> (8 * UInt64(i)))
            }

            tail.withUnsafeBytes { (t: UnsafeRawBufferPointer) in
                for block in 0..<tailBlocks {
                    state.processBlock(t.baseAddress!.advanced(by: block * 64), m: words)
                }
            }
        }

        return state.digest()
    }

    /// MD5 der Daten als lowercase-Hex-String ohne Trenner (32 Zeichen).
    public static func hexString(of data: Data) -> String {
        // Handgebaut statt String(format:) — das ist deutlich schneller und
        // vermeidet auf Linux die Foundation-Formatierung.
        let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                                   "8", "9", "a", "b", "c", "d", "e", "f"]
        var out = ""
        out.reserveCapacity(32)
        for byte in hash(data: data) {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return out
    }
}
