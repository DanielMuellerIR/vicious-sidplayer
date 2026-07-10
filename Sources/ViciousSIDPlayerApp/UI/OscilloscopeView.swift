import SwiftUI
import ViciousSIDPlayerCore

public struct OscilloscopeView: View {
    @ObservedObject var coordinator: ViciousCoordinator
    var theme: PlayerTheme

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
        // paused: !isPlaying friert die Animation ein — bei Pause bleibt das zuletzt
        // gezeichnete Bild stehen (die Wellenform im Moment des Pausierens), statt
        // weiterzuscrollen. Die Werte selbst bleiben ueber isPaused erhalten (unten).
        TimelineView(.animation(paused: !coordinator.isPlaying)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
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
                    let rawFreq = showWave ? coordinator.frequencies[c] : 0
                    let env = showWave ? Double(coordinator.envelopes[c]) : 0.0
                    let gate = showWave ? coordinator.gates[c] : 0
                    let wf = showWave ? coordinator.waveforms[c] : 0
                    let duty = Double(coordinator.pulsewidths[c])

                    let freqHz = Double(rawFreq) * 0.0587

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

                    // Draw the wave trace
                    let color = traceColors[c]
                    context.stroke(wavePath, with: .color(color), style: StrokeStyle(lineWidth: gate != 0 ? 2.0 : 1.0))

                    // Draw overlays labels
                    let gateStr = gate != 0 ? "GATE:ON " : "GATE:OFF"
                    let freqStr = freqHz > 20.0 ? "\(Int(round(freqHz))) Hz" : "0 Hz"
                    let envStr = "\(Int(round(Double(env) * 100.0)))%"
                    let wfStr = wfName(wf)
                    let textInfo = "V\(c + 1) | \(wfStr) | [\(gateStr)] | Freq: \(freqStr) | Env: \(envStr)"

                    let resolvedText = context.resolve(Text(textInfo)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(color))
                    
                    context.draw(resolvedText, at: CGPoint(x: 10, y: channelH * CGFloat(c) + 12), anchor: .leading)
                }

                // Draw bottom HUD label
                let model = coordinator.prefModel == 8580 ? "8580" : "6581"
                let hudText = "CHIP MODEL: C64 \(model) // CHANNELS: 3 TRACE"
                // HUD-Farbe passend zum Theme: halbtransparentes Neon-Gruen ist auf
                // Weiss unsichtbar -> im Hell-Modus dunkleres Gruen, etwas kraeftiger.
                let hudColor = isDark
                    ? Color.green.opacity(0.4)
                    : Color(red: 0.13, green: 0.50, blue: 0.13).opacity(0.55)
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
