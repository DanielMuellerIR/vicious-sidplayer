import Foundation

public struct SidMetadata: Sendable {
    public let title: String
    public let author: String
    public let info: String
    public let subtunesCount: Int
    public let prefModel: Int // 6581 or 8580
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
    public let timermodes: [Bool] // true for 16-bit timer (CIA), false for vertical blank interrupt (VBI)
    public let binaryData: Data // Execution binary to map into memory
}

public enum SidParser {
    public static func parse(data: Data) throws -> SidFileData {
        guard data.count >= 0x7C else {
            throw ParserError.invalidSize
        }

        // Magic check: "PSID" or "RSID"
        let magic = String(decoding: data.subdata(in: 0..<4), as: UTF8.self)
        guard magic == "PSID" || magic == "RSID" else {
            throw ParserError.invalidMagic
        }

        // Read big endian 16-bit fields
        let readUInt16 = { (offset: Int) -> UInt16 in
            return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        }

        let dataOffset = Int(readUInt16(6))
        
        var loadAddr = readUInt16(8)
        let initAddr = readUInt16(10)
        let playAddr = readUInt16(12)
        let subtunes = Int(readUInt16(14))
        
        // Timer modes: 32 bits starting at offset 18 (each bit maps to a subtune)
        var timermodes = [Bool](repeating: false, count: 32)
        for i in 0..<32 {
            let byteOffset = 18 + (i >> 3)
            let bitPos = 7 - (i % 8)
            timermodes[31 - i] = (data[byteOffset] & (1 << bitPos)) != 0
        }

        // Helper to read null-terminated Latin-1 strings (PSID/RSID header
        // fields are ISO 8859-1 per SID file format spec, not ASCII/UTF-8 —
        // e.g. "C.Hülsbeck" would otherwise show replacement characters)
        let readString = { (offset: Int, maxLength: Int) -> String in
            let sub = data.subdata(in: offset..<(offset + maxLength))
            let len = sub.firstIndex(of: 0) ?? maxLength
            let bytes = sub.subdata(in: 0..<len)
            // Latin-1 decoding cannot fail (every byte maps to a scalar)
            return (String(data: bytes, encoding: .isoLatin1) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let title = readString(0x16, 32)
        let author = readString(0x36, 32)
        let info = readString(0x56, 32)

        // Preferred SID Model from flags at 0x76-0x77
        // Bits 4-5 of offset 0x77 (flags LSB): 01 = 6581, 10 = 8580
        let prefModel = (data[0x77] & 0x30) >= 0x20 ? 8580 : 6581

        // Second and third SID addresses from 0x7A and 0x7B
        let getSidAddress = { (val: UInt8) -> UInt32 in
            if val >= 0x42 && (val < 0x80 || val >= 0xE0) {
                return 0xD000 + UInt32(val) * 16
            }
            return 0
        }
        let secondSidAddress = getSidAddress(data[0x7A])
        let thirdSidAddress = getSidAddress(data[0x7B])

        // Ladeadresse: Nur wenn das Header-Feld loadAddress 0 ist, stehen die
        // ersten zwei Bytes des Datenblocks als Little-Endian-Ladeadresse vor dem
        // C64-Binary (SID-Spec). Bei explizitem loadAddress im Header beginnt der
        // Datenblock DIREKT mit dem Binary — dann duerfen keine 2 Bytes
        // uebersprungen werden, sonst laedt der Code um 2 verschoben (Stille).
        let binaryOffset: Int
        if loadAddr == 0 {
            guard data.count >= dataOffset + 2 else {
                throw ParserError.invalidDataOffset
            }
            loadAddr = UInt16(data[dataOffset]) | UInt16(data[dataOffset + 1]) << 8
            binaryOffset = dataOffset + 2
        } else {
            binaryOffset = dataOffset
        }

        guard data.count > binaryOffset else {
            throw ParserError.emptyDataBlock
        }

        let binaryData = data.subdata(in: binaryOffset..<data.count)

        let metadata = SidMetadata(
            title: title.isEmpty ? "Unbekannter Titel" : title,
            author: author.isEmpty ? "Unbekannter Komponist" : author,
            info: info,
            subtunesCount: subtunes,
            prefModel: prefModel
        )

        return SidFileData(
            metadata: metadata,
            loadAddr: loadAddr,
            initAddr: initAddr == 0 ? loadAddr : initAddr,
            playAddr: playAddr,
            subtuneAmount: subtunes,
            prefModel: prefModel,
            secondSidAddress: secondSidAddress,
            thirdSidAddress: thirdSidAddress,
            timermodes: timermodes,
            binaryData: binaryData
        )
    }

    public enum ParserError: Error {
        case invalidSize
        case invalidMagic
        case invalidDataOffset
        case emptyDataBlock
    }
}
