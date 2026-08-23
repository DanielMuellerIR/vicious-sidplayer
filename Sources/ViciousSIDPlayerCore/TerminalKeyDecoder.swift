import Foundation

// Setzt aus einzelnen Bytes vom Terminal ganze Tasten zusammen.
//
// Der Hintergrund: Im Rohmodus liest das CLI einzelne Bytes. Buchstaben sind
// damit erledigt, Pfeiltasten nicht — die senden eine Escape-Sequenz aus drei
// Bytes: `0x1B` `[` `A` fuer "oben", `B` unten, `C` rechts, `D` links. Wer nur
// das erste Byte anschaut, sieht ein Escape und wirft die zwei Folgebytes als
// Muell weg (bei "links" also ein `[` und ein `D` — das `D` landete dann als
// Buchstabe in der Tastenauswertung).
//
// Diese kleine Zustandsmaschine sammelt die Folgebytes ein. Sie steht im Core
// und nicht im CLI, weil ein ausfuehrbares Ziel aus XCTest nicht erreichbar ist
// — dieselbe Ueberlegung wie bei der Playlist-Logik der Mac-App.
public struct TerminalKeyDecoder: Sendable {

    /// Eine fertig erkannte Taste.
    public enum Key: Equatable, Sendable {
        /// Ein gewoehnliches Byte (Buchstabe, Leerzeichen, Strg-C = 0x03 …).
        case byte(UInt8)
        case up
        case down
        case right
        case left
    }

    private enum State {
        /// Nichts angefangen.
        case idle
        /// `0x1B` gesehen — kann Escape sein oder der Anfang einer Sequenz.
        case escape
        /// `0x1B [` oder `0x1B O` gesehen; das naechste Byte entscheidet.
        case sequence
    }

    private var state: State = .idle

    public init() {}

    /// Nimmt das naechste Byte entgegen.
    ///
    /// - Returns: die erkannte Taste, oder `nil`, wenn die Sequenz noch nicht
    ///   vollstaendig ist. `nil` heisst also "weiterlesen", nicht "verworfen".
    public mutating func feed(_ byte: UInt8) -> Key? {
        switch state {
        case .idle:
            if byte == 0x1B {
                state = .escape
                return nil
            }
            return .byte(byte)

        case .escape:
            // `[` ist die uebliche Einleitung, `O` schicken manche Terminals im
            // sogenannten Anwendungsmodus (etwa die Pfeiltasten in `less`).
            if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "O") {
                state = .sequence
                return nil
            }
            // Escape und dann etwas anderes: Das ist auf den meisten Terminals
            // die Alt-Taste zusammen mit diesem Zeichen. Das Escape faellt weg,
            // das Zeichen gilt.
            state = .idle
            return .byte(byte)

        case .sequence:
            state = .idle
            switch byte {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            case UInt8(ascii: "C"): return .right
            case UInt8(ascii: "D"): return .left
            default:
                // Irgendeine andere Sequenz (Bild auf, F5, Mausereignis …).
                // Wird verschluckt statt als Buchstabe missverstanden.
                return nil
            }
        }
    }

    /// Meldet, dass eine Weile nichts mehr kam.
    ///
    /// Ohne diese Meldung haenge ein einzelner Druck auf die Escape-Taste
    /// ewig in der Maschine: Sie wartet auf Folgebytes, die nie kommen. Das CLI
    /// ruft sie, sobald sein Lesevorgang leer zurueckkehrt.
    ///
    /// - Returns: das aufgestaute Escape, falls eines offen war.
    public mutating func idleTimeout() -> Key? {
        switch state {
        case .idle:
            return nil
        case .escape:
            state = .idle
            return .byte(0x1B)
        case .sequence:
            // Halb gelesene Sequenz — der Rest kommt nicht mehr. Verwerfen ist
            // hier richtig: `[` als Buchstabe auszugeben waere Unsinn.
            state = .idle
            return nil
        }
    }
}
