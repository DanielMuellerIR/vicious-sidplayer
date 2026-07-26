import AVFoundation
import Foundation

// Die Audio-Sitzung des Systems — alles, was von aussen in unsere Wiedergabe
// hineinregiert.
//
// Auf dem Mac gibt es das nicht: dort teilen sich alle Programme die Ausgabe und
// niemand nimmt sie einem weg. Auf dem iPhone ist das anders. Drei Ereignisse
// muss eine Musik-App zwingend behandeln, sonst faellt sie in genau die Fallen,
// die jeder Nutzer kennt:
//
//  1. ANRUF (Interruption). Waehrend eines Telefonats schweigt die App. Danach
//     sagt das System, ob sie weitermachen darf (`.shouldResume`) — nur dann
//     darf sie es auch. Ungefragt wieder loszuspielen ist ein Fehler.
//  2. KOPFHOERER ABGEZOGEN (Route Change). Werden die Kopfhoerer gezogen, MUSS
//     die Wiedergabe stoppen. Sonst dudelt die Musik ploetzlich laut aus dem
//     Lautsprecher — der klassische Peinlichkeitsfehler im Zug oder Buero.
//     Beim Wiedereinstecken laeuft es NICHT von allein weiter; das entscheidet
//     der Nutzer.
//  3. MEDIA SERVICES RESET. Der Audio-Server des Systems kann abstuerzen und neu
//     starten. Danach sind AVAudioEngine und Session tot; alles muss neu
//     aufgebaut werden. Passiert selten, aber wenn, dann bleibt die App sonst
//     stumm, bis sie beendet wird.
//
// Was hier bewusst NICHT passiert: `setActive(true)`. Eine aktive Audio-Sitzung
// nimmt anderen Apps die Ausgabe weg. Das darf erst passieren, wenn wirklich
// gespielt wird — deshalb aktiviert `activate()` gezielt der Wiedergabecode, und
// der `ViciousCoordinator` tut es beim Aufbau der Engine ohnehin selbst.
@MainActor
final class AudioSessionController {

    /// Gewuenschte Groesse des Audio-Puffers in Sekunden.
    ///
    /// 10 ms ist der Startwert aus dem Plan: klein genug, dass Bedienung und Ton
    /// zusammenpassen, gross genug, dass der Emulator zwischen zwei Aufrufen des
    /// Echtzeit-Threads sicher fertig wird. Das System darf den Wunsch
    /// abweisen — deshalb „preferred".
    static let preferredIOBufferDuration: TimeInterval = 0.010

    // MARK: - Anschluesse an die Wiedergabe
    //
    // Der Controller kennt weder AppModel noch Coordinator. Er meldet nur, was
    // passiert ist; was daraus folgt, entscheidet der Wiedergabecode.

    /// „Bitte jetzt pausieren" (Anruf beginnt, Kopfhoerer weg).
    var pauseHandler: (() -> Void)?

    /// „Es darf weitergehen" — wird ausschliesslich nach einer Unterbrechung
    /// gerufen, die das System selbst zum Fortsetzen freigegeben hat.
    var resumeHandler: (() -> Void)?

    /// Der Audio-Server ist neu gestartet; die Engine muss neu gebaut werden.
    var mediaServicesResetHandler: (() -> Void)?

    /// Laeuft gerade Wiedergabe? Wird gebraucht, um nach einer Unterbrechung nur
    /// dann fortzusetzen, wenn vorher auch wirklich etwas lief.
    var isPlayingProvider: (() -> Bool)?

    // MARK: - Interner Zustand

    private var didConfigure = false

    /// Haben WIR wegen einer Unterbrechung pausiert? Nur dann darf `.shouldResume`
    /// die Wiedergabe wieder anwerfen. Hatte der Nutzer vorher selbst pausiert,
    /// bleibt es pausiert.
    private var didPauseForInterruption = false

    /// Die Beobachter-Marken bleiben liegen, solange die App laeuft. Ein
    /// `deinit`-Aufraeumen gibt es bewusst nicht: der Controller lebt so lange
    /// wie das AppModel, also so lange wie die App.
    private var observers: [NSObjectProtocol] = []

    // MARK: - Einrichten

    /// Setzt Kategorie und Puffergroesse und haengt sich an die
    /// Systembenachrichtigungen. Mehrfachaufrufe sind harmlos.
    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        applyConfiguration()
        observeSystemNotifications()
    }

    /// Kategorie `.playback` bedeutet: Ton auch bei stummgeschaltetem
    /// Klingelschalter und bei gesperrtem Bildschirm. Zusammen mit
    /// `UIBackgroundModes = [audio]` in der Info.plist ist das die Grundlage
    /// dafuer, dass die Musik in der Hosentasche weiterlaeuft.
    private func applyConfiguration() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            // Muss VOR dem Aktivieren gesetzt werden, sonst ignoriert das System
            // den Wunsch bis zur naechsten Aktivierung.
            try session.setPreferredIOBufferDuration(Self.preferredIOBufferDuration)
        } catch {
            // Kein Abbruch: die Wiedergabe versucht es trotzdem. Scheitert dann
            // auch der Engine-Start, meldet der Coordinator das.
            print("AudioSession-Konfiguration fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    /// Aktiviert die Sitzung. Vor jedem Start der Wiedergabe aufrufen — nach
    /// einer Unterbrechung hat das System sie deaktiviert, und ein Fortsetzen
    /// aus der Pause heraus wuerde sonst still scheitern.
    func activate() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession-Aktivierung fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    // MARK: - Systembenachrichtigungen

    private func observeSystemNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        // Zwei Details in den folgenden Bloecken sind wichtig:
        //
        //  - `queue: .main` sorgt dafuer, dass sie auf dem Hauptthread laufen.
        //    `MainActor.assumeIsolated` sagt dem Compiler genau das.
        //  - Die `Notification` selbst darf NICHT ueber die Aktorgrenze wandern:
        //    ihr `userInfo` kann beliebige Objekte enthalten und ist damit nicht
        //    threadsicher. Deshalb werden die benoetigten Zahlen direkt hier
        //    herausgezogen; hinueber gehen nur schlichte Werte.
        //  - `[weak self]`, weil die Benachrichtigungszentrale den Block bis zum
        //    Programmende festhaelt. Ein starker Verweis wuerde den Controller
        //    ebenso lange am Leben halten, auch wenn ihn niemand mehr braucht.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let typeRaw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let reasonRaw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonRaw: reasonRaw)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMediaServicesReset()
            }
        })
    }

    // MARK: - Reaktionen

    /// Anruf, Wecker, Siri: das System nimmt uns die Ausgabe voruebergehend weg.
    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        switch type {
        case .began:
            // Nur merken, wenn wirklich etwas lief — sonst wuerde die App nach
            // dem Anruf Musik starten, die der Nutzer nie angefordert hat.
            didPauseForInterruption = (isPlayingProvider?() ?? false)
            if didPauseForInterruption { pauseHandler?() }

        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            let shouldResume = options.contains(.shouldResume) && didPauseForInterruption
            didPauseForInterruption = false
            guard shouldResume else { return }
            // Die Sitzung ist waehrend der Unterbrechung deaktiviert worden.
            activate()
            resumeHandler?()

        @unknown default:
            break
        }
    }

    /// Ausgabeweg gewechselt. Interessant ist genau ein Grund.
    private func handleRouteChange(reasonRaw: UInt?) {
        guard let reasonRaw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw),
              reason == .oldDeviceUnavailable else { return }
        // Kopfhoerer gezogen oder Bluetooth-Verbindung weg. Pausieren, und zwar
        // ohne Merker: beim Wiedereinstecken laeuft NICHTS von allein weiter.
        didPauseForInterruption = false
        pauseHandler?()
    }

    /// Der Audio-Server des Systems ist neu gestartet. Alles, was wir vorher
    /// eingestellt hatten, ist weg — also Kategorie neu setzen und den
    /// Wiedergabecode die Engine neu aufbauen lassen.
    private func handleMediaServicesReset() {
        didConfigure = false
        didPauseForInterruption = false
        applyConfiguration()
        didConfigure = true
        mediaServicesResetHandler?()
    }
}
