import Foundation

// Erscheinungsbild-Modus der App (Einstellungen-Dialog, Cmd+,):
//   .auto  -> folgt dem Hell/Dunkel-Modus von macOS (Default)
//   .light -> immer hell
//   .dark  -> immer dunkel
// Liegt bewusst im Core (ohne SwiftUI), damit die Aufloesungslogik headless
// testbar ist — gleiches Muster wie AutoplayFolder.resolve.
public enum ThemeMode: String, CaseIterable, Sendable {
    case auto
    case light
    case dark

    // Gemeinsamer UserDefaults-Key fuer SettingsView, MainView und AppDelegate.
    public static let userDefaultsKey = "themeMode"

    // Robuste Herstellung aus dem gespeicherten String: unbekannte oder fehlende
    // Werte (z.B. Erststart, alte App-Version) fallen auf .auto zurueck.
    public init(storedValue: String?) {
        self = ThemeMode(rawValue: storedValue ?? "") ?? .auto
    }

    // Kernlogik: ergibt dieser Modus gerade ein dunkles Erscheinungsbild?
    // systemPrefersDark = aktueller Dark-Mode-Zustand von macOS.
    public func resolvesToDark(systemPrefersDark: Bool) -> Bool {
        switch self {
        case .auto: return systemPrefersDark
        case .light: return false
        case .dark: return true
        }
    }
}
