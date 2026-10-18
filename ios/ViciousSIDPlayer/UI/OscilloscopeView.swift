import SwiftUI
import ViciousSIDPlayerCore

// Oszilloskop: drei Kurven, eine je SID-Stimme.
//
// Die Zeichenlogik stammt sinngemaess aus der Mac-App
// (`Sources/ViciousSIDPlayerApp/UI/OscilloscopeView.swift`) und ist dort seit
// laengerem erprobt. Wichtig zum Verstaendnis: hier wird NICHT das echte
// Audiosignal geplottet. Der Emulator liefert nur die aktuellen Registerwerte
// jeder Stimme (Frequenz, Wellenform, Huellkurve, Gate, Pulsbreite); daraus
// wird eine idealisierte Kurve derselben Wellenform gezeichnet. Das ist um
// Groessenordnungen billiger als ein echtes Sample-Fenster und sieht fuer den
// Zweck — sehen, was die drei Stimmen gerade tun — genauso aus.
//
// Zeichenplan wie auf dem Mac:
//
//  1. Der Takt ist auf 30 Bilder pro Sekunde gedeckelt. Auf dem iPhone
//     waeren sonst bis zu 120 Hz moeglich — viel
//     Rechenzeit fuer einen Effekt, den niemand sieht.
//  2. Der Zeichentakt haelt an, sobald die App in den Hintergrund geht
//     (`isSceneActive == false`). Das Audio laeuft dabei weiter — genau das ist
//     der Sinn der Hintergrundwiedergabe — aber fuer einen ausgeschalteten
//     Bildschirm zu zeichnen waere reine Batterieverschwendung.
//
// Punkt 2 steckt im `paused:`-Argument von `TimelineView`: ist es `true`,
// liefert der Zeitplan genau noch das aktuelle Bild und stellt danach seinen
// Timer ab. Beim Zurueckkommen laeuft er von selbst wieder an. Die View bleibt
// dabei bewusst in der Hierarchie — so zeigt das zuletzt gezeichnete Bild auch
// in der App-Umschalter-Vorschau noch die Wellenform.
struct OscilloscopeView: View {
    @ObservedObject var coordinator: ViciousCoordinator
    let palette: PlayerPalette
    /// App im Vordergrund? Nur dann laeuft der Zeichentakt.
    let isSceneActive: Bool
    @State private var selectedChip = 0
    @State private var analysisMode = 0
    private var displayedChip: Int { coordinator.activeSIDChips.contains(selectedChip) ? selectedChip : coordinator.activeSIDChips[0] }

    /// Zielbild: 30 Bilder pro Sekunde.
    private static let minimumFrameInterval = 1.0 / 30.0

    /// Zeichnen anhalten, wenn nichts laeuft oder die App im Hintergrund ist.
    private var isPaused: Bool {
        !isSceneActive || !coordinator.isPlaying
    }

    var body: some View {
        VStack(spacing: 6) {
            if coordinator.activeSIDChips.count > 1 {
                Picker("Angezeigter SID-Chip", selection: $selectedChip) {
                    ForEach(coordinator.activeSIDChips, id: \.self) { chip in
                        Text(verbatim: "SID \(chip + 1)").tag(chip)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 8).padding(.top, 6)
            }
            analysisPicker
            if analysisMode == 0 {
                scope
            } else {
                SIDAnalysisPanel(coordinator: coordinator, chip: displayedChip, mode: analysisMode, isSceneActive: isSceneActive)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.scopeBackground, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onChange(of: coordinator.activeSIDChips) { _, chips in
            if !chips.contains(selectedChip) { selectedChip = chips[0] }
        }
    }

    private var analysisPicker: some View {
        HStack(spacing: 4) {
            Picker("Analyseansicht", selection: $analysisMode) {
                Text("Scope").tag(0); Text("Piano / Hz").tag(1); Text("Register").tag(2)
            }
            .pickerStyle(.segmented).accessibilityIdentifier("analysis-view")
            mixMenu
        }
    }

    private var mixMenu: some View {
        Menu {
            ForEach(coordinator.activeSIDChips, id: \.self) { chip in
                Section("SID \(chip + 1)") {
                    Toggle("Chip stumm", isOn: Binding(get: { coordinator.analysisMix.chipMuted[chip] },
                        set: { _ in coordinator.toggleChipMuted(chip) }))
                    ForEach(0..<3, id: \.self) { voice in
                        let channel = chip * 3 + voice
                        Menu("Stimme \(voice + 1)") {
                            Toggle("Stumm", isOn: Binding(get: { coordinator.analysisMix.channelMuted[channel] },
                                set: { _ in coordinator.toggleChannelMuted(channel) }))
                            Toggle("Solo", isOn: Binding(get: { coordinator.analysisMix.soloChannels.contains(channel) },
                                set: { _ in coordinator.toggleChannelSolo(channel) }))
                        }
                    }
                }
            }
            Button("Solos aufheben") { coordinator.clearSolos() }
                .disabled(coordinator.analysisMix.soloChannels.isEmpty)
        } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 18))
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Mischung")
    }

    private var scope: some View {
        HStack(spacing: 4) {
            TimelineView(.animation(minimumInterval: Self.minimumFrameInterval, paused: isPaused)) { timeline in
                Canvas { context, size in
                    draw(context: &context,
                         size: size,
                         time: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            .background(palette.scopeBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(palette.scopeBorder, lineWidth: 1)
            )
            .accessibilityLabel("Oszilloskop")
            .accessibilityHint("Zeigt die Wellenform der drei SID-Stimmen.")
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { voice in
                    voiceControls(voice).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 88)
        }
    }

    private func voiceControls(_ voice: Int) -> some View {
        let channel = displayedChip * 3 + voice
        let muted = coordinator.analysisMix.channelMuted[channel]
        let solo = coordinator.analysisMix.soloChannels.contains(channel)
        return HStack(spacing: 0) {
            Button { coordinator.toggleChannelMuted(channel) } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .foregroundStyle(muted ? .red : palette.traceColors[voice])
            .accessibilityLabel(Text("SID \(displayedChip + 1), Stimme \(voice + 1) stummschalten"))
            .accessibilityValue(muted ? Text("An") : Text("Aus"))
            .accessibilityIdentifier("channel-\(channel)-mute")
            Button { coordinator.toggleChannelSolo(channel) } label: {
                Text(verbatim: "S").font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .background(solo ? Color.orange.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            }
            .foregroundStyle(solo ? Color.orange : Color.secondary)
            .accessibilityLabel(Text("SID \(displayedChip + 1), Stimme \(voice + 1) Solo"))
            .accessibilityValue(solo ? Text("An") : Text("Aus"))
            .accessibilityIdentifier("channel-\(channel)-solo")
        }
        .buttonStyle(.plain)
    }

    // MARK: - Zeichnen

    private func draw(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return }

        drawGrid(context: &context, width: width, height: height)

        // Im Stop-Zustand faellt alles auf die Nulllinie. Bei Pause bleiben die
        // letzten Werte stehen, damit das Bild nicht zusammenklappt.
        let showWave = coordinator.isPlaying || coordinator.isPaused
        let channelHeight = height / 3
        // Die Anzeigewerte werden hier beim Zeichnen geholt, nicht ueber
        // `@Published` zugestellt: So wirft die Emulation nicht 50-mal je
        // Sekunde den ganzen Rumpf der Oberflaeche neu auf (siehe
        // `ViciousCoordinator`).
        let visuals = showWave ? coordinator.currentVisuals(chip: displayedChip) : .silent

        for voice in 0..<3 {
            drawVoice(voice,
                      context: &context,
                      width: width,
                      channelHeight: channelHeight,
                      showWave: showWave,
                      visuals: visuals,
                      time: time)
        }

        drawHUD(context: &context, width: width, height: height)
    }

    private func drawGrid(context: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        let gridColor = palette.scopeGrid

        let spacingX = width / 10
        if spacingX > 0 {
            for x in stride(from: 0, to: width, by: spacingX) {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))
                context.stroke(path, with: .color(gridColor), lineWidth: 1)
            }
        }

        let spacingY = height / 8
        if spacingY > 0 {
            for y in stride(from: 0, to: height, by: spacingY) {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
                context.stroke(path, with: .color(gridColor), lineWidth: 1)
            }
        }
    }

    private func drawVoice(_ voice: Int,
                           context: inout GraphicsContext,
                           width: CGFloat,
                           channelHeight: CGFloat,
                           showWave: Bool,
                           visuals: VoiceVisuals,
                           time: TimeInterval) {
        let baselineY = channelHeight * CGFloat(voice) + channelHeight / 2

        let rawFrequency = showWave ? visuals.frequencies[voice] : 0
        let envelope = showWave ? Double(visuals.envelopes[voice]) : 0.0
        let gate = showWave ? visuals.gates[voice] : 0
        let waveform = showWave ? visuals.waveforms[voice] : 0
        let duty = Double(visuals.pulsewidths[voice])

        let frequencyHz = coordinator.effectiveClock.oscillatorFrequency(registerValue: rawFrequency)

        // Nulllinie
        var baselinePath = Path()
        baselinePath.move(to: CGPoint(x: 0, y: baselineY))
        baselinePath.addLine(to: CGPoint(x: width, y: baselineY))
        context.stroke(baselinePath, with: .color(palette.scopeBaseline), lineWidth: 1)

        // Ausschlag: die Huellkurve bestimmt die Hoehe. Bei stiller Stimme ein
        // Hauch Rauschen, damit die Linie „lebt" statt tot flach zu liegen.
        let amplitude: Double
        if !showWave {
            amplitude = 0.0
        } else if envelope > 0.01 {
            amplitude = envelope * Double(channelHeight * 0.38)
        } else {
            amplitude = Double.random(in: -0.75...0.75)
        }

        // Wellenlaenge in Pixeln: hohe Toene enger, tiefe breiter — begrenzt,
        // damit weder ein Strichmuster noch eine Gerade entsteht.
        let wavelength = frequencyHz > 10.0 ? max(10.0, min(300.0, 3000.0 / frequencyHz)) : 150.0
        // Phasenversatz an die Uhr haengen: dadurch scrollt die Kurve sichtbar.
        let phaseShift = frequencyHz > 0.0 ? (frequencyHz * time * 0.02).truncatingRemainder(dividingBy: 1.0) : 0.0

        var wavePath = Path()
        var hasMoved = false
        // Schrittweite 2 Punkte: bei Retina-Aufloesung optisch nicht von 1 zu
        // unterscheiden, halbiert aber die Punktzahl.
        for x in stride(from: 0.0, to: Double(width), by: 2.0) {
            let phase = x / wavelength - phaseShift
            let fraction = phase - floor(phase)
            let sample = Self.waveSample(fraction: fraction, waveform: waveform, duty: duty)
            let y = baselineY + CGFloat(sample * amplitude)
            let point = CGPoint(x: x, y: y)
            if hasMoved {
                wavePath.addLine(to: point)
            } else {
                wavePath.move(to: point)
                hasMoved = true
            }
        }

        // Stummgeschaltete Stimmen gedimmt zeichnen: die Emulation laeuft weiter,
        // nur ihr Beitrag zum Mix fehlt.
        let isMuted = coordinator.effectiveChannelMuted[displayedChip * 3 + voice]
        let color = isMuted ? palette.traceColors[voice].opacity(0.25) : palette.traceColors[voice]
        context.stroke(wavePath,
                       with: .color(color),
                       style: StrokeStyle(lineWidth: gate != 0 ? 2.0 : 1.0))

        // Technische Statuszeile je Stimme. Bewusst nicht uebersetzt: das sind
        // Registernamen aus dem SID-Datenblatt, keine Bedienoberflaeche.
        let frequencyText = frequencyHz > 20.0 ? "\(Int(frequencyHz.rounded())) Hz" : "0 Hz"
        let envelopeText = "\(Int((envelope * 100.0).rounded()))%"
        let mutedText = isMuted ? " · M" : ""
        let line = "V\(voice + 1) \(Self.waveformName(waveform)) · \(frequencyText) · \(envelopeText) · G\(gate)\(mutedText)"

        let resolved = context.resolve(
            Text(line)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(color)
        )
        context.draw(resolved,
                     at: CGPoint(x: 8, y: channelHeight * CGFloat(voice) + 11),
                     anchor: .leading)
    }

    private func drawHUD(context: inout GraphicsContext, width: CGFloat, height: CGFloat) {
        let model = coordinator.modelForChip(displayedChip) == 8580 ? "8580" : "6581"
        // Ueber eine String-Variable statt direkt als Literal: `Text` mit einem
        // Literal wuerde den Text als Uebersetzungsschluessel behandeln, und
        // Chipbezeichnungen uebersetzt man nicht.
        let hudLine = "CHIP: C64 " + model + " // 3 TRACE"
        let resolved = context.resolve(
            Text(hudLine)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(palette.scopeHUD)
        )
        context.draw(resolved, at: CGPoint(x: width - 8, y: height - 10), anchor: .trailing)
    }

    // MARK: - Wellenform-Modell

    /// Idealisierte Wellenform des SID an der Stelle `fraction` (0…1 innerhalb
    /// einer Periode). Die Bits entsprechen dem Kontrollregister des Chips:
    /// 0x10 Dreieck, 0x20 Saegezahn, 0x40 Rechteck, 0x80 Rauschen.
    private static func waveSample(fraction: Double, waveform: Int, duty: Double) -> Double {
        if (waveform & 0x80) != 0 { return Double.random(in: -1.0...1.0) }
        if (waveform & 0x40) != 0 { return fraction < duty ? 1.0 : -1.0 }
        if (waveform & 0x20) != 0 { return 2.0 * fraction - 1.0 }
        if (waveform & 0x10) != 0 { return fraction < 0.5 ? 4.0 * fraction - 1.0 : 3.0 - 4.0 * fraction }
        return 0.0
    }

    /// Kurzname der Wellenform fuer die Statuszeile.
    private static func waveformName(_ waveform: Int) -> String {
        if (waveform & 0x80) != 0 { return "NOI" }
        if (waveform & 0x40) != 0 { return "PUL" }
        if (waveform & 0x20) != 0 { return "SAW" }
        if (waveform & 0x10) != 0 { return "TRI" }
        return "---"
    }
}
