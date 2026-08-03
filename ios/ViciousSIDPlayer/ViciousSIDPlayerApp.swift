import SwiftUI

// Einstiegspunkt der iPhone-App.
//
// Der eigentliche Zustand haengt am AppModel (Player/AppModel.swift); diese
// Datei bleibt bewusst duenn und macht nur dreierlei: das Modell erzeugen,
// es in die View-Hierarchie reichen und die Szenenphase (aktiv / im
// Hintergrund) weitermelden.
//
// Warum die Szenenphase so wichtig ist: Audio soll im Hintergrund WEITERLAUFEN,
// das Oszilloskop und alle UI-Timer sollen dort aber STILLSTEHEN. Das ist der
// groesste Batteriehebel der App — 30 Bilder pro Sekunde zeichnen fuer einen
// ausgeschalteten Bildschirm waere reine Verschwendung.
@main
struct ViciousSIDPlayerApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                // „Oeffnen mit", AirDrop und die Dateien-App liefern die Datei
                // als URL hier ab — die Info.plist registriert den SID-Typ ja
                // genau dafuer. Ohne diesen Handler wuerde die App zwar
                // gestartet, die Datei aber kommentarlos ignoriert. Der Import
                // haengt nicht an `start()`: auch beim Kaltstart ueber eine
                // Datei ist die Bibliothek hier schon erreichbar.
                .onOpenURL { url in
                    model.handleIncomingFile(at: url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            model.scenePhaseChanged(to: newPhase)
        }
    }
}
