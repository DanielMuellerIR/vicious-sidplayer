import XCTest
@testable import ViciousSIDPlayerCore

final class ViciousTests: XCTestCase {
    func testViciousSynthesis() throws {
        // 1. Locate the test SID file
        let currentDir = FileManager.default.currentDirectoryPath
        let projectDir = URL(fileURLWithPath: currentDir)
        let sidURL = projectDir.appendingPathComponent("audio/Cybernoid.sid")
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidURL.path), "Test SID file should exist at \(sidURL.path)")
        
        // 2. Parse the SID file
        let data = try Data(contentsOf: sidURL)
        let sidFile = try SidParser.parse(data: data)
        
        XCTAssertEqual(sidFile.metadata.title, "Cybernoid")
        XCTAssertEqual(sidFile.metadata.author, "Jeroen Tel")
        
        // 3. Initialize processor
        print("DEBUG parser: loadAddr = \(String(format: "0x%04X", sidFile.loadAddr)), initAddr = \(String(format: "0x%04X", sidFile.initAddr)), playAddr = \(String(format: "0x%04X", sidFile.playAddr))")
        print("DEBUG parser: binaryData count = \(sidFile.binaryData.count), first 16 bytes: \(sidFile.binaryData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))")
        let processor = ViciousProcessor(sampleRate: 44100.0)
        _ = processor.loadSID(sidFile: sidFile)
        
        // 4. Initialize subtune
        processor.initSubtune(sub: 0)
        processor.setVolume(vol: 1.0)
        
        // 5. Synthesize 5 seconds of audio to verify oscillation and timing
        var nonZeroCount = 0
        let totalSamples = 44100 * 5
        var maxSample: Double = 0.0
        var minSample: Double = 0.0
        
        for _ in 0..<totalSamples {
            let sample = processor.play()
            if abs(sample) > 0.000001 {
                nonZeroCount += 1
            }
            maxSample = max(maxSample, sample)
            minSample = min(minSample, sample)
        }
        
        let liveData = processor.getChannelsData()
        print("DEBUG final live channels data: envelopes=\(liveData.envelopes), frequencies=\(liveData.frequencies), gates=\(liveData.gates), waveforms=\(liveData.waveforms), pulsewidths=\(liveData.pulsewidths)")
        print("Test Synthesis Results: non-zero samples = \(nonZeroCount) / \(totalSamples), min = \(minSample), max = \(maxSample)")
        
        // Cybernoid should not be completely silent!
        XCTAssertGreaterThan(nonZeroCount, 1000, "Audio should oscillate and not be silent")
        
        // 6. Test Seek logic
        processor.seek(seconds: 10.0)
        let sampleAfterSeek = processor.play()
        print("Sample after seek: \(sampleAfterSeek)")
        
        // 7. Test Subtune changing
        processor.initSubtune(sub: 1)
        let sampleSubtune1 = processor.play()
        print("Sample subtune 1: \(sampleSubtune1)")
    }
}
