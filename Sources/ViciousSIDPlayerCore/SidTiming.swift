import Foundation

public enum C64Clock: String, Codable, CaseIterable, Sendable {
    case pal
    case ntsc

    public var cpuFrequency: Double { self == .pal ? 985248 : 1022727 }
    public var frameRate: Double { self == .pal ? 50 : 60 }
    public var defaultCIATimer: UInt16 { self == .pal ? 0x4025 : 0x4295 }
    public var label: String { rawValue.uppercased() }

    public func oscillatorFrequency(registerValue: Int) -> Double {
        Double(registerValue) * cpuFrequency / 16777216
    }
}

public enum SidClockMode: String, Codable, CaseIterable, Sendable {
    case auto
    case pal
    case ntsc

    public func resolve(_ preference: SidClockPreference) -> C64Clock {
        switch self {
        case .pal: return .pal
        case .ntsc: return .ntsc
        case .auto: return preference == .ntsc ? .ntsc : .pal
        }
    }
}

public enum SidClockPreference: UInt8, Codable, Sendable {
    case unknown = 0
    case pal = 1
    case ntsc = 2
    case both = 3

    public var label: String {
        switch self {
        case .unknown: return "Keine Taktangabe"
        case .pal: return "PAL"
        case .ntsc: return "NTSC"
        case .both: return "PAL/NTSC"
        }
    }
}
