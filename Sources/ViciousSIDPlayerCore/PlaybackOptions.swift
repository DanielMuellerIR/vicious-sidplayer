import Foundation

public enum PlaybackRepeatMode: String, Codable, CaseIterable, Sendable {
    case off, subtune, file, sequence
}

public enum PlaybackOptionError: Error, LocalizedError, Sendable {
    case invalidDuration, invalidSettings
    public var errorDescription: String? {
        switch self {
        case .invalidDuration: return NSLocalizedString("Ungültige Dauer. Sekunden oder m:ss verwenden.", comment: "")
        case .invalidSettings: return NSLocalizedString("Wiedergabeeinstellungen sind nicht lesbar. Die vorhandenen Daten bleiben erhalten.", comment: "")
        }
    }
}

public enum PlaybackDurationInput {
    public static func text(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        return seconds.rounded() == seconds ? LibraryMetadata.durationDescription(seconds) : String(seconds)
    }

    public static func seconds(_ text: String, maximum: Double) throws -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let seconds: Double?
        if parts.count == 1 { seconds = Double(text) }
        else if parts.count == 2, let minutes = Double(parts[0]), let rest = Double(parts[1]),
                minutes.rounded() == minutes, minutes >= 0, rest >= 0, rest < 60 {
            seconds = minutes * 60 + rest
        } else { seconds = nil }
        guard let seconds, seconds.isFinite, seconds > 0, maximum.isFinite, maximum > 0, seconds <= maximum else {
            throw PlaybackOptionError.invalidDuration
        }
        return seconds
    }
}

public struct PlaybackSettingsDocument: Codable, Equatable, Sendable {
    public var version = 1
    public var repeatMode = PlaybackRepeatMode.off
    public var fadeOutSeconds = 0.0
    public var sleepMinutes = 30
    public var endTimes: [String: Double] = [:]
    public init() {}

    public static func endTimeKey(md5: String, subtune: Int) -> String? {
        guard md5.count == 32, md5.unicodeScalars.allSatisfy({ "0123456789abcdefABCDEF".unicodeScalars.contains($0) }),
              (0..<256).contains(subtune) else { return nil }
        return "\(md5.lowercased()):\(subtune)"
    }
    public func endTime(md5: String?, subtune: Int) -> Double? {
        guard !endTimes.isEmpty, let md5, (0..<256).contains(subtune) else { return nil }
        return endTimes["\(md5.lowercased()):\(subtune)"]
    }
    public mutating func setEndTime(_ seconds: Double?, md5: String, subtune: Int) throws {
        guard let key = Self.endTimeKey(md5: md5, subtune: subtune),
              seconds == nil || seconds!.isFinite && seconds! > 0 && seconds! <= WavRenderer.maximumDurationSeconds else {
            throw PlaybackOptionError.invalidSettings
        }
        endTimes[key] = seconds
    }
    public func validated() throws -> Self {
        guard version == 1, fadeOutSeconds.isFinite, (0...30).contains(fadeOutSeconds), (1...180).contains(sleepMinutes),
              endTimes.allSatisfy({ key, value in
                  let parts = key.split(separator: ":", omittingEmptySubsequences: false)
                  guard parts.count == 2, let sub = Int(parts[1]), Self.endTimeKey(md5: String(parts[0]), subtune: sub) == key else { return false }
                  return value.isFinite && value > 0 && value <= WavRenderer.maximumDurationSeconds
              }) else { throw PlaybackOptionError.invalidSettings }
        return self
    }
}

/// Der Gain ist unabhaengig von der Nutzerlautstaerke und wirkt erst auf den
/// fertigen Mix. Eine Zeitfrist wird nach Seek/Resume auf die Titelzeit projiziert.
public struct PlaybackFadeEnvelope: Equatable, Sendable {
    public let songEnd: Double?
    public let timerEnd: Double?
    public let seconds: Double
    public init(songEnd: Double? = nil, timerEnd: Double? = nil, seconds: Double = 0) {
        self.songEnd = songEnd.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.timerEnd = timerEnd.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.seconds = seconds.isFinite ? max(0, min(30, seconds)) : 0
    }
    public func gain(at elapsed: Double) -> Double {
        guard elapsed.isFinite else { return 1 }
        func gain(endingAt end: Double?) -> Double {
            guard let end else { return 1 }
            if elapsed >= end { return 0 }
            let span = min(seconds, end)
            guard span > 0 else { return 1 }
            return min(1, max(0, (end - max(0, elapsed)) / span))
        }
        return min(gain(endingAt: songEnd), gain(endingAt: timerEnd))
    }
}

public struct PlaybackSleepDeadline: Equatable, Sendable {
    public let deadline: Date
    public init(seconds: Double, now: Date = Date()) throws {
        guard seconds.isFinite, seconds > 0, seconds <= 180 * 60, now.timeIntervalSinceReferenceDate.isFinite else {
            throw PlaybackOptionError.invalidDuration
        }
        deadline = now.addingTimeInterval(seconds)
    }
    public func remaining(at now: Date = Date()) -> Double { max(0, deadline.timeIntervalSince(now)) }
    public func projectedTrackEnd(elapsed: Double, now: Date = Date()) -> Double {
        max(0, elapsed.isFinite ? elapsed : 0) + remaining(at: now)
    }
}

public enum PlaybackCompletionAction: Equatable, Sendable {
    case stop
    case subtune(Int)
    case advanceEntry(repeatSequence: Bool)
}

public enum PlaybackCompletionPolicy {
    public static func action(isPlaying: Bool, elapsed: Double, duration: Double, currentSubtune: Int, subtuneCount: Int,
                              entry: ListeningEntry?, autoNext: Bool, repeatMode: PlaybackRepeatMode,
                              hasExplicitEnd: Bool = false, stopAfterSubtune: Bool = false) -> PlaybackCompletionAction? {
        guard isPlaying, elapsed.isFinite, duration.isFinite, duration >= 0, elapsed >= duration,
              autoNext || repeatMode != .off || hasExplicitEnd || stopAfterSubtune else { return nil }
        if stopAfterSubtune || subtuneCount <= 0 { return .stop }
        switch repeatMode {
        case .subtune: return .subtune(max(0, min(subtuneCount - 1, currentSubtune)))
        case .file: return .subtune(currentSubtune >= 0 && currentSubtune < subtuneCount - 1 ? currentSubtune + 1 : 0)
        case .off, .sequence:
            guard autoNext || repeatMode == .sequence else { return .stop }
            if let next = ListeningPlaybackPolicy.nextSubtune(entry: entry, current: currentSubtune, count: subtuneCount) { return .subtune(next) }
            return .advanceEntry(repeatSequence: repeatMode == .sequence)
        }
    }
}
