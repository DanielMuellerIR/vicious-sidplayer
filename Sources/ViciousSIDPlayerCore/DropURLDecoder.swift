import Foundation

/// Wandelt einen via Drag & Drop gelieferten "public.file-url"-Eintrag in eine
/// nutzbare Datei-URL um.
///
/// Hintergrund: Finder liefert den Drop-Eintrag meist als `Data`, die die
/// `file://`-URL repraesentiert (= `URL.dataRepresentation`). Der korrekte
/// Inverse ist `URL(dataRepresentation:relativeTo:)`. Frueher wurde der
/// decodierte String faelschlich an `URL(fileURLWithPath:)` uebergeben — das
/// deutet den ganzen "file://..."-String als Dateipfad und haengt ihn ans
/// aktuelle Arbeitsverzeichnis, sodass die Datei nie gefunden wurde.
public enum DropURLDecoder {
    /// Decodiert den NSItemProvider-Eintrag (Data / URL / String) zu einer URL.
    /// Gibt `nil` zurueck, wenn der Eintrag in keiner bekannten Form vorliegt.
    public static func url(fromItem item: Any?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let string = item as? String {
            // Kommt der Eintrag als String, ist es ein URL-String (file://...),
            // also per URL(string:) parsen, nicht als Pfad behandeln.
            return URL(string: string)
        }
        return nil
    }
}
