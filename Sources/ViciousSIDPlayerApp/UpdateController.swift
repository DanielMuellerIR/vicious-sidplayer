import Combine
import Sparkle

@MainActor
final class UpdateController: ObservableObject {
    // Eine Instanz für die gesamte App verhindert konkurrierende Update-Läufe.
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    @Published private(set) var canCheckForUpdates = false

    init() {
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
}
