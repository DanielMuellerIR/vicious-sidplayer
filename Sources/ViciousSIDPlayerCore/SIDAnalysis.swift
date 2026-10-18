import Foundation

public struct SIDPitch: Equatable, Sendable {
    public let hertz: Double
    public let midiNote: Int
    public let cents: Double
    public var name: String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[midiNote % 12])\(midiNote / 12 - 1)"
    }
    /// Nur einzelne tonale Wellenformen: Noise/Kombinationen/Digi sind keine
    /// verlässliche Tonhöhenmessung. Gate aus kann noch eine Releasephase sein.
    public static func estimate(register: Int, clock: C64Clock, waveform: Int, envelope: Double) -> Self? {
        guard (1...65535).contains(register), [0x10, 0x20, 0x40].contains(waveform),
              envelope.isFinite, envelope > 0.001 else { return nil }
        let hertz = clock.oscillatorFrequency(registerValue: register)
        let note = 69 + 12 * log2(hertz / 440)
        let rounded = Int(note.rounded())
        guard (0...127).contains(rounded) else { return nil }
        return Self(hertz: hertz, midiNote: rounded, cents: (note - Double(rounded)) * 100)
    }
}

public enum SIDRegister {
    public static let offsets = Array(0...0x18) + [0x1b, 0x1c]
    public static func label(_ offset: Int) -> String {
        if (0..<21).contains(offset) {
            let names = ["FREQ LO", "FREQ HI", "PULSE LO", "PULSE HI", "CONTROL", "ATTACK/DECAY", "SUSTAIN/RELEASE"]
            return "V\(offset / 7 + 1) \(names[offset % 7])"
        }
        switch offset {
        case 0x15: return "CUTOFF LO"
        case 0x16: return "CUTOFF HI"
        case 0x17: return "RESONANCE/ROUTING"
        case 0x18: return "MODE/VOLUME"
        case 0x1b: return "OSC3"
        case 0x1c: return "ENV3"
        default: return "—"
        }
    }
}
