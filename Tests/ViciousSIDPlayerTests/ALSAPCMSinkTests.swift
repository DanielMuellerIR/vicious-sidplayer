#if os(Linux)
import XCTest
@testable import ViciousSIDPlayerCore

final class ALSAPCMSinkTests: XCTestCase {
    func testInvalidFormatEndsSinkAndRejectsRestart() throws {
        for rate in [0.0, Double.nan, Double.infinity] {
            let sink = ALSAPCMSink(format: PCMFormat(sampleRate: rate, channels: 1))
            XCTAssertThrowsError(try sink.start { _, _ in 0 }) { error in
                guard case PCMSinkError.unsupportedFormat = error else {
                    return XCTFail("Unerwarteter Fehler: \(error)")
                }
            }
            assertFailedAndUnusable(sink)
        }
    }

    func testUnavailableDeviceEndsSinkAndRejectsRestart() throws {
        // Der isolierte Linux-Lauf setzt ALSA_CONFIG_PATH auf eine Konfiguration
        // ohne Ausgabegerät. Normale Testläufe dürfen keine Soundkarte öffnen.
        guard ProcessInfo.processInfo.environment["VICIOUS_TEST_ALSA_UNAVAILABLE"] == "1" else {
            throw XCTSkip("Benötigt die isolierte ALSA-Konfiguration ohne Ausgabegerät.")
        }
        let sink = ALSAPCMSink()
        XCTAssertThrowsError(try sink.start { _, _ in 0 }) { error in
            guard case PCMSinkError.deviceUnavailable = error else {
                return XCTFail("Unerwarteter Fehler: \(error)")
            }
        }
        assertFailedAndUnusable(sink)
    }

    private func assertFailedAndUnusable(_ sink: ALSAPCMSink, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(sink.isRunning, file: file, line: line)
        let reason = sink.waitUntilFinished()
        if case .failed = reason {} else {
            XCTFail("Startfehler muss als .failed enden, kam: \(reason)", file: file, line: line)
        }
        sink.stop()
        XCTAssertEqual(sink.waitUntilFinished(), reason, file: file, line: line)
        XCTAssertThrowsError(try sink.start { _, _ in 0 }, file: file, line: line) { error in
            guard case PCMSinkError.invalidState = error else {
                return XCTFail("Sink muss nach Startfehler unbenutzbar sein: \(error)", file: file, line: line)
            }
        }
    }
}
#endif
