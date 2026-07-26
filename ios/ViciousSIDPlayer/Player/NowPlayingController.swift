import Foundation
import MediaPlayer
import UIKit

// Sperrbildschirm, Kontrollzentrum, AirPods und CarPlay.
//
// Zwei Systemdienste stecken dahinter, und sie machen Verschiedenes:
//
//   MPRemoteCommandCenter  — die Knoepfe. Was passiert, wenn jemand auf dem
//                            Sperrbildschirm „Pause" tippt oder die AirPods
//                            zweimal antippt.
//   MPNowPlayingInfoCenter — die Anzeige. Titel, Interpret, Dauer, Position.
//
// Zwei Regeln, die man leicht uebersieht und die beide teuer sind:
//
//  1. JEDER BEFEHLSBLOCK MUSS EINEN STATUS ZURUECKGEBEN. Gibt ein Handler
//     nichts oder `.commandFailed` zurueck, blendet iOS den zugehoerigen Knopf
//     auf dem Sperrbildschirm einfach aus. Das sieht dann nach einem Fehler in
//     der App aus, obwohl nur die Rueckmeldung fehlte.
//  2. DIE ANZEIGE NUR SPARSAM SCHREIBEN. Jede Zuweisung an `nowPlayingInfo`
//     ist ein Aufruf ueber Prozessgrenzen hinweg zum Medien-Dienst des Systems.
//     Bei 30 Bildern pro Sekunde waere das eine Heizung fuer den Akku, ohne dass
//     ein Mensch den Unterschied saehe. Deshalb: bei Zustandswechseln sofort,
//     fuer die reine Laufzeit hoechstens einmal pro Sekunde.
@MainActor
final class NowPlayingController {

    /// Alles, was auf dem Sperrbildschirm steht — in einem Wert, damit sich
    /// leicht feststellen laesst, ob sich ueberhaupt etwas geaendert hat.
    struct Snapshot: Equatable {
        var title: String
        var artist: String
        /// Zusatzzeile: Copyright-Feld der SID-Datei, bei mehreren Subtunes
        /// zusaetzlich die Subtune-Nummer.
        var album: String
        var duration: Double
        var elapsed: Double
        var isPlaying: Bool
        var isPaused: Bool

        /// Unterscheiden sich zwei Momentaufnahmen in etwas ANDEREM als der
        /// verstrichenen Zeit? Nur dann muss sofort geschrieben werden.
        func differsBeyondElapsed(from other: Snapshot) -> Bool {
            title != other.title
                || artist != other.artist
                || album != other.album
                || duration != other.duration
                || isPlaying != other.isPlaying
                || isPaused != other.isPaused
        }
    }

    // MARK: - Anschluesse an die Wiedergabe

    var playHandler: (() -> Void)?
    var pauseHandler: (() -> Void)?
    var toggleHandler: (() -> Void)?
    var nextHandler: (() -> Void)?
    var previousHandler: (() -> Void)?
    /// Zielposition in Sekunden (Ziehen der Fortschrittsleiste auf dem
    /// Sperrbildschirm).
    var seekHandler: ((Double) -> Void)?

    // MARK: - Interner Zustand

    private var didConfigure = false
    private var lastSnapshot: Snapshot?
    private var lastWrite: Date?
    private lazy var artwork: MPMediaItemArtwork? = NowPlayingController.makeArtwork()

    // MARK: - Befehle einrichten

    /// Registriert die Fernbedienungsbefehle. Mehrfachaufrufe sind harmlos.
    func configureCommands() {
        guard !didConfigure else { return }
        didConfigure = true
        installTargets()
    }

    /// Bewusst `nonisolated`.
    ///
    /// Die Handler von `MPRemoteCommandCenter` sind gewoehnliche
    /// Objective-C-Bloecke ohne Zusicherung, auf welchem Thread sie ankommen.
    /// Wuerden sie in einem `@MainActor`-Kontext entstehen, waeren sie selbst
    /// MainActor-isoliert — und wenn das System sie dann von einem anderen
    /// Thread aufruft, ist das ein Datenrennen. Deshalb entstehen sie hier ohne
    /// Isolation, geben sofort ihren Status zurueck und erledigen die eigentliche
    /// Arbeit in einem kurzen Sprung auf den MainActor.
    private nonisolated func installTargets() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            Task { @MainActor in self.playHandler?() }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            Task { @MainActor in self.pauseHandler?() }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            Task { @MainActor in self.toggleHandler?() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            Task { @MainActor in self.nextHandler?() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .noSuchContent }
            Task { @MainActor in self.previousHandler?() }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let target = positionEvent.positionTime
            Task { @MainActor in self.seekHandler?(target) }
            return .success
        }

        // Befehle, die dieser Player nicht anbietet, ausdruecklich abschalten —
        // sonst zeigt iOS Knoepfe an, die ins Leere laufen.
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changeRepeatModeCommand.isEnabled = false
        center.changeShuffleModeCommand.isEnabled = false
    }

    // MARK: - Anzeige aktualisieren

    /// Schreibt die Sperrbildschirm-Anzeige — gedrosselt.
    ///
    /// - Parameter force: bei echten Zustandswechseln (Titelwechsel, Play/Pause,
    ///   Sprung an eine andere Stelle) setzen. Dann wird sofort geschrieben,
    ///   sonst reagiert der Sperrbildschirm sichtbar traege.
    func update(_ snapshot: Snapshot, force: Bool = false) {
        let now = Date()
        let stateChanged = lastSnapshot.map { snapshot.differsBeyondElapsed(from: $0) } ?? true

        if !force && !stateChanged {
            // Es hat sich nur die Laufzeit bewegt: hoechstens einmal pro Sekunde.
            if let last = lastWrite, now.timeIntervalSince(last) < 1.0 { return }
        }

        lastSnapshot = snapshot
        lastWrite = now

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPMediaItemPropertyAlbumTitle: snapshot.album,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            // Die Rate steuert, ob die Fortschrittsanzeige auf dem
            // Sperrbildschirm von allein weiterlaeuft. Genau deshalb reicht es,
            // die Position nur im Sekundentakt nachzuziehen.
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? 1.0 : 0.0
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }

        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = snapshot.isPlaying ? .playing : (snapshot.isPaused ? .paused : .stopped)
    }

    /// Kein Titel geladen: Anzeige leeren, damit der Sperrbildschirm nicht
    /// weiter einen Song behauptet, den es nicht mehr gibt.
    func clear() {
        lastSnapshot = nil
        lastWrite = nil
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    // MARK: - Bild

    /// Erzeugt ein schlichtes Titelbild fuer den Sperrbildschirm.
    ///
    /// Bewusst gezeichnet statt aus den App-Ressourcen geladen: SID-Dateien
    /// enthalten kein Bildmaterial, und ein fest eingebautes Bild waere eine
    /// zusaetzliche Abhaengigkeit zum Ressourcen-Katalog. Drei Balken stehen fuer
    /// die drei Stimmen des SID-Chips.
    private nonisolated static func makeArtwork() -> MPMediaItemArtwork? {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setFillColor(UIColor(white: 0.08, alpha: 1.0).cgColor)
            cgContext.fill(CGRect(origin: .zero, size: size))

            // Drei Balken unterschiedlicher Hoehe, mittig gruppiert.
            let colors: [UIColor] = [
                UIColor(red: 0.30, green: 0.85, blue: 0.55, alpha: 1.0),
                UIColor(red: 0.35, green: 0.65, blue: 1.00, alpha: 1.0),
                UIColor(red: 1.00, green: 0.65, blue: 0.25, alpha: 1.0)
            ]
            let heights: [CGFloat] = [200, 300, 150]
            let barWidth: CGFloat = 60
            let gap: CGFloat = 40
            let totalWidth = CGFloat(colors.count) * barWidth + CGFloat(colors.count - 1) * gap
            var x = (size.width - totalWidth) / 2

            for (index, color) in colors.enumerated() {
                cgContext.setFillColor(color.cgColor)
                let height = heights[index]
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
                cgContext.fill(rect)
                x += barWidth + gap
            }
        }
        // Der Anforderungsblock wird vom System aufgerufen und liefert immer
        // dasselbe, bereits fertige Bild.
        return MPMediaItemArtwork(boundsSize: size) { _ in image }
    }
}
