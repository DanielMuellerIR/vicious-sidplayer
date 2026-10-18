import Foundation

public enum AudioExportFileNames {
    public static func names(for titles: [String], existing: Set<String> = [], format: AudioExportFormat = .wav) -> [String] {
        var used = Set(existing.map(key))
        var nextNumber: [String: Int] = [:]
        return titles.map { title in
            let base = safeBase(title)
            let baseKey = key(base)
            var number = nextNumber[baseKey] ?? 1
            var name = number == 1 ? base + "." + format.rawValue : "\(base) (\(number)).\(format.rawValue)"
            while used.contains(key(name)) {
                number += 1
                name = "\(base) (\(number)).\(format.rawValue)"
            }
            used.insert(key(name))
            nextNumber[baseKey] = number + 1
            return name
        }
    }

    private static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func safeBase(_ value: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "<>:\"/\\|?*"))
        let cleaned = String(String.UnicodeScalarView(value.unicodeScalars.map { forbidden.contains($0) ? UnicodeScalar(95)! : $0 }))
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var result = ""
        for character in trimmed {
            let addition = String(character)
            if result.utf8.count + addition.utf8.count > 140 { break }
            result += addition
        }
        if result.isEmpty { result = "Track" }
        let prefix = result.split(separator: ".", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
        if reserved.contains(prefix) { result = "_" + result }
        return result
    }
}
