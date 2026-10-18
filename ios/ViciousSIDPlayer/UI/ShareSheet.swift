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
    /// Fertige Dateien aus demselben Exportlauf.
    let urls: [URL]
    init(url: URL) { self.urls = [url] }
    init(urls: [URL]) { self.urls = urls }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        // Nichts zu tun: der Dialog bekommt seinen Inhalt einmalig beim Erzeugen.
    }
}

/// Der Ergebnislauf behält seine fertigen URLs, bis der Teilen-Dialog schließt.
struct ExportedFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}
