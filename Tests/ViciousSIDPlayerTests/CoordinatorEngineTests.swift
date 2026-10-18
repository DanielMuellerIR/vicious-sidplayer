import XCTest
@testable import ViciousSIDPlayerCore

// Der Koordinator beruehrt echte Audioausgabe. Ohne AVFoundation fallen
// diese Tests weg; ohne nutzbares Audiogeraet ueberspringen sie den Lauf.
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
    func testFilenameFallbackOnlyReplacesMissingHeaderTitles() throws {
        let coordinator = ViciousCoordinator()
        let empty = try SidParser.parse(data: silentSID())
        coordinator.setSid(empty, fallbackTitle: "BotB 35682")
        XCTAssertEqual(coordinator.trackName, "BotB 35682")
        coordinator.setSid(empty, fallbackTitle: "  ")
        XCTAssertEqual(coordinator.trackName, empty.metadata.title)
        var data = silentSID()
        data.replaceSubrange(22..<27, with: "Title".utf8)
        coordinator.setSid(try SidParser.parse(data: data), fallbackTitle: "Filename")
        XCTAssertEqual(coordinator.trackName, "Title")
    }

    @MainActor
    func testLongSeekKeepsMainActorFreeAndStopInvalidatesPreparation() async throws {
        let coordinator = ViciousCoordinator()
        coordinator.setSid(try SidParser.parse(data: silentSID()))
        coordinator.play()
        try XCTSkipUnless(coordinator.isPlaying, "Kein nutzbares Audiogeraet")
        let start = Date()
        coordinator.seek(seconds: 300)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertTrue(coordinator.isPreparingSeek)
        coordinator.seek(seconds: 1)
        let deadline = Date().addingTimeInterval(5)
        while coordinator.isPreparingSeek && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(coordinator.isPreparingSeek)
        XCTAssertEqual(coordinator.elapsedSeconds, 1, accuracy: 0.2)
        coordinator.seek(seconds: 300)
        coordinator.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(coordinator.isPreparingSeek)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(coordinator.elapsedSeconds, 0)
    }

    @MainActor
    func testSubtuneDuringClockPreparationUsesTheSelectedClock() async throws {
        var data = silentSID()
        data[15] = 2
        data.replaceSubrange(0x7C..<data.count, with: [0x60,0,0,0xEE,0,0xD4,0x60])
        let coordinator = ViciousCoordinator()
        coordinator.setSid(try SidParser.parse(data: data)); coordinator.setVolume(0)
        coordinator.setUIUpdateInterval(0.01)
        coordinator.play(); defer { coordinator.stop() }
        try XCTSkipUnless(coordinator.isPlaying, "Kein nutzbares Audiogeraet")
        coordinator.seek(seconds: 300)
        coordinator.setClockMode(.ntsc)
        coordinator.setSubtune(sub: 1)
        XCTAssertFalse(coordinator.isPreparingSeek)
        try await Task.sleep(for: .seconds(2))
        let visuals = coordinator.currentVisuals()
        XCTAssertGreaterThan(coordinator.elapsedSeconds, 1.5)
        // Die Anzeigezeit ist auf Zehntelsekunden gedrosselt; der Registerpuffer
        // kann deshalb schon bis zu etwa 0,13 Sekunden weiter sein.
        XCTAssertEqual(Double(visuals.frequencies[0]), 60 * coordinator.elapsedSeconds, accuracy: 8)
        XCTAssertEqual(coordinator.currentSubtune, 1)
    }

    @MainActor
    func testSlowerUIRefreshKeepsEmulationRunningAndRecoversOnReturn() async throws {
        var data = silentSID()
        data.replaceSubrange(0x7C..<data.count, with: [0x60, 0, 0, 0xEE, 0, 0xD4, 0x60])
        let coordinator = ViciousCoordinator()
        coordinator.setSid(try SidParser.parse(data: data)); coordinator.setVolume(0)
        coordinator.play(); defer { coordinator.stop() }
        try XCTSkipUnless(coordinator.isPlaying, "Kein nutzbares Audiogeraet")
        try await Task.sleep(for: .milliseconds(400))
        let before = coordinator.currentVisuals().frequencies[0]
        let elapsedBefore = coordinator.elapsedSeconds

        coordinator.setUIUpdateInterval(1)
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertGreaterThan(coordinator.currentVisuals().frequencies[0], before + 40,
                             "Die Play-Routine muss unabhaengig vom UI-Timer weiterlaufen.")
        XCTAssertGreaterThan(coordinator.elapsedSeconds, elapsedBefore + 0.7)

        let elapsedHidden = coordinator.elapsedSeconds
        coordinator.setUIUpdateInterval(0.1)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertGreaterThan(coordinator.elapsedSeconds, elapsedHidden + 0.2)
        XCTAssertFalse(coordinator.isPaused)
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
