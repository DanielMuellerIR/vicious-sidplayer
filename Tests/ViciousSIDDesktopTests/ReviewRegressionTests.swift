import Foundation
import XCTest
import ViciousSIDPlayerCore
@testable import ViciousSIDDesktop

private final class TestSink: PCMSink, @unchecked Sendable {
    let format=PCMFormat()
    var isRunning: Bool { true }
    private let condition=NSCondition()
    private var finished=false
    func start(render: @escaping PCMRenderBlock) throws {}
    func pause() throws {}
    func resume() throws {}
    func stop() { condition.lock(); finished=true; condition.broadcast(); condition.unlock() }
    func waitUntilFinished() -> PCMSinkFinishReason {
        condition.lock(); defer { condition.unlock() }
        while !finished { condition.wait() }
        return .stopped
    }
}

final class ReviewRegressionTests: XCTestCase {
    private func sid(_ marker: UInt8=0) -> Data {
        var bytes=Data(repeating:0,count:0x7C)
        bytes.replaceSubrange(0..<4,with:Array("PSID".utf8))
        for (offset,value) in [(4,2),(6,0x7C),(8,0x1000),(10,0x1000),(12,0x1001),(14,2),(16,1)] {
            bytes[offset]=UInt8(value >> 8);bytes[offset+1]=UInt8(value & 255)
        }
        bytes.append(contentsOf:[0x60,0x60,marker]);return bytes
    }
    @MainActor private func fixture() async throws -> (URL,DesktopEngine) {
        let area=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:area,withIntermediateDirectories:true)
        let a=area.appendingPathComponent("A.sid"),b=area.appendingPathComponent("B.sid")
        try sid().write(to:a);try sid(1).write(to:b)
        let audio=DesktopAudio(makeSink:{_ in TestSink()})
        let engine=DesktopEngine(support:area.appendingPathComponent("support"),root:area.path,audio:audio)
        engine.suppressStartupAutoplay=true
        await engine.listening.ready();await engine.history.ready();await engine.playback.ready()
        _=engine.playlist.append([a,b],root:area)
        await engine.start()
        await engine.scanTask?.value
        engine.ticker?.cancel(); engine.ticker=nil
        engine.metadata.cancel(clear:true)
        return(area,engine)
    }
    @MainActor func testCollectionResumeHonorsLaterStopAndPause() async throws {
        let(area,engine)=try await fixture();defer {try? FileManager.default.removeItem(at:area)}
        try engine.load(0,autoplay:true)
        XCTAssertTrue(engine.pauseForCollection())
        _=await engine.handle(["op":"stop"])
        engine.resumeAfterCollection();XCTAssertEqual(engine.audio.state,"Stopped")
        try engine.audio.play();XCTAssertTrue(engine.pauseForCollection())
        _=await engine.handle(["op":"pause"])
        engine.resumeAfterCollection();XCTAssertEqual(engine.audio.state,"Paused")
        try engine.audio.play();XCTAssertTrue(engine.pauseForCollection())
        engine.resumeAfterCollection();XCTAssertEqual(engine.audio.state,"Playing")
        await engine.shutdown()
    }
    @MainActor func testInitialTrackKeepsQueueOrderDuplicatesAndSubtune() async throws {
        let(area,engine)=try await fixture();defer {try? FileManager.default.removeItem(at:area)}
        let a=engine.playlist.tracks[0].id,b=engine.playlist.tracks[1].id
        let queue=ListeningQueue(libraryID:engine.libraryID,name:"Saved order",kind:.savedList,
                                entries:[.init(trackID:b,subtune:1),.init(trackID:a),.init(trackID:b)])
        engine.listening.setQueue(queue)
        await engine.startInitialTrack(id:a,subtune:0,position:0)
        XCTAssertEqual(engine.listening.queue,queue)
        XCTAssertEqual(engine.currentTrack?.id,b);XCTAssertEqual(engine.audio.subtune,1)
        await engine.shutdown()
    }
    @MainActor func testCapturedPersonalTargetsSurviveTrackChange() async throws {
        let(area,engine)=try await fixture();defer {try? FileManager.default.removeItem(at:area)}
        try engine.load(0,autoplay:false)
        let target=try XCTUnwrap(engine.reference);let reference=engine.encoded(target)
        try engine.load(1,autoplay:false)
        _=await engine.handle(["op":"endTime","reference":reference,"title":"Captured","value":"42"])
        _=await engine.handle(["op":"noteReference","reference":reference,"text":"Captured note"])
        _=await engine.handle(["op":"bookmark","reference":reference,"name":"Captured mark","position":12.5])
        XCTAssertEqual(engine.playback.document.endTime(md5:target.md5,subtune:0),42)
        XCTAssertNil(engine.playback.document.endTime(md5:engine.md5,subtune:0))
        XCTAssertEqual(engine.history.document.notes.first?.reference,target)
        XCTAssertEqual(engine.history.document.bookmarks.first?.reference,target)
        XCTAssertEqual(engine.history.document.bookmarks.first?.position,12.5)
        await engine.shutdown()
    }
    @MainActor func testOpenedMetadataChangesPublicationSignature() async throws {
        let(area,engine)=try await fixture();defer {try? FileManager.default.removeItem(at:area)}
        _=await engine.handle(["op":"snapshot"]);let previous=engine.lastLibrarySignature
        let tracks=engine.playlist.tracks
        engine.metadata.refreshOpenedFiles(tracks)
        for _ in 0..<500 where engine.metadata.records.isEmpty {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertFalse(engine.metadata.records.isEmpty)
        engine.lastLibraryPublication=0
        _=await engine.handle(["op":"snapshot"])
        XCTAssertNotEqual(engine.lastLibrarySignature,previous)
        await engine.shutdown()
    }
    @MainActor func testDirectoryExportRenamesExistingTargetsBeforeStarting() async throws {
        let(area,engine)=try await fixture();defer {try? FileManager.default.removeItem(at:area)}
        try engine.load(0,autoplay:false)
        _=await engine.handle(["op":"exportPrepare","scope":"subtune"])
        await engine.exporter.waitForPreparation()
        engine.exporter.setDuration("0.05")
        let originalName=try XCTUnwrap(engine.exporter.items.first?.fileName)
        let folder=area.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let original=folder.appendingPathComponent(originalName)
        try Data("keep existing".utf8).write(to:original)
        _=await engine.handle(["op":"export","directory":folder.path])
        for _ in 0..<1000 where engine.exporter.state != .finished {try await Task.sleep(nanoseconds:1_000_000)}
        XCTAssertEqual(engine.exporter.state,.finished)
        XCTAssertNil(engine.exporter.error)
        let exportedName=try XCTUnwrap(engine.exporter.items.first?.fileName)
        XCTAssertNotEqual(exportedName,originalName)
        XCTAssertEqual(try Data(contentsOf:original),Data("keep existing".utf8))
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(exportedName)).prefix(4),Data("RIFF".utf8))
        await engine.shutdown()
    }
    @MainActor func testCancelledLoopPreparationDoesNotStrandSeek() async throws {
        let audio=DesktopAudio(makeSink:{_ in TestSink()})
        audio.load(try SidParser.parse(data:sid()));try audio.play()
        audio.loop.setStart(0,duration:60);audio.loop.setEnd(30,duration:60);audio.loop.setEnabled(true)
        let task=Task { try await audio.seek(0.1) }
        for _ in 0..<1000 where !audio.isPreparingLoop {try await Task.sleep(nanoseconds:100_000)}
        XCTAssertTrue(audio.isPreparingLoop)
        audio.loop.clear();audio.cancelLoopPreparation()
        try await task.value
        XCTAssertFalse(audio.isSeeking);XCTAssertEqual(audio.state,"Playing")
        audio.stop()
    }
}
