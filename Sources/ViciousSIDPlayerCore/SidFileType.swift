import Foundation

// Zentrale Wahrheit ueber "was ist eine SID-Datei".
//
// Vorher stand die Endung "sid" an einem halben Dutzend Stellen verstreut im
// Code, und der Oeffnen-Dialog der Mac-App filterte gar nicht (`.data` zeigt
// jede Datei). Beides haengt am selben Fakt, deshalb steht er jetzt genau
// einmal hier — plattformneutral, ohne UIKit/AppKit, damit Core, Mac-App,
// iOS-App, CLI und Quick Look dieselbe Konstante benutzen.
//
// Der UTI ist derselbe, den die App-Bundles in ihrer Info.plist exportieren
// (`UTExportedTypeDeclarations`). Aendert er sich dort, muss er sich hier
// mitaendern — sonst filtern die Dateidialoge auf einen Typ, den das System
// nicht kennt, und zeigen wieder nichts oder alles.
public enum SidFileType {
    /// Dateiendung ohne Punkt, kleingeschrieben.
    public static let fileExtension = "sid"

    /// Exportierter Uniform Type Identifier aus der Info.plist der App-Bundles.
    public static let uti = "com.viben.sid-tune"

    /// Menschenlesbare Bezeichnung (identisch zur `UTTypeDescription`).
    public static let localizedDescription = "Commodore 64 SID Tune"

    /// Erkennt eine SID-Datei am Namen. Bewusst nur ueber die Endung und
    /// case-insensitiv: Sammlungen aus dem Netz mischen `.sid` und `.SID`, und
    /// ein Inhalts-Check waere beim Scannen tausender Dateien viel zu teuer.
    /// Das Parsen (und damit die echte Pruefung) passiert spaeter beim Laden.
    public static func matches(_ url: URL) -> Bool {
        return url.pathExtension.lowercased() == fileExtension
    }
}
