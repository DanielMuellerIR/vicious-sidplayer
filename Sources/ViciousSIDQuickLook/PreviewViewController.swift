import AppKit
import QuickLookUI
import Combine
import ViciousSIDPlayerCore

// Quick-Look-Preview fuer .sid-Dateien: zeigt die Metadaten (Titel, Komponist,
// Copyright) und spielt den Song sofort ab.
//
// Design-Entscheidung Autoplay: Quick-Look-Views sind auf macOS nicht
// zuverlaessig interaktiv (Mausklicks erreichen die Extension je nach Host
// nicht immer). Deshalb startet die Wiedergabe automatisch beim Oeffnen des
// Previews und stoppt beim Schliessen. Die Buttons (Stopp/Subtune-Wechsel)
// funktionieren dort, wo der Host Klicks durchreicht.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {

    // Blaettert der Nutzer im Quick-Look-Panel zur naechsten Datei, erzeugt das
    // System einen NEUEN Controller, bevor der alte verschwindet — das vorige
    // Preview muss dann sofort verstummen, sonst spielen zwei Songs parallel.
    private static weak var activePreview: PreviewViewController?

    private let coordinator = ViciousCoordinator()
    private var cancellables: Set<AnyCancellable> = []

    // UI-Elemente (werden in loadView aufgebaut, in preparePreviewOfFile befuellt)
    private let titleLabel = PreviewViewController.makeLabel(size: 20, weight: .bold)
    private let composerLabel = PreviewViewController.makeLabel(size: 14, weight: .regular)
    private let infoLabel = PreviewViewController.makeLabel(size: 12, weight: .regular, secondary: true)
    private let timeLabel = PreviewViewController.makeLabel(size: 13, weight: .medium, monospacedDigits: true)
    private let subtuneLabel = PreviewViewController.makeLabel(size: 12, weight: .regular, secondary: true)
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let prevButton = NSButton(title: "◀︎", target: nil, action: nil)
    private let nextButton = NSButton(title: "▶︎", target: nil, action: nil)

    override func loadView() {
        // Kein Storyboard/NIB: die View wird komplett in Code aufgebaut.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        self.view = root

        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playButton.bezelStyle = .rounded
        prevButton.target = self
        prevButton.action = #selector(previousSubtune)
        prevButton.bezelStyle = .rounded
        nextButton.target = self
        nextButton.action = #selector(nextSubtune)
        nextButton.bezelStyle = .rounded

        let controls = NSStackView(views: [prevButton, playButton, nextButton, timeLabel])
        controls.orientation = .horizontal
        controls.spacing = 8

        let stack = NSStackView(views: [titleLabel, composerLabel, infoLabel, subtuneLabel, controls])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(14, after: infoLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -16)
        ])
    }

    // Wird von Quick Look fuer jede zu previewende Datei aufgerufen.
    func preparePreviewOfFile(at url: URL) async throws {
        let data = try Data(contentsOf: url)
        let sid = try SidParser.parse(data: data)

        // Vorheriges Preview stummschalten, dieses als aktives registrieren.
        PreviewViewController.activePreview?.coordinator.stop()
        PreviewViewController.activePreview = self

        coordinator.setSid(sid)

        titleLabel.stringValue = coordinator.trackName
        composerLabel.stringValue = coordinator.composer
        infoLabel.stringValue = coordinator.info

        // Subtune-Steuerung nur zeigen, wenn es mehr als einen Song gibt.
        let hasSubtunes = coordinator.subtunesCount > 1
        prevButton.isHidden = !hasSubtunes
        nextButton.isHidden = !hasSubtunes
        subtuneLabel.isHidden = !hasSubtunes

        // Laufzeit + Play-Zustand + Subtune-Anzeige live nachfuehren.
        coordinator.$elapsedSeconds
            .sink { [weak self] seconds in
                let total = Int(seconds)
                self?.timeLabel.stringValue = String(format: "%d:%02d", total / 60, total % 60)
            }
            .store(in: &cancellables)
        coordinator.$isPlaying
            .sink { [weak self] playing in
                self?.playButton.title = playing ? "■ Stopp" : "▶ Abspielen"
            }
            .store(in: &cancellables)
        coordinator.$currentSubtune
            .combineLatest(coordinator.$subtunesCount)
            .sink { [weak self] current, count in
                self?.subtuneLabel.stringValue = "Song \(current + 1) von \(count)"
            }
            .store(in: &cancellables)

        coordinator.play()
    }

    // Preview wird geschlossen (oder weggeblaettert): Wiedergabe beenden.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        coordinator.stop()
    }

    @objc private func togglePlayback() {
        // Kein echtes Pause: stop() baut die Engine ab, play() startet den
        // aktuellen Subtune von vorn — fuer ein Preview voellig ausreichend.
        if coordinator.isPlaying {
            coordinator.stop()
        } else {
            coordinator.play()
        }
    }

    @objc private func previousSubtune() {
        switchSubtune(to: coordinator.currentSubtune - 1)
    }

    @objc private func nextSubtune() {
        switchSubtune(to: coordinator.currentSubtune + 1)
    }

    private func switchSubtune(to sub: Int) {
        // Wrap-around ueber die Subtune-Liste, laufende Wiedergabe wechselt live.
        let count = coordinator.subtunesCount
        guard count > 0 else { return }
        coordinator.setSubtune(sub: (sub + count) % count)
    }

    private static func makeLabel(size: CGFloat,
                                  weight: NSFont.Weight,
                                  secondary: Bool = false,
                                  monospacedDigits: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if secondary {
            label.textColor = .secondaryLabelColor
        }
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
