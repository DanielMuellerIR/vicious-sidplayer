import SwiftUI
import UIKit

// Duenne Bruecke zum System-Teilen-Dialog.
//
// SwiftUI bringt zwar `ShareLink` mit, das reicht hier aber nicht: die
// WAV-Datei entsteht erst beim Antippen (der Renderer laeuft ein paar Sekunden),
// und `ShareLink` will sein Objekt schon vorher haben. Deshalb der klassische
// `UIActivityViewController`, den wir oeffnen, sobald die Datei fertig ist.
//
// `UIViewControllerRepresentable` ist der Standardweg, einen UIKit-Controller in
// SwiftUI einzubetten — keine private API, App-Store-tauglich.
struct ShareSheet: UIViewControllerRepresentable {
    /// Die zu teilende Datei (liegt im temporaeren Ordner der App).
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        // Nichts zu tun: der Dialog bekommt seinen Inhalt einmalig beim Erzeugen.
    }
}

/// Kleiner Umschlag, damit sich eine URL per `.sheet(item:)` praesentieren
/// laesst — `URL` allein ist nicht `Identifiable`.
struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}
