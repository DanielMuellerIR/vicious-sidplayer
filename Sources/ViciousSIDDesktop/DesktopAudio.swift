import Foundation
import ViciousSIDPlayerCore

/// Der Audio-Thread besitzt nur Processor und Sichtpuffer. Dateiscan, JSON und
/// Oberfläche laufen außerhalb dieses Threads; Pause behält den Processor.
@MainActor
final class DesktopAudio {
  private(set) var sid: SidFileData?
  private(set) var processor: ViciousProcessor?
  private var sink: PCMSink?
  private let visuals = RealtimeVisualsBuffer()
  private(set) var state = "Stopped"
  private(set) var subtune = 0
  private(set) var pendingPosition = 0.0
  private(set) var isSeeking = false
  private var generation = 0
  private var seekWorker: Task<ViciousProcessor, Error>?
  private var loopWorker: Task<ViciousProcessor.PreparedLoop, Error>?
  private var preparedLoop: ViciousProcessor.PreparedLoop?
  private var loopGeneration = 0
  private(set) var isPreparingLoop = false
  var onFailure: ((String) -> Void)?
  var volume = 1.0 { didSet { processor?.setVolume(vol: pow(volume, 2)) } }
  var model: Int? { didSet { processor?.setModelOverride(model.map(Double.init)) } }
  var clockMode = SidClockMode.auto
  var mix = AnalysisMix() { didSet { applyMix() } }
  var filterEnabled = true { didSet { processor?.setFilterEnabled(filterEnabled) } }
  var loop = PlaybackLoop()
  var chips: [Int] {
    [0] + (sid?.secondSidAddress ?? 0 != 0 ? [1] : []) + (sid?.thirdSidAddress ?? 0 != 0 ? [2] : [])
  }
  var elapsed: Double {
    processor == nil || isSeeking ? pendingPosition : visuals.readVisuals().playtime
  }
  var effectiveClock: C64Clock { clockMode.resolve(sid?.clockPreference ?? .unknown) }

  func load(_ file: SidFileData) {
    stop()
    sid = file
    subtune = 0
    loop.clear()
  }
  func play() throws {
    guard let sid else { return }
    if isSeeking {
      state = "Playing"
      return
    }
    if state == "Paused", let sink {
      try sink.resume()
      state = "Playing"
      return
    }
    guard state != "Playing" else { return }
    let format = PCMSinkFactory.preferredFormat()
    let processor: ViciousProcessor
    if let prepared = self.processor {
      processor = prepared
    } else {
      processor = ViciousProcessor(sampleRate: format.sampleRate, clockMode: clockMode)
      _ = processor.loadSID(sidFile: sid)
      processor.initSubtune(sub: subtune)
      configure(processor)
      processor.seek(seconds: pendingPosition)
      if loop.isEnabled, let preparedLoop { _ = processor.installLoop(preparedLoop) }
    }
    let sink = PCMSinkFactory.makeDefault(format: format)
    let buffer = visuals
    try sink.start { samples, frames in
      for frame in 0..<frames {
        let value = processor.playStereo()
        samples[frame * 2] = Float(value.left)
        samples[frame * 2 + 1] = Float(value.right)
      }
      buffer.write(processor.getChannelsData())
      return frames
    }
    self.processor = processor
    self.sink = sink
    state = "Playing"
    let ticket = generation
    Task { [weak self] in
      let reason = await Task.detached { sink.waitUntilFinished() }.value
      guard let self, self.generation == ticket else { return }
      if case .failed(let detail) = reason {
        self.stop()
        self.onFailure?(detail)
      }
    }
  }
  func pause() throws {
    guard state == "Playing" else { return }
    try sink?.pause()
    state = "Paused"
  }
  func stop() {
    cancelLoopPreparation()
    seekWorker?.cancel()
    seekWorker = nil
    generation += 1
    isSeeking = false
    loop.setEnabled(false)
    sink?.stop()
    sink = nil
    processor = nil
    state = "Stopped"
    pendingPosition = 0
    visuals.write(.silent)
  }
  func unload() {
    stop()
    sid = nil
    subtune = 0
    loop.clear()
  }
  func setSubtune(_ value: Int) throws {
    guard let sid, (0..<sid.subtuneAmount).contains(value) else { return }
    let previous = state
    stop()
    subtune = value
    loop.clear()
    if previous == "Playing" { try play() } else if previous == "Paused" { state = "Paused" }
  }
  func changeClock(_ mode: SidClockMode) async throws {
    guard clockMode != mode else { return }
    clockMode = mode
    try await seek(elapsed)
  }
  private func configure(_ processor: ViciousProcessor) {
    processor.setVolume(vol: pow(volume, 2))
    processor.setModelOverride(model.map(Double.init))
    processor.setMutedChannels(mix.effectiveMuted(activeChips: chips))
    processor.setFilterEnabled(filterEnabled)
  }
  private func applyMix() { processor?.setMutedChannels(mix.effectiveMuted(activeChips: chips)) }
  func seek(_ seconds: Double) async throws {
    guard let sid else { return }
    let position = ViciousProcessor.normalizedSeekSeconds(seconds)
    let previous = state
    let selection = loop
    stop()
    loop = selection
    pendingPosition = position
    loop.seek(to: position)
    if previous == "Stopped" {
      if loop.isEnabled { try await installLoop() }
      return
    }
    isSeeking = true
    state = previous
    let ticket = generation
    let sub = subtune
    let clock = clockMode
    let model = model
    let muted = mix.effectiveMuted(activeChips: chips)
    let filter = filterEnabled
    let worker = Task.detached(priority: .userInitiated) {
      let processor = ViciousProcessor(sampleRate: 44100, clockMode: clock)
      _ = processor.loadSID(sidFile: sid)
      processor.initSubtune(sub: sub)
      processor.setModelOverride(model.map(Double.init))
      processor.setMutedChannels(muted)
      processor.setFilterEnabled(filter)
      try processor.seekCancellable(seconds: position) { try Task.checkCancellation() }
      return processor
    }
    seekWorker = worker
    let prepared = try await worker.value
    guard generation == ticket else { return }
    seekWorker = nil
    configure(prepared)
    processor = prepared
    visuals.write(prepared.getChannelsData())
    if loop.isEnabled { try await installLoop() }
    guard generation == ticket else { return }
    let desiredState = state
    isSeeking = false
    state = "Paused"
    if desiredState == "Playing" { try play() }
  }
  func installLoop() async throws {
    cancelLoopPreparation()
    processor?.disableLoop()
    guard loop.isEnabled, let range = loop.range, let sid else {
      return
    }
    let ticket = generation
    let loopTicket = loopGeneration
    let sub = subtune
    let clock = clockMode
    let model = model
    let muted = mix.effectiveMuted(activeChips: chips)
    let filter = filterEnabled
    isPreparingLoop = true
    let worker = Task.detached(priority: .userInitiated) {
      try ViciousProcessor.prepareLoop(
        sid: sid, subtune: sub, sampleRate: 44100, range: range, model: model,
        muted: muted, filterEnabled: filter, clockMode: clock,
        cancellationCheck: { try Task.checkCancellation() })
    }
    loopWorker = worker
    defer {
      if loopTicket == loopGeneration {
        isPreparingLoop = false
        loopWorker = nil
      }
    }
    let prepared = try await worker.value
    guard ticket == generation, loopTicket == loopGeneration, loop.isEnabled else { return }
    preparedLoop = prepared
    if let processor, !processor.installLoop(prepared) {
      loop.setEnabled(false)
      throw PCMSinkError.invalidState("Die A/B-Schleife passt nicht mehr zur aktuellen Wiedergabe.")
    }
  }
  func cancelLoopPreparation() {
    loopGeneration += 1
    loopWorker?.cancel()
    loopWorker = nil
    preparedLoop = nil
    isPreparingLoop = false
  }
  func clearLoop() {
    loop.clear()
    cancelLoopPreparation()
    processor?.disableLoop()
  }
  func modelForChip(_ chip: Int) -> Int {
    if let model { return model }
    if chip == 1, let value = sid?.prefModel2, value != 0 { return value }
    if chip == 2, let value = sid?.prefModel3, value != 0 { return value }
    return sid?.prefModel ?? 6581
  }
  func visualSnapshot() -> [[String: Any]] {
    let data = visuals.readVisuals()
    return chips.map { chip in
      let v = data.chip(chip)
      let env = [v.envelopes.0, v.envelopes.1, v.envelopes.2]
      let freq = [v.frequencies.0, v.frequencies.1, v.frequencies.2]
      let wave = [v.waveforms.0, v.waveforms.1, v.waveforms.2]
      let voices: [[String: Any]] = (0..<3).map { voice in
        let pitch = SIDPitch.estimate(
          register: freq[voice], clock: effectiveClock, waveform: wave[voice],
          envelope: Double(env[voice]))
        return [
          "envelope": env[voice], "frequency": freq[voice],
          "hertz": effectiveClock.oscillatorFrequency(registerValue: freq[voice]),
          "gate": [v.gates.0, v.gates.1, v.gates.2][voice], "waveform": wave[voice],
          "pulsewidth": [v.pulsewidths.0, v.pulsewidths.1, v.pulsewidths.2][voice],
          "note": pitch?.name ?? "—", "midi": pitch?.midiNote ?? -1, "cents": pitch?.cents ?? 0,
        ]
      }
      return [
        "chip": chip, "model": modelForChip(chip),
        "address": chip == 0
          ? 0xD400 : chip == 1 ? sid?.secondSidAddress ?? 0 : sid?.thirdSidAddress ?? 0,
        "voices": voices,
        "registers": SIDRegister.offsets.map { offset in
          ["offset": offset, "label": SIDRegister.label(offset), "value": Int(v.registers[offset])]
            as [String: Any]
        },
      ]
    }
  }
}
