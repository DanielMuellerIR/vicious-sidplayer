import SwiftUI
import ViciousSIDPlayerCore

struct SIDAnalysisPanel: View {
    @ObservedObject var coordinator: ViciousCoordinator
    let chip: Int
    let mode: Int
    var isSceneActive = true

    private var contextLabel: some View {
        Text(verbatim: String(format: "SID %d · $%04X · %d · %@", chip + 1,
            coordinator.sidBaseAddresses[chip], coordinator.modelForChip(chip), coordinator.effectiveClock.label))
            .font(.caption2.monospaced()).foregroundStyle(.secondary)
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !isSceneActive || !coordinator.isPlaying)) { _ in
            let live = coordinator.isPlaying || coordinator.isPaused
            let visuals = live ? coordinator.currentVisuals(chip: chip) : .silent
            let registers = live ? coordinator.currentRegisters(chip: chip) : .silent
            if mode == 1 {
                VStack(alignment: .leading, spacing: 8) {
                    contextLabel
                    ForEach(0..<3, id: \.self) { voice in
                        let pitch = SIDPitch.estimate(register: visuals.frequencies[voice], clock: coordinator.effectiveClock,
                            waveform: visuals.waveforms[voice], envelope: Double(visuals.envelopes[voice]))
                        HStack(spacing: 8) {
                            Text(verbatim: "V\(voice + 1)").font(.caption.weight(.semibold))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(verbatim: pitch.map { String(format: "%@ · %.1f Hz · %+.0f ct", $0.name, $0.hertz, $0.cents) } ?? String(format: "— · %.1f Hz", coordinator.effectiveClock.oscillatorFrequency(registerValue: visuals.frequencies[voice])))
                                        .font(.caption.monospaced()).lineLimit(1).minimumScaleFactor(0.8)
                                    Spacer(minLength: 0)
                                    Text(verbatim: "G\(visuals.gates[voice]) · \(Int(visuals.envelopes[voice] * 100))%")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                Canvas { context, size in
                                    let width = max(0, (size.width - 22) / 12)
                                    for key in 0..<12 {
                                        let black = [1, 3, 6, 8, 10].contains(key)
                                        let rect = CGRect(x: CGFloat(key) * (width + 2), y: black ? 3 : 0,
                                                          width: width, height: black ? 12 : 18)
                                        let color = pitch?.midiNote.quotientAndRemainder(dividingBy: 12).remainder == key
                                            ? Color.accentColor : Color.secondary.opacity(black ? 0.6 : 0.16)
                                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                                    }
                                }.frame(height: 18).accessibilityHidden(true)
                            }
                        }
                        .opacity(coordinator.effectiveChannelMuted[chip * 3 + voice] ? 0.4 : 1)
                    }
                    Text("Ungefähre Register-Tonhöhe, A4 = 440 Hz. Noise, kombinierte Wellenformen und Digi-Töne sind nicht verlässlich erkennbar.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(10)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    contextLabel
                    Text("Geschriebene Register und emulierte OSC3/ENV3-Werte; nur Leseansicht.")
                        .font(.caption2).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(SIDRegister.offsets, id: \.self) { offset in
                                HStack(spacing: 8) {
                                    Text(verbatim: String(format: "$%04X", coordinator.sidBaseAddresses[chip] + UInt32(offset)))
                                        .foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                    Text(verbatim: SIDRegister.label(offset)).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(verbatim: String(format: "%02X", registers.registers[offset])).bold()
                                }.font(.caption.monospaced()).accessibilityElement(children: .combine)
                            }
                        }
                    }
                }.padding(10)
            }
        }
    }
}

struct PlaybackLoopControls: View {
    @ObservedObject var coordinator: ViciousCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private func time(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "—" }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controlsLayout {
                Button { coordinator.setLoopStart() } label: { Text("A setzen").lineLimit(1).frame(minHeight: 44) }
                    .accessibilityIdentifier("loop-set-a").disabled(!coordinator.hasSID)
                Button { coordinator.setLoopEnd() } label: { Text("B setzen").lineLimit(1).frame(minHeight: 44) }
                    .disabled(coordinator.playbackLoop.start == nil)
                    .accessibilityIdentifier("loop-set-b")
                Button { coordinator.setLoopEnabled(!coordinator.playbackLoop.isEnabled) } label: {
                    Label("A/B", systemImage: coordinator.playbackLoop.isEnabled ? "repeat.circle.fill" : "repeat.circle")
                        .font(.footnote).frame(minWidth: 44, minHeight: 44)
                }
                    .tint(coordinator.playbackLoop.isEnabled ? .accentColor : .secondary)
                    .disabled(coordinator.playbackLoop.range == nil)
                    .accessibilityIdentifier("loop-enabled")
                    .accessibilityLabel("A/B")
                    .accessibilityValue(coordinator.playbackLoop.isEnabled ? Text("An") : Text("Aus"))
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button { coordinator.clearLoop() } label: { Image(systemName: "xmark.circle").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("A/B-Marker löschen")
            }
            .buttonStyle(.bordered)
            Text(verbatim: "A \(time(coordinator.playbackLoop.start)) · B \(time(coordinator.playbackLoop.end))")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("Mindestens 0,25 s. Ein Sprung außerhalb A/B schaltet die Schleife aus.")
                .font(.caption2).foregroundStyle(.secondary)
            if coordinator.isPreparingLoop { Text("Schleife wird vorbereitet …").font(.caption) }
            if let error = coordinator.loopError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private var controlsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
    }
}
