import SwiftUI
import ViciousSIDPlayerCore

public struct OscilloscopeView: View {
    @ObservedObject var coordinator: ViciousCoordinator
    var theme: PlayerTheme
    @State private var selectedChip = 0
    @State private var analysisMode = 0
    @State private var showsMixControls = false
    private var displayedChip: Int { coordinator.activeSIDChips.contains(selectedChip) ? selectedChip : coordinator.activeSIDChips[0] }

    // Trace-Farben pro Theme: die Neon-Toene (Cyan/Gruen/Pink) leuchten nur auf
    // dunklem Grund — auf Weiss sind sie kaum lesbar. Der Hell-Modus bekommt
    // deshalb dunklere Varianten derselben Farbfamilien (Petrol/Waldgruen/Magenta).
    private var traceColors: [Color] {
        theme == .dark
            ? [.cyan, .green, .pink]
            : [Color(red: 0.00, green: 0.45, blue: 0.55),
               Color(red: 0.13, green: 0.50, blue: 0.13),
               Color(red: 0.75, green: 0.10, blue: 0.45)]
    }

    public init(coordinator: ViciousCoordinator, theme: PlayerTheme) {
        self.coordinator = coordinator
        self.theme = theme
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if coordinator.activeSIDChips.count > 1 {
                    Picker("Angezeigter SID-Chip", selection: $selectedChip) {
                        ForEach(coordinator.activeSIDChips, id: \.self) { chip in
                            Text(verbatim: "SID \(chip + 1)").tag(chip)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(maxWidth: 220)
                } else { Text(verbatim: "SID 1").font(.caption) }
                Text(verbatim: "\(coordinator.modelForChip(displayedChip))").font(.caption.monospaced())
                Spacer(minLength: 8)
                Picker("Analyseansicht", selection: $analysisMode) {
                    Text("Oszilloskop").tag(0); Text("Piano / Hz").tag(1); Text("Register").tag(2)
                }.labelsHidden().frame(width: 130).accessibilityIdentifier("analysis-view")
                Button("Mischung …") { showsMixControls.toggle() }
                    .popover(isPresented: $showsMixControls) { mixControls }
            }
            .padding(8)
            if analysisMode == 0 {
            ZStack {
                scopeCanvas
                GeometryReader { geo in
                    let channelH = geo.size.height / 3
                    ForEach(0..<3, id: \.self) { voice in
                        let channel = displayedChip * 3 + voice
                        HStack(spacing: 4) {
                            Button { coordinator.toggleChannelMuted(channel) } label: {
                                Image(systemName: coordinator.analysisMix.channelMuted[channel] ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .frame(width: 24, height: 26)
                            }
                            .foregroundColor(coordinator.analysisMix.channelMuted[channel] ? .red : traceColors[voice])
                            .accessibilityLabel(Text("SID \(displayedChip + 1), Stimme \(voice + 1) stummschalten"))
                            .accessibilityValue(coordinator.analysisMix.channelMuted[channel] ? Text("An") : Text("Aus"))
                            .help("Stimmen-Mute umschalten; Solo und Chip-Mute bleiben erhalten")
                            Button { coordinator.toggleChannelSolo(channel) } label: {
                                Image(systemName: coordinator.analysisMix.soloChannels.contains(channel) ? "s.circle.fill" : "s.circle").frame(width: 24, height: 26)
                            }
                                .foregroundColor(coordinator.analysisMix.soloChannels.contains(channel) ? .orange : .secondary)
                                .accessibilityLabel(Text("SID \(displayedChip + 1), Stimme \(voice + 1) Solo"))
                                .accessibilityValue(coordinator.analysisMix.soloChannels.contains(channel) ? Text("An") : Text("Aus"))
                                .help("Solo umschalten; mehrere Solos wirken gemeinsam")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: .semibold))
                        .background(theme == .dark ? Color.macDarkSurface : Color.macLightSurface)
                        .position(x: geo.size.width - 34, y: channelH * CGFloat(voice) + 14)
                    }
                    Button { coordinator.toggleFilterEnabled() } label: {
                        Text(coordinator.filterEnabled ? "FILTER: ON" : "FILTER: OFF")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(coordinator.filterEnabled ? traceColors[1] : .red)
                            .frame(width: 100, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("SID-Filter")
                    .accessibilityValue(coordinator.filterEnabled ? "An" : "Aus")
                    .help("SID-Filter an/aus; der Filterzustand läuft weiter")
                    .position(x: 52, y: geo.size.height - 12)
                }
            }
            } else {
                SIDAnalysisPanel(coordinator: coordinator, chip: displayedChip, mode: analysisMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: coordinator.activeSIDChips) { chips in
            if !chips.contains(selectedChip) { selectedChip = chips[0] }
        }
    }

    private var mixControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SID-Mischung").font(.headline)
            ForEach(coordinator.activeSIDChips, id: \.self) { chip in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(verbatim: "SID \(chip + 1) · \(coordinator.modelForChip(chip))").font(.subheadline.weight(.semibold))
                        Spacer()
                        Toggle("Chip stumm", isOn: Binding(
                            get: { coordinator.analysisMix.chipMuted[chip] },
                            set: { if $0 != coordinator.analysisMix.chipMuted[chip] { coordinator.toggleChipMuted(chip) } }))
                            .toggleStyle(.checkbox)
                            .accessibilityLabel(Text("SID \(chip + 1) Chip stumm"))
                    }
                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { voice in
                            let channel = chip * 3 + voice
                            VStack(spacing: 5) {
                                Text(verbatim: "V\(voice + 1)").font(.caption.monospaced())
                                HStack(spacing: 4) {
                                    Button { coordinator.toggleChannelMuted(channel) } label: {
                                        Image(systemName: coordinator.analysisMix.channelMuted[channel] ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                            .frame(width: 30, height: 24)
                                    }
                                    .tint(coordinator.analysisMix.channelMuted[channel] ? .red : traceColors[voice])
                                    .accessibilityLabel(Text("SID \(chip + 1), Stimme \(voice + 1) stummschalten"))
                                    .accessibilityValue(coordinator.analysisMix.channelMuted[channel] ? Text("An") : Text("Aus"))
                                    Button { coordinator.toggleChannelSolo(channel) } label: {
                                        HStack(spacing: 2) {
                                            Text("Solo")
                                            Image(systemName: "checkmark").font(.system(size: 10)).opacity(coordinator.analysisMix.soloChannels.contains(channel) ? 1 : 0)
                                        }.fixedSize(horizontal: true, vertical: false)
                                            .frame(minWidth: 46, minHeight: 24)
                                    }
                                        .tint(coordinator.analysisMix.soloChannels.contains(channel) ? .orange : .secondary)
                                        .accessibilityLabel(Text("SID \(chip + 1), Stimme \(voice + 1) Solo"))
                                        .accessibilityValue(coordinator.analysisMix.soloChannels.contains(channel) ? Text("An") : Text("Aus"))
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            Button("Solos aufheben") { coordinator.clearSolos() }.disabled(coordinator.analysisMix.soloChannels.isEmpty)
            Text("Mehrere Solos wirken gemeinsam. Stimmen- und Chip-Mute haben Vorrang.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(16)
        .frame(width: 440)
        .preferredColorScheme(theme == .dark ? .dark : .light)
    }

    private var scopeCanvas: some View {
        // paused: !isPlaying friert die Animation ein — bei Pause bleibt das zuletzt
        // gezeichnete Bild stehen (die Wellenform im Moment des Pausierens), statt
        // weiterzuscrollen. Die Werte selbst bleiben ueber isPaused erhalten (unten).
        TimelineView(.animation(paused: !coordinator.isPlaying)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                // Die Anzeigewerte werden hier beim Zeichnen geholt, nicht ueber
                // `@Published` zugestellt: So wirft die Emulation nicht 50-mal je
                // Sekunde den ganzen Rumpf der Oberflaeche neu auf (siehe
                // `ViciousCoordinator`).
                let visuals = coordinator.currentVisuals(chip: displayedChip)
                let mutedChannels = coordinator.effectiveChannelMuted
                let W = size.width
                let H = size.height

                guard W > 0 && H > 0 else { return }

                // Draw Background
                let isDark = theme == .dark
                let bgCol = isDark ? Color.macDarkSurface : Color.macLightSurface
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bgCol))

                // Draw Grid Lines
                let gridColor = Color.gray.opacity(0.12)
                let gridSpacingX = W / 10
                for x in stride(from: 0, to: W, by: gridSpacingX) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: H))
                    context.stroke(path, with: .color(gridColor), lineWidth: 1)
                }
                
                let gridSpacingY = H / 8
                for y in stride(from: 0, to: H, by: gridSpacingY) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: W, y: y))
                    context.stroke(path, with: .color(gridColor), lineWidth: 1)
                }

                // Render 3 channels
                let channelH = H / 3
                // showWave = laeuft ODER pausiert: dann die (letzten) Kanalwerte
                // zeichnen. Nur im echten Stop-Zustand auf die Null-Linie fallen.
                let showWave = coordinator.isPlaying || coordinator.isPaused

                for c in 0..<3 {
                    let baselineY = channelH * CGFloat(c) + channelH / 2
                    let rawFreq = showWave ? visuals.frequencies[c] : 0
                    let env = showWave ? Double(visuals.envelopes[c]) : 0.0
                    let gate = showWave ? visuals.gates[c] : 0
                    let wf = showWave ? visuals.waveforms[c] : 0
                    let duty = Double(visuals.pulsewidths[c])

                    let freqHz = coordinator.effectiveClock.oscillatorFrequency(registerValue: rawFreq)

                    // Draw baseline
                    var baseLinePath = Path()
                    baseLinePath.move(to: CGPoint(x: 0, y: baselineY))
                    baseLinePath.addLine(to: CGPoint(x: W, y: baselineY))
                    context.stroke(baseLinePath, with: .color(Color.gray.opacity(0.25)), lineWidth: 1)

                    // Draw oscillating trace path
                    var wavePath = Path()
                    let amplitude = !showWave ? 0.0 : (env > 0.01 ? Double(env) * Double(channelH * 0.38) : Double.random(in: -0.75...0.75))
                    let wavelength = freqHz > 10.0 ? max(10.0, min(300.0, 3000.0 / freqHz)) : 150.0

                    // Tie the phase offset to current time to scroll smoothly
                    let phaseShift = freqHz > 0.0 ? (freqHz * time * 0.02).truncatingRemainder(dividingBy: 1.0) : 0.0

                    var hasMoved = false
                    for x in stride(from: 0, to: W, by: 2) {
                        let ph = Double(x) / wavelength - phaseShift
                        let frac = ph - floor(ph)
                        let waveVal = sidWaveSample(frac: frac, wf: wf, duty: duty)
                        let y = baselineY + CGFloat(waveVal * amplitude)

                        if !hasMoved {
                            wavePath.move(to: CGPoint(x: x, y: y))
                            hasMoved = true
                        } else {
                            wavePath.addLine(to: CGPoint(x: x, y: y))
                        }
                    }

                    // Draw the wave trace — stummgeschaltete Stimmen gedimmt zeichnen
                    // (die Emulation laeuft weiter, nur der Mix-Beitrag fehlt).
                    let isMuted = mutedChannels[displayedChip * 3 + c]
                    let color = isMuted ? traceColors[c].opacity(0.25) : traceColors[c]
                    context.stroke(wavePath, with: .color(color), style: StrokeStyle(lineWidth: gate != 0 ? 2.0 : 1.0))

                    // Draw overlays labels
                    let gateStr = gate != 0 ? "GATE:ON " : "GATE:OFF"
                    let freqStr = freqHz > 20.0 ? "\(Int(round(freqHz))) Hz" : "0 Hz"
                    let envStr = "\(Int(round(Double(env) * 100.0)))%"
                    let wfStr = wfName(wf)
                    let mutedStr = isMuted ? " | MUTED" : ""
                    let textInfo = "SID \(displayedChip + 1) V\(c + 1) | \(wfStr) | [\(gateStr)] | Freq: \(freqStr) | Env: \(envStr)\(mutedStr)"

                    let resolvedText = context.resolve(Text(textInfo)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(color))
                    
                    context.draw(resolvedText, at: CGPoint(x: 10, y: channelH * CGFloat(c) + 12), anchor: .leading)
                }

                // Draw bottom HUD label
                let model = String(coordinator.modelForChip(displayedChip))
                let hudText = "SID \(displayedChip + 1) · \(model) // 3 TRACE"
                // HUD-Farbe passend zum Theme: halbtransparentes Neon-Gruen ist auf
                // Weiss unsichtbar -> im Hell-Modus dunkleres Gruen, etwas kraeftiger.
                let hudColor = isDark
                    ? Color.green.opacity(0.4)
                    : Color(red: 0.13, green: 0.50, blue: 0.13)
                let resolvedHud = context.resolve(Text(hudText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(hudColor))
                
                context.draw(resolvedHud, at: CGPoint(x: W - 10, y: H - 12), anchor: .trailing)
            }
        }
    }

    private func sidWaveSample(frac: Double, wf: Int, duty: Double) -> Double {
        if (wf & 0x80) != 0 { // Noise
            return Double.random(in: -1.0...1.0)
        }
        if (wf & 0x40) != 0 { // Pulse
            return frac < duty ? 1.0 : -1.0
        }
        if (wf & 0x20) != 0 { // Sawtooth
            return 2.0 * frac - 1.0
        }
        if (wf & 0x10) != 0 { // Triangle
            return frac < 0.5 ? 4.0 * frac - 1.0 : 3.0 - 4.0 * frac
        }
        return 0.0
    }

    private func wfName(_ wf: Int) -> String {
        if (wf & 0x80) != 0 { return "NOI" }
        if (wf & 0x40) != 0 { return "PUL" }
        if (wf & 0x20) != 0 { return "SAW" }
        if (wf & 0x10) != 0 { return "TRI" }
        return "---"
    }
}
