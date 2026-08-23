import XCTest
@testable import ViciousSIDPlayerCore

// Der Audio-Koordinator ist die einzige Stelle des Cores, die echte
// Systemausgabe anfasst — deshalb gibt es hier nur genau einen Test, und der
// prueft die eine Eigenschaft, die sich sonst nur auf echter iPhone-Hardware
// zeigt: dass die Wiedergabe nach einem Neuaufbau der Audio-Engine wieder
// laeuft.
//
// Unter Linux faellt der Koordinator aus der Uebersetzung heraus (kein
// AVFoundation), deshalb die Klammer.
#if canImport(AVFoundation)
final class CoordinatorEngineTests: XCTestCase {

    /// Eine gueltige, stumme PSID-Datei: Kopf nach Spezifikation, im Code nur
    /// zwei RTS. Ohne eigene Datei liesse sich der Koordinator gar nicht
    /// starten, und eine echte SID gehoert nicht ins Repo.
    private func silentSID() -> Data {
        var d = Data(count: 0x7C)
        d.replaceSubrange(0..<4, with: Array("PSID".utf8))
        func put(_ value: UInt16, at offset: Int) {
            d[offset] = UInt8(value >> 8)
            d[offset + 1] = UInt8(value & 0xFF)
        }
        put(2, at: 4)          // Version
        put(0x7C, at: 6)       // dataOffset
        put(0x1000, at: 8)     // loadAddress
        put(0x1000, at: 10)    // initAddress
        put(0x1003, at: 12)    // playAddress
        put(1, at: 14)         // songs
        put(1, at: 16)         // startSong
        d[0x77] = 0x10         // 6581
        d.append(contentsOf: [0x60, 0x00, 0x00, 0x60])
        return d
    }

    @MainActor
    func testPlaybackWorksAgainAfterTheAudioEngineWasRebuilt() throws {
        let coordinator = ViciousCoordinator()
        let file = try SidParser.parse(data: silentSID())
        coordinator.setSid(file)

        coordinator.play()
        try XCTSkipUnless(coordinator.isPlaying,
                          "Kein nutzbares Audiogeraet — der Test sagt hier nichts aus.")

        // Das ist der Fall nach `mediaServicesWereReset`: Die alte Engine ist
        // tot, die App muss eine neue anlegen.
        coordinator.rebuildAudioEngine()
        XCTAssertEqual(coordinator.audioEngineGeneration, 1)
        XCTAssertFalse(coordinator.isPlaying, "Der Neuaufbau haelt an wie stop()")
        XCTAssertEqual(coordinator.elapsedSeconds, 0.0)

        coordinator.play()
        XCTAssertTrue(coordinator.isPlaying,
                      "Mit der alten, ungueltigen Engine bliebe die App dauerhaft stumm")
        coordinator.stop()
    }
}
#endif
