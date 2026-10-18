import Foundation

public struct SidMetadata: Sendable {
    public let title: String
    public let author: String
    public let info: String
    public let subtunesCount: Int
    public let prefModel: Int
    let hasTitle: Bool
    let hasAuthor: Bool
}

public struct SidFileData: Sendable {
    public let metadata: SidMetadata
    public let loadAddr: UInt16
    public let initAddr: UInt16
    public let playAddr: UInt16
    public let subtuneAmount: Int
    public let prefModel: Int
    public let secondSidAddress: UInt32
    public let thirdSidAddress: UInt32
    // V3/v4 haben eigene Modelle; v5 verwendet für alle Chips dasselbe Modell.
    // 0 bedeutet weiterhin: Modell des ersten Chips übernehmen.
    public let prefModel2: Int
    public let prefModel3: Int
    public let clockPreference: SidClockPreference
    public let timermodes: [Bool]
    public let binaryData: Data
    public let formatVersion: Int
    public let isRSID: Bool
    public let embeddedSongLengths: [Double]?
    public let usesRepeatedSpeedBits: Bool
    let declaredModelBits: [Int]
}

public enum SidParser {
    public static func parse(data: Data) throws -> SidFileData {
        // Headerpositionen gelten ab Dateianfang, ein Data-Slice kann aber bei
        // einem anderen Index beginnen. Nur an dieser Grenze normalisieren.
        let data = data.startIndex == 0 ? data : Data(data)
        guard data.count >= 0x76 else { throw ParserError.invalidSize }
        let magic = String(decoding: data.prefix(4), as: UTF8.self)
        guard magic == "PSID" || magic == "RSID" else { throw ParserError.invalidMagic }
        let isRSID = magic == "RSID"
        func word(_ offset: Int) -> UInt16 { UInt16(data[offset]) << 8 | UInt16(data[offset + 1]) }
        let version = Int(word(4))
        guard (1...5).contains(version), !isRSID || version >= 2 else { throw ParserError.invalidVersion }
        let headerSize = version == 1 ? 0x76 : 0x7C
        guard data.count >= headerSize else { throw ParserError.invalidSize }
        let dataOffset = Int(word(6))
        guard dataOffset >= headerSize, dataOffset <= data.count,
              version != 5 || dataOffset == headerSize else { throw ParserError.invalidDataOffset }
        let flags = version >= 2 ? word(0x76) : 0
        if flags & 1 != 0 { throw ParserError.unsupportedMUS }
        if isRSID, word(8) != 0 || word(12) != 0 || data[18..<22].contains(where: { $0 != 0 }) {
            throw ParserError.invalidRSIDHeader
        }
        if isRSID, flags & 2 != 0 { throw ParserError.unsupportedBASIC }
        let declaredSongs = Int(word(14))
        if version == 5, !(1...256).contains(declaredSongs) { throw ParserError.invalidSongCount }
        // Ältere Dateien behalten die bisherige sichere Begrenzung. Die
        // Songnummer wird dem C64 im 8-Bit-Akkumulator übergeben.
        let subtunes = min(256, max(1, declaredSongs))
        let fields = metadataFields(Array(data[0x16..<0x76]), version: version)
        let commonModel = Int((flags >> 4) & 3)
        let prefModel = commonModel >= 2 ? 8580 : 6581
        func model(_ bits: Int) -> Int { bits >= 2 ? 8580 : (bits == 1 ? 6581 : 0) }
        let addresses: [UInt32]
        if version == 5 {
            addresses = try version5Addresses(configuration: data[0x7A], start: data[0x7B])
        } else {
            let second = version >= 3 ? sidAddress(data[0x7A]) : 0
            let third = version >= 4 ? sidAddress(data[0x7B]) : 0
            guard third == 0 || third != second else { throw ParserError.invalidSIDConfiguration }
            addresses = [0xD400, second, third]
        }
        if version == 5, flags & 0x800 != 0 {
            guard !addresses.contains(where: { $0 >= 0xDF00 }) else { throw ParserError.invalidSIDConfiguration }
            throw ParserError.unsupportedOPL
        }
        var declaredModels = [commonModel]
        if addresses[1] != 0 { declaredModels.append(version == 5 ? commonModel : Int((flags >> 6) & 3)) }
        if addresses[2] != 0 { declaredModels.append(version == 5 ? commonModel : Int((flags >> 8) & 3)) }
        var payloadEnd = data.count
        var embeddedLengths: [Double]?
        if version == 5, flags & 0x400 != 0 {
            payloadEnd -= subtunes * 4
            guard payloadEnd > dataOffset else { throw ParserError.invalidSongLengths }
            embeddedLengths = try (0..<subtunes).map { index in
                let offset = payloadEnd + index * 4
                guard let minutesSeconds = bcd(word(offset)), let milliseconds = bcd(word(offset + 2)),
                      minutesSeconds % 100 < 60, milliseconds < 1000 else { throw ParserError.invalidSongLengths }
                return Double(minutesSeconds / 100 * 60 + minutesSeconds % 100) + Double(milliseconds) / 1000
            }
        }
        // Bei loadAddress=0 liegt die Little-Endian-Adresse vor dem Binary.
        // Bei ausdrücklicher Headeradresse darf kein Programmbyte entfallen.
        var loadAddr = word(8)
        let binaryOffset: Int
        if loadAddr == 0 {
            guard payloadEnd >= dataOffset + 2 else { throw ParserError.invalidDataOffset }
            loadAddr = UInt16(data[dataOffset]) | UInt16(data[dataOffset + 1]) << 8
            binaryOffset = dataOffset + 2
        } else { binaryOffset = dataOffset }
        guard payloadEnd > binaryOffset else { throw ParserError.emptyDataBlock }
        let initAddr = word(10) == 0 ? loadAddr : word(10)
        if isRSID {
            guard loadAddr >= 0x07E8, initAddr >= 0x07E8,
                  initAddr < 0xA000 || (0xC000...0xCFFF).contains(initAddr) else { throw ParserError.invalidRSIDHeader }
        }
        if isRSID || version == 5 {
            guard Int(initAddr) >= Int(loadAddr), Int(initAddr) < Int(loadAddr) + payloadEnd - binaryOffset else {
                throw ParserError.invalidInitAddress
            }
        }
        let timermodes = (0..<32).map { index in
            let byte = data[18 + (3 - index / 8)]
            return byte & (1 << (index % 8)) != 0
        }
        let metadata = SidMetadata(title: fields[0].isEmpty ? "Unbekannter Titel" : fields[0],
            author: fields[1].isEmpty ? "Unbekannter Komponist" : fields[1], info: fields[2],
            subtunesCount: subtunes, prefModel: prefModel, hasTitle: !fields[0].isEmpty, hasAuthor: !fields[1].isEmpty)
        return SidFileData(metadata: metadata, loadAddr: loadAddr, initAddr: initAddr, playAddr: word(12),
            subtuneAmount: subtunes, prefModel: prefModel, secondSidAddress: addresses[1], thirdSidAddress: addresses[2],
            prefModel2: (3...4).contains(version) ? model(Int((flags >> 6) & 3)) : 0,
            prefModel3: version == 4 ? model(Int((flags >> 8) & 3)) : 0,
            clockPreference: SidClockPreference(rawValue: UInt8((flags >> 2) & 3))!, timermodes: timermodes,
            binaryData: data.subdata(in: binaryOffset..<payloadEnd), formatVersion: version, isRSID: isRSID,
            embeddedSongLengths: embeddedLengths, usesRepeatedSpeedBits: !isRSID && (version == 1 || flags & 2 != 0),
            declaredModelBits: declaredModels)
    }

    private static func metadataFields(_ bytes: [UInt8], version: Int) -> [String] {
        if version == 5 {
            var position = 0
            var fields: [String] = []
            for field in 0..<3 {
                let start = position
                while position < bytes.count && bytes[position] != 0 { position += 1 }
                guard position > start, field == 2 || position < bytes.count else { break }
                fields.append(decodeWindows1252(bytes[start..<position]))
                while position < bytes.count && bytes[position] == 0 { position += 1 }
            }
            // Nichtleere Bytefelder bleiben gültig, auch wenn ihre Anzeige nach
            // dem Trimmen leer ist. Sonst würden Autor und Jahr verrutschen.
            if fields.count == 3 { return fields }
        }
        // V5 verlangt diesen Fallback, unter anderem bei einem 32 Byte langen
        // alten Titelfeld ohne Nullabschluss. Die festen Felder bleiben gültig.
        return (0..<3).map { index in
            decodeWindows1252(bytes[(index * 32)..<((index + 1) * 32)].prefix { $0 != 0 })
        }
    }

    private static let windows1252: [UInt32] = [
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178
    ]
    private static func decodeWindows1252(_ bytes: some Sequence<UInt8>) -> String {
        // Foundation bietet nicht auf allen Zielplattformen dieselben alten
        // Codepages. Undefinierte Bytes bleiben als Ersatzzeichen sichtbar.
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            scalars.append(UnicodeScalar((0x80...0x9F).contains(byte) ? windows1252[Int(byte) - 0x80] : UInt32(byte))!)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sidAddress(_ byte: UInt8) -> UInt32 {
        guard byte & 1 == 0, (0x42...0x7E).contains(byte) || (0xE0...0xFE).contains(byte) else { return 0 }
        return 0xD000 + UInt32(byte) * 16
    }
    private static func version5Addresses(configuration: UInt8, start: UInt8) throws -> [UInt32] {
        if configuration == 0 {
            guard start == 0 else { throw ParserError.invalidSIDConfiguration }
            return [0xD400, 0, 0]
        }
        let count = Int(configuration & 15), layout = Int(configuration >> 4)
        guard (2...15).contains(count), layout <= 6 else { throw ParserError.invalidSIDConfiguration }
        guard count <= 3 else { throw ParserError.unsupportedChipCount(count) }
        let steps: [[UInt32]] = [[0x20], [0x40], [0x80], [0x100], [0x20, 0x60], [0x20, 0xE0], [0x100, 0x300]]
        var result: [UInt32] = [0xD400]
        let custom = sidAddress(start)
        if custom != 0 { result.append(custom) }
        var index = 0
        while result.count < count {
            var next = result.last! + steps[layout][index % steps[layout].count]
            if next >= 0xD800 && next < 0xDE00 { next += 0x600 }
            guard next <= 0xDFE0 else { throw ParserError.invalidSIDConfiguration }
            result.append(next); index += 1
        }
        while result.count < 3 { result.append(0) }
        return result
    }
    private static func bcd(_ word: UInt16) -> Int? {
        var value = 0
        for shift in [12, 8, 4, 0] {
            let digit = Int((word >> shift) & 15)
            guard digit <= 9 else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    public enum ParserError: Error, LocalizedError, Equatable {
        case invalidSize, invalidMagic, invalidVersion, invalidDataOffset, emptyDataBlock
        case invalidSongCount, invalidSongLengths, invalidSIDConfiguration, invalidRSIDHeader, invalidInitAddress
        case unsupportedMUS, unsupportedBASIC, unsupportedOPL, unsupportedChipCount(Int)

        public var isUnsupported: Bool {
            switch self {
            case .invalidVersion, .unsupportedMUS, .unsupportedBASIC, .unsupportedOPL, .unsupportedChipCount: return true
            default: return false
            }
        }
        public var errorDescription: String? {
            switch self {
            case .invalidSize: return NSLocalizedString("Der SID-Header ist unvollständig.", comment: "")
            case .invalidMagic: return NSLocalizedString("Die Datei hat keine PSID- oder RSID-Kennung.", comment: "")
            case .invalidVersion: return NSLocalizedString("Unterstützt werden PSID v1–v5 und RSID v2–v5.", comment: "")
            case .invalidDataOffset: return NSLocalizedString("Der Datenoffset des SID-Headers ist ungültig.", comment: "")
            case .emptyDataBlock: return NSLocalizedString("Die SID-Datei enthält kein C64-Programm.", comment: "")
            case .invalidSongCount: return NSLocalizedString("SID v5 benötigt 1 bis 256 Subtunes.", comment: "")
            case .invalidSongLengths: return NSLocalizedString("Die eingebetteten SID-Längen sind unvollständig oder ungültig.", comment: "")
            case .invalidSIDConfiguration: return NSLocalizedString("Die SID-Adresskonfiguration ist ungültig.", comment: "")
            case .invalidRSIDHeader: return NSLocalizedString("Der RSID-Header verletzt die Vorgaben für Ladeadresse, Startadresse, Play-Adresse oder Timer.", comment: "")
            case .invalidInitAddress: return NSLocalizedString("Die SID-Startadresse liegt außerhalb des geladenen C64-Programms.", comment: "")
            case .unsupportedMUS: return NSLocalizedString("MUS-Daten benötigen einen externen Player und werden nicht unterstützt.", comment: "")
            case .unsupportedBASIC: return NSLocalizedString("RSID mit BASIC-Start benötigt ein C64-BASIC-ROM und wird nicht unterstützt.", comment: "")
            case .unsupportedOPL: return NSLocalizedString("FM-OPL-Chips werden nicht unterstützt.", comment: "")
            case .unsupportedChipCount(let count): return String(format: NSLocalizedString("Diese Datei benötigt %d SID-Chips; der Player unterstützt höchstens 3.", comment: ""), count)
            }
        }
    }
}
