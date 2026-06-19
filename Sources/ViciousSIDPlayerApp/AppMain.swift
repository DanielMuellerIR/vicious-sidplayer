import SwiftUI
import AppKit

// Empfaengt Dateien, die per Doppelklick / "Oeffnen mit" aus dem Finder kommen.
// SwiftUI allein liefert solche File-Open-Events nicht an die View — dafuer
// braucht es einen klassischen NSApplicationDelegate mit application(_:open:).
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Puffer: Bei Kaltstart (App war zu) feuert application(_:open:), BEVOR
    // MainView.onAppear seinen Observer registriert. Deshalb hier zwischenlagern
    // und beim Erscheinen der View nachziehen. (Alles Main-Thread -> static ok.)
    @MainActor static var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        AppDelegate.pendingURLs.append(contentsOf: urls)
        // Warmstart (App lief schon): View hoert mit und zieht den Puffer sofort.
        NotificationCenter.default.post(name: NSNotification.Name("openSIDFiles"), object: nil)
    }

    // Single-Window-App: schliesst man das Fenster, soll die App beenden
    // (kein verwaister Hintergrundprozess, der weiterspielt).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

@main
struct ViciousSIDPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Window (nicht WindowGroup): genau EIN Fenster. WindowGroup oeffnete beim
        // Datei-Open ein zweites Fenster mit eigener MainView/eigenem Coordinator
        // -> mehrere SIDs spielten gleichzeitig. Window verhindert das.
        Window("Vicious SID Player", id: "main") {
            MainView()
        }
        .commands {
            #if os(macOS)
            CommandMenu("Wiedergabe") {
                Button("Abspielen / Stoppen") {
                    NotificationCenter.default.post(name: NSNotification.Name("menuPlayStop"), object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)
                
                Button("Nächster Titel") {
                    NotificationCenter.default.post(name: NSNotification.Name("menuNextTrack"), object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                
                Button("Vorheriger Titel") {
                    NotificationCenter.default.post(name: NSNotification.Name("menuPrevTrack"), object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                
                Divider()
                
                Button("Design umschalten") {
                    NotificationCenter.default.post(name: NSNotification.Name("menuToggleTheme"), object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            #endif
        }
    }
}
