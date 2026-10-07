#if canImport(AVFoundation)
import XCTest
@testable import ViciousSIDPlayerCore

final class AVAudioEnginePCMSinkTests: XCTestCase {
    private final class EndProbe: @unchecked Sendable {
        let lock = NSLock()
        var time: TimeInterval = 0
        var frames = 0
        func record(_ frames: Int) {
            lock.lock()
            self.time = ProcessInfo.processInfo.systemUptime
            self.frames = frames
            lock.unlock()
        }
        func result() -> (TimeInterval, Int) {
            lock.lock()
            defer { lock.unlock() }
            return (time, frames)
        }
    }

    func testNaturalFinishWaitsForTheFinalPartialAudioBuffer() throws {
        let probe = EndProbe()
        let sink = AVAudioEnginePCMSink(format: PCMFormat(sampleRate: 44100, channels: 1))
        do {
            try sink.start { buffer, frames in
                buffer.initialize(repeating: 0)
                probe.record(frames)
                return frames / 2
            }
        } catch {
            throw XCTSkip("Kein nutzbares Audiogerät: \(error)")
        }
        defer { sink.stop() }
        XCTAssertEqual(sink.waitUntilFinished(), .sourceFinished)
        let (time, frames) = probe.result()
        XCTAssertGreaterThan(frames, 0)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - time, Double(frames) / 44100)
    }

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
