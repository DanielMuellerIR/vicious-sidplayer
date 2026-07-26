import SwiftUI
import ViciousSIDPlayerCore

// Farbpalette der iPhone-App.
//
// Die Mac-App (`Sources/ViciousSIDPlayerApp/UI/Theme.swift`) definiert zwei
// komplette Paletten und faerbt damit jede Flaeche selbst — auf dem Mac ist das
// noetig, weil dort ein eigenes Fensterlayout gebaut wurde.
//
// Auf iOS macht das System den Grossteil: Listen, Formulare, Tab-Leiste und
// Bedienelemente holen ihre Farben von UIKit und wechseln automatisch zwischen
// Hell und Dunkel. Selbst faerben muessen wir nur dort, wo es keine passende
// Systemfarbe gibt — praktisch nur im Oszilloskop.
//
// Wichtig (steht so in AGENTS.md): im Hellmodus brauchen die Oszilloskopfarben
// genuegend Kontrast. Neon-Cyan auf Weiss ist unlesbar, deshalb bekommt der
// Hellmodus dunklere Varianten derselben Farbfamilien — exakt die Werte, die
// sich auf dem Mac bereits bewaehrt haben.
struct PlayerPalette {
    /// Ergibt der aktuelle Theme-Modus ein dunkles Erscheinungsbild?
    let isDark: Bool

    /// Baut die Palette aus dem gewaehlten Modus und dem, was das System gerade
    /// vorgibt. Die Entscheidungslogik selbst liegt im Core (`ThemeMode`), damit
    /// sie headless testbar bleibt und Mac und iPhone sich nicht auseinander
    /// entwickeln.
    init(themeMode: ThemeMode, systemScheme: ColorScheme) {
        self.isDark = themeMode.resolvesToDark(systemPrefersDark: systemScheme == .dark)
    }

    // MARK: - Oszilloskop

    /// Hintergrund der Zeichenflaeche.
    var scopeBackground: Color {
        isDark
            ? Color(red: 20 / 255, green: 20 / 255, blue: 22 / 255)
            : Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255)
    }

    /// Rasterlinien. Bewusst sehr schwach — sie sollen Orientierung geben und
    /// nicht mit den Kurven konkurrieren.
    var scopeGrid: Color {
        Color.gray.opacity(isDark ? 0.12 : 0.16)
    }

    /// Nulllinie eines Kanals.
    var scopeBaseline: Color {
        Color.gray.opacity(isDark ? 0.25 : 0.32)
    }

    /// Rahmen um die Zeichenflaeche.
    var scopeBorder: Color {
        isDark
            ? Color(red: 60 / 255, green: 60 / 255, blue: 62 / 255)
            : Color(red: 211 / 255, green: 211 / 255, blue: 213 / 255)
    }

    /// Kurvenfarben der drei SID-Stimmen.
    /// Dunkel: Neon (Cyan/Gruen/Pink). Hell: Petrol/Waldgruen/Magenta — dieselben
    /// Farbfamilien, nur dunkel genug, um auf hellem Grund lesbar zu bleiben.
    var traceColors: [Color] {
        isDark
            ? [.cyan, .green, .pink]
            : [Color(red: 0.00, green: 0.45, blue: 0.55),
               Color(red: 0.13, green: 0.50, blue: 0.13),
               Color(red: 0.75, green: 0.10, blue: 0.45)]
    }

    /// Farbe der Statuszeile unten rechts im Oszilloskop.
    var scopeHUD: Color {
        isDark
            ? Color.green.opacity(0.55)
            : Color(red: 0.13, green: 0.50, blue: 0.13).opacity(0.75)
    }

    // MARK: - Allgemein

    /// Akzentfarbe (Apple-Blau, je nach Modus die hellere oder dunklere Variante).
    /// Deckungsgleich mit `AccentColor` im Asset-Katalog.
    var accent: Color {
        isDark
            ? Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
            : Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255)
    }
}

extension ThemeMode {
    /// Uebersetzt den Modus in das, was SwiftUI an der Wurzel-View erwartet:
    /// `nil` heisst „System entscheidet".
    ///
    /// Auf dem Mac wird dafuer der globale Schluessel `AppleInterfaceStyle`
    /// gelesen, weil AppKit die eigene Override-Appearance zurueckmeldet und die
    /// Antwort damit unbrauchbar waere. Auf iOS gibt es dieses Problem nicht:
    /// `.preferredColorScheme(nil)` laesst schlicht das System entscheiden.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Beschriftung fuer die Auswahl in den Einstellungen.
    var localizedName: LocalizedStringKey {
        switch self {
        case .auto: return "Automatisch"
        case .light: return "Hell"
        case .dark: return "Dunkel"
        }
    }
}
