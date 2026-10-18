import XCTest
@testable import ViciousSIDPlayerCore

final class SIDFilterCurveTests: XCTestCase {
    private enum ProbeError: Error { case nonFinite }

    func testReferenceValuesAndStableCoefficientsAcrossSupportedRates() {
        let reference = SIDFilterCurve.coefficients6581(sampleRate: 44100)
        XCTAssertEqual(reference[190], 0.035)
        XCTAssertEqual(reference[191], 0.033899302569728396)
        XCTAssertEqual(reference[2047], 0.9269683318933072)
        let adjusted = SIDFilterCurve.coefficients6581(sampleRate: 48000)
        XCTAssertEqual(adjusted[190], 0.03220255966959873, accuracy: 1e-15)
        XCTAssertEqual(adjusted[191], 0.031188409321508237, accuracy: 1e-15)
        for rate in [8000.0, 22050, 32000, 44100, 48000, 96000, 192000] {
            let coefficients = SIDFilterCurve.coefficients6581(sampleRate: rate)
            XCTAssertEqual(coefficients.count, 2048)
            XCTAssertTrue(coefficients.allSatisfy { $0.isFinite && $0 > 0 && $0 < 1 })
        }
    }

    // Eigener Sägezahnton: nach 200 PAL-Frames wechselt Cutoff 190 auf 191.
    private func fixture() throws -> SidFileData {
        let code: [UInt8] = [
            0xa9,0,0x8d,0,0xd4, 0xa9,12,0x8d,1,0xd4,
            0xa9,0,0x8d,5,0xd4, 0xa9,0xf0,0x8d,6,0xd4,
            0xa9,0x21,0x8d,4,0xd4, 0xa9,6,0x8d,0x15,0xd4,
            0xa9,23,0x8d,0x16,0xd4, 0xa9,1,0x8d,0x17,0xd4,
            0xa9,0x1f,0x8d,0x18,0xd4, 0xa9,0,0x8d,2,0,0x60,
            0xe6,2,0xa5,2,0xc9,200,0x90,12,0xa9,0,0x85,2,
            0xad,0x15,0xd4,0x49,1,0x8d,0x15,0xd4,0x60
        ]
        var data = Data(count: 124)
        data.replaceSubrange(0..<4, with: "PSID".utf8)
        func put(_ value: Int, _ offset: Int) { data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255) }
        put(2, 4); put(124, 6); put(0x1000, 8); put(0x1000, 10)
        put(0x1033, 12); put(1, 14); put(1, 16); put(0x14, 118)
        return try SidParser.parse(data: data + Data(code))
    }

    private func render(rate: Int) throws -> (pcm: Data, changeDB: Double) {
        let p = ViciousProcessor(sampleRate: Double(rate))
        _ = p.loadSID(sidFile: try fixture()); p.initSubtune(sub: 0); p.setVolume(vol: 1)
        var pcm = Data(), sums = [0.0, 0.0], squares = [0.0, 0.0], counts = [0, 0]
        for frame in 0..<(rate * 8) {
            let value = p.play()
            guard value.isFinite else { throw ProbeError.nonFinite }
            var sample = Int16(max(-1.0, min(1.0, value)) * 32767).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
            let second = frame / rate
            if (1..<3).contains(second) || (5..<7).contains(second) {
                let window = second < 4 ? 0 : 1, v = Double(Int16(littleEndian: sample)) / 32768
                sums[window] += v; squares[window] += v * v; counts[window] += 1
            }
        }
        let rms = (0..<2).map { i in
            let n = Double(counts[i]), mean = sums[i] / n
            return sqrt(squares[i] / n - mean * mean)
        }
        return (pcm, 20 * log10(rms[1] / rms[0]))
    }

    func test44100RemainsBitExactAnd48000AvoidsTheCutoffDrop() throws {
        let reference = try render(rate: 44100), adjusted = try render(rate: 48000)
        // PCM-Prüfsumme des freigegebenen 44,1-kHz-Prüfsignals aus v1.9.46.
        XCTAssertEqual(MD5.hexString(of: reference.pcm), "96a6bebb36bf3d3756d594cc1dd96ed3")
        XCTAssertLessThan(abs(adjusted.changeDB), 0.5)
        XCTAssertEqual(adjusted.changeDB, reference.changeDB, accuracy: 0.02)
    }
}
