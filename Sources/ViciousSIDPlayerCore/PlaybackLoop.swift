import Foundation

/// Sitzungsmarker; weder Sammlungsaustausch noch Session-Restore speichern sie.
public struct PlaybackLoop: Equatable, Sendable {
    public static let minimumSpan = 0.25
    public private(set) var start: Double?
    public private(set) var end: Double?
    public private(set) var isEnabled = false
    public init() {}

    public var range: ClosedRange<Double>? {
        guard let start, let end, end - start >= Self.minimumSpan else { return nil }
        return start...end
    }
    public mutating func setStart(_ seconds: Double, duration: Double) {
        guard let value = Self.position(seconds, duration: duration) else { return }
        start = value
        if let end, end - value < Self.minimumSpan { self.end = nil }
        if range == nil { isEnabled = false }
    }
    public mutating func setEnd(_ seconds: Double, duration: Double) {
        guard let value = Self.position(seconds, duration: duration), let start,
              value - start >= Self.minimumSpan else { return }
        end = value
    }
    public mutating func setEnabled(_ enabled: Bool) { isEnabled = enabled && range != nil }
    public mutating func seek(to seconds: Double) {
        if !seconds.isFinite || range?.contains(seconds) != true { isEnabled = false }
    }
    public mutating func constrain(to duration: Double) {
        guard duration.isFinite, duration >= 0 else { isEnabled = false; return }
        if let end { self.end = min(end, duration) }
        if let start, start > duration { self.start = nil }
        if range == nil { isEnabled = false }
    }
    public mutating func clear() { self = Self() }
    private static func position(_ seconds: Double, duration: Double) -> Double? {
        guard seconds.isFinite, duration.isFinite, duration >= 0 else { return nil }
        return min(duration, max(0, seconds))
    }
}
