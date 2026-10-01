#if canImport(AVFoundation)
import XCTest
@testable import ViciousSIDPlayerCore

final class AVAudioEnginePCMSinkTests: XCTestCase {
    func testConcurrentStopsReleaseResourcesOnce() throws {
        for _ in 0..<20 {
            let sink = AVAudioEnginePCMSink(format: PCMFormat(channels: 1))
            do {
                try sink.start { buffer, frames in
                    for index in buffer.indices { buffer[index] = 0 }
                    return frames
                }
            } catch {
                throw XCTSkip("Kein nutzbares Audiogerät: \(error)")
            }
            let ready = DispatchGroup()
            let done = DispatchGroup()
            let go = DispatchSemaphore(value: 0)
            for _ in 0..<4 {
                ready.enter()
                done.enter()
                DispatchQueue.global().async {
                    ready.leave()
                    go.wait()
                    sink.stop()
                    done.leave()
                }
            }
            XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
            for _ in 0..<4 { go.signal() }
            guard done.wait(timeout: .now() + 10) == .success else {
                return XCTFail("Paralleler Abbau hängt")
            }
            XCTAssertFalse(sink.isRunning)
            XCTAssertEqual(sink.waitUntilFinished(), .stopped)
            sink.stop()
            XCTAssertEqual(sink.waitUntilFinished(), .stopped)
        }
    }
}
#endif
