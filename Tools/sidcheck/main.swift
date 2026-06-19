import Foundation
import ViciousSIDPlayerCore

// Headless-Crash-Checker fuer eine einzelne .sid-Datei.
//
// Zweck: Parser + 6502/SID-Emulation gegen eine Datei laufen lassen, um harte
// Integer-/Range-Traps in der Emulation zu finden. Ein Trap killt den Prozess
// (non-zero exit / Signal) — deshalb wird je Datei EIN Prozess gestartet, damit
// ein Crash den Sweep nicht abreisst. Mit SWIFT_BACKTRACE=enable=yes druckt die
// Swift-Runtime beim Trap einen symbolisierten Backtrace nach stderr (Dateizeile).
//
// Aufruf: sidcheck <file.sid> [samplesProSubtune] [maxSubtunes]
//   exit 0  = sauber durchgelaufen ODER sauberer Parser-Fehler (kein Crash)
//   Trap    = Prozess stirbt mit Signal/Fatal-Error (genau das suchen wir)

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: sidcheck <file.sid> [samples] [maxSubtunes]\n".utf8))
    exit(2)
}
let path = args[1]
let samples = args.count >= 3 ? (Int(args[2]) ?? 22050) : 22050   // ~0.5 s @ 44100
let maxSubtunes = args.count >= 4 ? (Int(args[3]) ?? 32) : 32

do {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let sid = try SidParser.parse(data: data)
    let proc = ViciousProcessor(sampleRate: 44100.0)
    _ = proc.loadSID(sidFile: sid)

    var subs = max(1, sid.subtuneAmount)
    subs = min(subs, maxSubtunes)
    for s in 0..<subs {
        proc.initSubtune(sub: s)
        proc.setVolume(vol: 1.0)
        for _ in 0..<samples { _ = proc.play() }
    }
    exit(0)
} catch {
    // Ein abgefangener Parser-Fehler ist KEIN Crash — die App behandelt solche
    // Dateien sauber. Nur unabfangbare Traps sollen den Sweep markieren.
    exit(0)
}
