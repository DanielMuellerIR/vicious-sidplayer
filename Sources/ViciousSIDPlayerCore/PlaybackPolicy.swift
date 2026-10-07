public enum PlaybackPolicy {
    public static func shouldAdvance(isPlaying: Bool, autoNext: Bool,
                                     elapsed: Double, duration: Double) -> Bool {
        isPlaying && autoNext && elapsed >= duration
    }

    public static func shouldStartAfterScan(requested: Bool, suppressed: Bool,
                                           currentTrackIndex: Int,
                                           pendingTrackLoaded: Bool) -> Bool {
        requested && !suppressed && currentTrackIndex < 0 && !pendingTrackLoaded
    }
}
