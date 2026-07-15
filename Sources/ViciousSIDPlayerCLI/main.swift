import Foundation
import ViciousSIDPlayerCore

// ============================================================================
// vicious-sid — der plattformuebergreifende CLI-Player.
//
// Laeuft auf macOS UND Linux. Das ist Absicht: so ist der Linux-Ausgabepfad
// schon auf dem Mac entwickel- und testbar, statt erst auf dem Zielrechner
// aufzufallen. Die Plattformweiche steckt vollstaendig in PCMSinkFactory —
// hier gibt es kein einziges #if os(...).
//
// Aufruf:
//   vicious-sid <datei.sid> [--subtune N] [--seconds S] [--wav <out.wav>] [--stdout]
//
// Ausgabe-Disziplin: stdout gehoert IMMER den Audiodaten (--stdout schreibt dort
// rohes PCM). Alles Menschenlesbare — Titel, Autor, Fortschritt, Fehler — geht
// nach stderr. Nur so bleibt `vicious-sid x.sid --stdout | aplay ...` sauber.
//
// Exit-Codes (fuer Skripte und Agenten):
//   0 = alles gut
//   1 = Argument- oder Parser-Fehler (die Datei ist kein brauchbares SID)
//   2 = I/O-Fehler (Datei nicht lesbar, Audio-Ausgabe kaputt, Platte voll)
// ============================================================================

let usage = """
usage: vicious-sid <datei.sid> [optionen]

Optionen:
  --subtune N     Subtune N abspielen (0-basiert, Default: 0)
  --seconds S     Nach S Sekunden beenden (Default: endlos bzw. 180 bei --wav)
  --wav <datei>   Statt abzuspielen als WAV-Datei rendern (schneller als Echtzeit)
  --stdout        Rohes PCM (s16le, interleaved) nach stdout statt an die Soundkarte
  -h, --help      Diese Hilfe

Tasten während der Wiedergabe (nur am Terminal):
  Leertaste       Pause / Weiter
  n / +           nächster Subtune
  p / -           vorheriger Subtune
  q / Strg-C      beenden

Beispiele:
  vicious-sid tune.sid --subtune 2
  vicious-sid tune.sid --stdout | aplay -f S16_LE -r 44100 -c 2      # Linux
  vicious-sid tune.sid --stdout | ffplay -f s16le -ar 44100 -ac 2 -i -   # macOS
  vicious-sid tune.sid --wav out.wav --seconds 30
"""

/// Schreibt eine Meldung nach stderr — niemals nach stdout, dort liegen die Audiodaten.
func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Bricht mit Meldung und Exit-Code ab.
func fail(_ message: String, code: Int32) -> Never {
    note(message)
    exit(code)
}

// MARK: - Argumente

var path: String?
var subtune = 0
var seconds: Double?
var wavPath: String?
var useStdout = false

var argIndex = 1
let args = CommandLine.arguments
while argIndex < args.count {
    let arg = args[argIndex]

    /// Holt den Wert hinter einer Option und meldet sauber, wenn er fehlt.
    func value(for option: String) -> String {
        guard argIndex + 1 < args.count else {
            fail("Fehler: \(option) erwartet einen Wert.\n\n\(usage)", code: 1)
        }
        argIndex += 1
        return args[argIndex]
    }

    switch arg {
    case "-h", "--help":
        note(usage)
        exit(0)
    case "--subtune":
        let raw = value(for: "--subtune")
        guard let parsed = Int(raw), parsed >= 0 else {
            fail("Fehler: --subtune erwartet eine Zahl >= 0, bekam '\(raw)'.", code: 1)
        }
        subtune = parsed
    case "--seconds":
        let raw = value(for: "--seconds")
        guard let parsed = Double(raw), parsed.isFinite, parsed > 0 else {
            fail("Fehler: --seconds erwartet eine positive Zahl, bekam '\(raw)'.", code: 1)
        }
        seconds = parsed
    case "--wav":
        wavPath = value(for: "--wav")
    case "--stdout":
        useStdout = true
    default:
        guard !arg.hasPrefix("-") else {
            fail("Fehler: unbekannte Option '\(arg)'.\n\n\(usage)", code: 1)
        }
        guard path == nil else {
            fail("Fehler: mehr als eine Datei angegeben ('\(path!)' und '\(arg)').", code: 1)
        }
        path = arg
    }
    argIndex += 1
}

guard let sidPath = path else {
    fail(usage, code: 1)
}

// --wav rendert in eine Datei, --stdout schreibt in die Pipe. Beides zusammen
// waere zweideutig (welche Ausgabe gilt?) — lieber klar ablehnen als raten.
if wavPath != nil && useStdout {
    fail("Fehler: --wav und --stdout schließen sich gegenseitig aus.", code: 1)
}

// MARK: - Datei laden und parsen

let data: Data
do {
    data = try Data(contentsOf: URL(fileURLWithPath: sidPath))
} catch {
    // Datei nicht da/nicht lesbar ist ein Umweltproblem, kein Formatfehler.
    fail("Fehler: '\(sidPath)' nicht lesbar — \(error.localizedDescription)", code: 2)
}

let sid: SidFileData
do {
    sid = try SidParser.parse(data: data)
} catch {
    fail("Fehler: '\(sidPath)' ist keine gültige SID-Datei — \(error)", code: 1)
}

// Subtune-Nummer gegen die Datei pruefen, bevor irgendetwas klingt.
guard subtune < sid.metadata.subtunesCount else {
    fail("Fehler: Subtune \(subtune) gibt es nicht — die Datei hat \(sid.metadata.subtunesCount) (0…\(sid.metadata.subtunesCount - 1)).",
         code: 1)
}

// Metadaten nach stderr (siehe Ausgabe-Disziplin oben).
note("Titel:    \(sid.metadata.title)")
note("Autor:    \(sid.metadata.author)")
note("Info:     \(sid.metadata.info)")
note("Subtune:  \(subtune + 1) von \(sid.metadata.subtunesCount)")
note("Modell:   \(sid.prefModel)")

// MARK: - WAV-Export

if let wavPath {
    let duration = seconds ?? 180.0
    do {
        try WavRenderer.render(sidFile: sid, subtune: subtune, seconds: duration,
                               to: URL(fileURLWithPath: wavPath))
    } catch {
        fail("Fehler beim WAV-Export: \(error.localizedDescription)", code: 2)
    }
    note("WAV geschrieben: \(wavPath) (\(Int(duration)) s)")
    exit(0)
}

// MARK: - Wiedergabe

// Das Format zuerst bestimmen, DANN den Controller damit bauen — der Processor
// muss seine Samplerate von Anfang an kennen (siehe PCMSinkFactory.preferredFormat).
let format = useStdout
    ? PCMFormat(sampleRate: 44100.0, channels: 2)   // Pipe: wir geben die Rate vor
    : PCMSinkFactory.preferredFormat(channels: 2)

let sink: PCMSink = useStdout
    ? StdoutPCMSink(format: format)
    : PCMSinkFactory.makeDefault(format: format)

// Ab hier fasst niemand mehr Sink oder Processor direkt an — alles laeuft ueber
// den Controller. Tastatur und (auf Linux) MPRIS2 sind nur Bedienfelder davor.
let controller = PlayerController(sid: sid,
                                  sink: sink,
                                  format: format,
                                  startSubtune: subtune,
                                  seconds: seconds)

if useStdout {
    note("Ausgabe:  rohes PCM auf stdout (s16le, \(Int(format.sampleRate)) Hz, \(format.channels) Kanäle)")
} else {
    note("Ausgabe:  Soundkarte (\(Int(format.sampleRate)) Hz, \(format.channels) Kanäle)")
}
note(seconds.map { "Dauer:    \(Int($0)) s" } ?? "Dauer:    endlos (Strg-C beendet)")

// MARK: - Tastatursteuerung

/// Nimmt den Endgrund vom Warte-Thread entgegen.
///
/// Warum ueberhaupt ein zweiter Thread: `waitUntilFinished()` blockiert bis zum
/// Ende des Stuecks. Wuerde der Haupt-Thread darin haengen, koennte er keine Tasten
/// lesen. Also wartet ein eigener Thread, und der Haupt-Thread pollt hier, ob schon
/// ein Grund vorliegt.
final class FinishBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: PCMSinkFinishReason?

    /// `nil` = laeuft noch.
    var reason: PCMSinkFinishReason? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: PCMSinkFinishReason) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

/// Spielt mit Tastatursteuerung und liefert den Endgrund.
///
/// Die Tastatur ist hier nur ein Bedienfeld: Sie sagt dem Controller, WAS
/// passieren soll, und weiss nicht, WIE. Genau deshalb kann auf Linux MPRIS2
/// parallel dasselbe tun, ohne dass sich die beiden ins Gehege kommen.
func runInteractive(controller: PlayerController) -> PCMSinkFinishReason {
    let box = FinishBox()
    let waiter = Thread { box.set(controller.waitUntilFinished()) }
    waiter.name = "vicious-sid.waiter"
    waiter.start()

    let terminal = RawTerminal()
    terminal.enter()
    // Egal wie diese Funktion verlassen wird: das Terminal MUSS zurueckgesetzt
    // werden, sonst bleibt die Shell des Nutzers ohne Echo und Zeilenpufferung
    // zurueck — also praktisch unbenutzbar.
    defer { terminal.restore() }

    /// Meldet den Subtune nach einem Wechsel. Die Nummer kommt vom Controller,
    /// nicht aus einer eigenen Zaehlung — sonst liefen Anzeige und Wirklichkeit
    /// auseinander, sobald MPRIS ebenfalls weiterschaltet.
    func reportSubtune() {
        guard controller.subtunesCount > 1 else {
            note("Diese Datei hat nur einen Subtune.")
            return
        }
        note("Subtune \(controller.currentSubtune + 1)/\(controller.subtunesCount)")
    }

    // Solange kein Endgrund vorliegt: Tasten lesen. readKey() wartet hoechstens
    // ~100 ms und liefert dann nil — dadurch bleibt die Schleife reaktionsfaehig
    // und merkt auch, wenn das Stueck von selbst zu Ende geht.
    while box.reason == nil {
        guard let key = terminal.readKey() else { continue }

        switch key {
        case UInt8(ascii: " "):
            controller.playPause()
            note(controller.state == .paused ? "Pause." : "Weiter.")
        case UInt8(ascii: "n"), UInt8(ascii: "+"):
            controller.next()
            reportSubtune()
        case UInt8(ascii: "p"), UInt8(ascii: "-"):
            controller.previous()
            reportSubtune()
        case UInt8(ascii: "q"), 0x03:
            // 0x03 ist Strg-C. Weil der Rohmodus ISIG abschaltet, kommt es als
            // ganz normales Byte herein statt als Signal — genau deshalb koennen
            // wir hier sauber aufraeumen, statt hart abgeschossen zu werden.
            controller.stop()
        default:
            break
        }
    }

    return box.reason ?? .stopped
}

do {
    try controller.start()
} catch {
    fail("Fehler: Audio-Ausgabe konnte nicht starten — \(error.localizedDescription)", code: 2)
}

// MPRIS2 anmelden, damit Medientasten und das Sound-Applet des Desktops den
// Player finden. Nur auf Linux, und nur als Zugabe: klappt es nicht (kein
// Session-Bus, etwa via SSH oder in einem Container), spielt der Player normal
// weiter — dafuer ist es kein Grund abzubrechen.
#if os(Linux)
let mpris = MPRISServer(controller: controller)
do {
    try mpris.start()
    note("MPRIS2:   angemeldet (Medientasten und Sound-Applet steuern mit)")
} catch {
    note("MPRIS2:   nicht verfügbar (\(error.localizedDescription)) — Wiedergabe läuft trotzdem")
}
defer { mpris.stop() }
#endif

// Tastatursteuerung nur, wenn stdin wirklich an einem Terminal haengt. Laeuft das
// CLI aus einem Skript oder mit umgeleiteter Eingabe, gibt es niemanden, der Tasten
// druecken koennte — dann einfach warten.
let finishReason: PCMSinkFinishReason
if RawTerminal.isInteractive {
    note("Tasten:   [Leer] Pause · [n]/[p] Subtune vor/zurück · [q] Ende")
    finishReason = runInteractive(controller: controller)
} else {
    finishReason = controller.waitUntilFinished()
}

// Den Grund in einen Exit-Code uebersetzen.
switch finishReason {
case .sourceFinished:
    note("Fertig.")
    exit(0)
case .stopped:
    note("Abgebrochen.")
    exit(0)
case .outputClosed:
    // Der Empfaenger der Pipe ist weg (aplay beendet, `| head`). Das ist bei
    // einem Programm, das nach stdout schreibt, voellig normal — kein Fehler.
    note("Ausgabe geschlossen.")
    exit(0)
case .failed(let detail):
    fail("Fehler während der Wiedergabe: \(detail)", code: 2)
case .notStarted:
    fail("Fehler: Wiedergabe lief nie an.", code: 2)
}
