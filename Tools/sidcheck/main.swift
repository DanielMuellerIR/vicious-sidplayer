import Foundation
import ViciousSIDPlayerCore

// Headless-Werkzeug fuer eine einzelne .sid-Datei — zwei Modi:
//
// 1) Crash-Sweep (Default)
//    Zweck: Parser + 6502/SID-Emulation gegen eine Datei laufen lassen, um harte
//    Integer-/Range-Traps in der Emulation zu finden. Ein Trap killt den Prozess
//    (non-zero exit / Signal) — deshalb wird je Datei EIN Prozess gestartet, damit
//    ein Crash den Sweep nicht abreisst. Mit SWIFT_BACKTRACE=enable=yes druckt die
//    Swift-Runtime beim Trap einen symbolisierten Backtrace nach stderr (Dateizeile).
//
//    Aufruf: sidcheck <file.sid> [samplesProSubtune] [maxSubtunes]
//      exit 0  = sauber durchgelaufen ODER sauberer Parser-Fehler (kein Crash)
//      Trap    = Prozess stirbt mit Signal/Fatal-Error (genau das suchen wir)
//
// 2) Register-Dump (--dump)
//    Zweck: Subtune 0 headless abspielen und alle 20 ms (PAL-Frame) den sichtbaren
//    SID-Zustand (Frequenz, Gate, Waveform, Pulsbreite, Huellkurve je Stimme) als
//    JSON exportieren — z.B. fuer Noten-/Sound-Parameter-Analysen.
//
//    Aufruf: sidcheck <file.sid> --dump <out.json> [dauerSekunden]   (Default: 15)
//      exit 0  = Dump geschrieben
//      exit 1  = Fehler (anders als im Crash-Sweep zaehlt hier jeder Fehler,
//                weil der Aufrufer ein Ergebnis-File erwartet)
//
// 3) WAV-Export (--wav)
//    Zweck: einen Subtune schneller als Echtzeit als WAV-Datei rendern
//    (16-bit PCM mono, 44,1 kHz) — headless/skriptbar, siehe WavRenderer (Core).
//
//    Aufruf: sidcheck <file.sid> --wav <out.wav> [dauerSekunden] [subtune]
//            (Defaults: 180 s, Subtune 0; Subtune 0-basiert)
//      exit 0  = WAV geschrieben
//      exit 1  = Fehler

// Ein Eintrag pro SID-Stimme: die fuers Ohr relevanten Register-Werte.
struct ChannelFrame: Codable {
    let freq: Int    // Frequenzregister (16 Bit)
    let gate: Int    // Gate-Bit (1 = Ton an)
    let wave: Int    // Waveform-Bits (Dreieck/Saegezahn/Puls/Rauschen)
    let pw: Float    // Pulsbreite (0..1)
    let env: Float   // Huellkurven-Pegel (0..1)
}

// Ein Schnappschuss aller drei Stimmen zu einem Zeitpunkt.
struct SidFrame: Codable {
    let time: Double
    let ch1: ChannelFrame
    let ch2: ChannelFrame
    let ch3: ChannelFrame
}

let usage = "usage: sidcheck <file.sid> [samples] [maxSubtunes]\n" +
            "       sidcheck <file.sid> --dump <out.json> [dauerSekunden]\n" +
            "       sidcheck <file.sid> --wav <out.wav> [dauerSekunden] [subtune]\n"

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
let path = args[1]
let dumpMode = args.count >= 3 && args[2] == "--dump"
let wavMode = args.count >= 3 && args[2] == "--wav"

// Argumente des Dump-Modus vorab pruefen, damit ein fehlender Ausgabepfad
// nicht erst nach der Emulation auffaellt.
var dumpPath: String? = nil
var dumpDuration = 15.0
if dumpMode {
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    dumpPath = args[3]
    if args.count >= 5 { dumpDuration = Double(args[4]) ?? 15.0 }
}

// Argumente des WAV-Modus vorab pruefen (wie beim Dump-Modus).
var wavPath: String? = nil
var wavDuration = 180.0
var wavSubtune = 0
if wavMode {
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data(usage.utf8))
        exit(2)
    }
    wavPath = args[3]
    if args.count >= 5 { wavDuration = Double(args[4]) ?? 180.0 }
    if args.count >= 6 { wavSubtune = Int(args[5]) ?? 0 }
}

// Argumente des Crash-Sweeps (werden im Dump-/WAV-Modus ignoriert).
let samples = (!dumpMode && !wavMode && args.count >= 3) ? (Int(args[2]) ?? 22050) : 22050   // ~0.5 s @ 44100
let maxSubtunes = (!dumpMode && !wavMode && args.count >= 4) ? (Int(args[3]) ?? 32) : 32

do {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let sid = try SidParser.parse(data: data)
    if wavMode {
        // WAV-Export: eigener Renderer (baut sich seinen Processor selbst).
        try WavRenderer.render(sidFile: sid, subtune: wavSubtune, seconds: wavDuration,
                               to: URL(fileURLWithPath: wavPath!))
        print("WAV-Export von '\(sid.metadata.title)' (Subtune \(wavSubtune), \(Int(wavDuration)) s) nach '\(wavPath!)' geschrieben.")
        exit(0)
    }

    let proc = ViciousProcessor(sampleRate: 44100.0)
    _ = proc.loadSID(sidFile: sid)

    if dumpMode {
        // Subtune 0 initialisieren (das Hauptthema)
        proc.initSubtune(sub: 0)
        proc.setVolume(vol: 1.0)

        let totalSamples = Int(dumpDuration * 44100.0)
        let frameInterval = 882  // 50 Hz Interrupt-Takt bei 44.1 kHz (PAL)

        var frames: [SidFrame] = []
        for i in 0..<totalSamples {
            _ = proc.play()

            // Alle 20 ms (VBI-Frame) den Zustand des Soundchips loggen
            if i % frameInterval == 0 {
                let vis = proc.getChannelsData()
                let time = Double(i) / 44100.0
                let ch1 = ChannelFrame(freq: vis.frequencies.0, gate: vis.gates.0,
                                       wave: vis.waveforms.0, pw: vis.pulsewidths.0,
                                       env: vis.envelopes.0)
                let ch2 = ChannelFrame(freq: vis.frequencies.1, gate: vis.gates.1,
                                       wave: vis.waveforms.1, pw: vis.pulsewidths.1,
                                       env: vis.envelopes.1)
                let ch3 = ChannelFrame(freq: vis.frequencies.2, gate: vis.gates.2,
                                       wave: vis.waveforms.2, pw: vis.pulsewidths.2,
                                       env: vis.envelopes.2)
                frames.append(SidFrame(time: time, ch1: ch1, ch2: ch2, ch3: ch3))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(frames)
        try jsonData.write(to: URL(fileURLWithPath: dumpPath!))
        print("SID-Register-Dump von '\(sid.metadata.title)' nach '\(dumpPath!)' geschrieben (\(frames.count) Frames).")
        exit(0)
    }

    // Crash-Sweep: alle Subtunes kurz anspielen.
    var subs = max(1, sid.subtuneAmount)
    subs = min(subs, maxSubtunes)
    for s in 0..<subs {
        proc.initSubtune(sub: s)
        proc.setVolume(vol: 1.0)
        for _ in 0..<samples { _ = proc.play() }
    }
    exit(0)
} catch {
    if dumpMode || wavMode {
        // Im Dump-/WAV-Modus erwartet der Aufrufer eine Ausgabedatei — Fehler melden.
        FileHandle.standardError.write(Data("Fehler: \(error)\n".utf8))
        exit(1)
    }
    // Ein abgefangener Parser-Fehler ist KEIN Crash — die App behandelt solche
    // Dateien sauber. Nur unabfangbare Traps sollen den Sweep markieren.
    exit(0)
}
