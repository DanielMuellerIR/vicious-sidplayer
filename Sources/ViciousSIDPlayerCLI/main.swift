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

/// Zaehlt mit, wie viele Frames schon gerendert wurden, und deckelt sie auf die
/// per --seconds gewuenschte Dauer.
///
/// `@unchecked Sendable` ist hier ehrlich und kein Trick: nach `start()` fasst
/// AUSSCHLIESSLICH der Audio-Thread dieses Objekt an. Es gibt keinen zweiten
/// Zugriff, also auch kein Datenrennen — und ein Lock im Renderpfad waere sogar
/// schaedlich (siehe Echtzeit-Hinweis am `PCMRenderBlock`).
final class FrameBudget: @unchecked Sendable {
    private let limit: Int?
    private var rendered = 0

    /// - Parameter limit: Maximale Frame-Anzahl; `nil` = unbegrenzt.
    init(limit: Int?) {
        self.limit = limit
    }

    /// Gibt zurueck, wie viele der `requested` Frames noch erlaubt sind.
    /// Ein Wert kleiner als angefordert bedeutet fuer den Sink „Quelle erschoepft".
    func take(_ requested: Int) -> Int {
        guard let limit else { return requested }
        let remaining = max(0, limit - rendered)
        let granted = min(requested, remaining)
        rendered += granted
        return granted
    }
}

// Das Format zuerst bestimmen, DANN den Processor damit bauen — er muss seine
// Samplerate von Anfang an kennen (siehe PCMSinkFactory.preferredFormat).
let format = useStdout
    ? PCMFormat(sampleRate: 44100.0, channels: 2)   // Pipe: wir geben die Rate vor
    : PCMSinkFactory.preferredFormat(channels: 2)

let processor = ViciousProcessor(sampleRate: format.sampleRate)
_ = processor.loadSID(sidFile: sid)
processor.initSubtune(sub: subtune)
// Volle Lautstaerke: die Skalierung ist Sache der Quelle, nicht des Sinks
// (siehe Vertragskommentar in PCMSink.swift). Ein CLI hat keinen Mixer davor.
processor.setVolume(vol: 1.0)

let budget = FrameBudget(limit: seconds.map { Int($0 * format.sampleRate) })

// Der Renderblock. Laeuft auf dem Audio-/Pump-Thread: nichts allozieren,
// nichts loggen, nicht blockieren.
let render: PCMRenderBlock = { [processor, budget] buffer, frames in
    let granted = budget.take(frames)
    for frame in 0..<granted {
        // Immer stereo ziehen: bei 1 SID sind beide Kanaele identisch, bei
        // 2SID/3SID pannt der Processor die Chips selbst (playStereo).
        let sample = processor.playStereo()
        buffer[frame * 2] = Float(sample.left)
        buffer[frame * 2 + 1] = Float(sample.right)
    }
    return granted
}

let sink: PCMSink = useStdout
    ? StdoutPCMSink(format: format)
    : PCMSinkFactory.makeDefault(format: format)

if useStdout {
    note("Ausgabe:  rohes PCM auf stdout (s16le, \(Int(format.sampleRate)) Hz, \(format.channels) Kanäle)")
} else {
    note("Ausgabe:  Soundkarte (\(Int(format.sampleRate)) Hz, \(format.channels) Kanäle)")
}
note(seconds.map { "Dauer:    \(Int($0)) s" } ?? "Dauer:    endlos (Strg-C beendet)")

do {
    try sink.start(render: render)
} catch {
    fail("Fehler: Audio-Ausgabe konnte nicht starten — \(error.localizedDescription)", code: 2)
}

// Warten, bis die Wiedergabe endet — und den Grund in einen Exit-Code uebersetzen.
switch sink.waitUntilFinished() {
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
