import Foundation

public struct AnalysisMix: Equatable, Sendable {
    public private(set) var channelMuted = [Bool](repeating: false, count: 9)
    public private(set) var chipMuted = [Bool](repeating: false, count: 3)
    public private(set) var soloChannels: Set<Int> = []

    public init() {}

    public mutating func toggleChannelMuted(_ channel: Int) {
        guard channelMuted.indices.contains(channel) else { return }
        channelMuted[channel].toggle()
    }

    public mutating func toggleChipMuted(_ chip: Int) {
        guard chipMuted.indices.contains(chip) else { return }
        chipMuted[chip].toggle()
    }

    public mutating func toggleSolo(_ channel: Int) {
        guard channelMuted.indices.contains(channel) else { return }
        if !soloChannels.insert(channel).inserted { soloChannels.remove(channel) }
    }

    public mutating func clearSolos() { soloChannels.removeAll() }

    public mutating func setVoiceMuted(_ voice: Int, muted: Bool) {
        guard (0..<3).contains(voice) else { return }
        for chip in 0..<3 { channelMuted[chip * 3 + voice] = muted }
    }

    public func effectiveMuted(activeChips: [Int]) -> [Bool] {
        let active = Set(activeChips.filter { (0..<3).contains($0) })
        let solos = soloChannels.filter { active.contains($0 / 3) }
        return (0..<9).map { channel in
            let chip = channel / 3
            return !active.contains(chip) || chipMuted[chip] || channelMuted[channel]
                || !solos.isEmpty && !solos.contains(channel)
        }
    }
}
