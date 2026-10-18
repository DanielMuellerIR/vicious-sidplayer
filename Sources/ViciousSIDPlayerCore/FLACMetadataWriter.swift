import Foundation

enum FLACMetadataWriter {
    static func validate(_ url: URL, channels: Int, frames: Int) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try readExactly(42, from: file)
        guard header.prefix(4) == Data("fLaC".utf8), header[4] & 127 == 0,
              header[5..<8] == Data([0, 0, 34]) else { throw AudioExportError.invalidEncodedFile }
        let info = header[18..<26].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard info >> 44 == 44100, Int((info >> 41) & 7) + 1 == channels,
              (info >> 36) & 31 == 15, info & 0xFFFFFFFFF == UInt64(frames),
              try file.seekToEnd() > 42 else { throw AudioExportError.invalidEncodedFile }
    }

    /// RFC 9639: Vorbis-Kommentare sind UTF-8 mit Little-Endian-Längen;
    /// FLAC-Blocklängen sind dagegen 24 Bit Big Endian. Nur Metadaten ändern,
    /// alle anderen Blöcke und die bereits codierten Audioframes erhalten.
    static func write(_ comments: [String], source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard try readExactly(4, from: input) == Data("fLaC".utf8) else { throw AudioExportError.invalidEncodedFile }
        var blocks: [(UInt8, Data)] = []
        var total = 0, count = 0
        while true {
            try Task.checkCancellation()
            let header = try readExactly(4, from: input)
            let kind = header[0] & 127
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            total += length; count += 1
            guard kind != 127, total <= 16 * 1024 * 1024, count <= 1024,
                  count != 1 || (kind == 0 && length == 34) else { throw AudioExportError.invalidEncodedFile }
            let data = try readExactly(length, from: input)
            if kind != 4 { blocks.append((kind, data)) }
            if header[0] & 128 != 0 { break }
        }
        var comment = Data()
        func appendString(_ value: String) throws {
            let bytes = Data(value.utf8)
            guard bytes.count <= 1024 * 1024, comment.count + 4 + bytes.count <= 0xFFFFFF else { throw AudioExportError.invalidEncodedFile }
            var length = UInt32(bytes.count).littleEndian
            withUnsafeBytes(of: &length) { comment.append(contentsOf: $0) }
            comment.append(bytes)
        }
        try appendString("Vicious SID Player")
        guard comments.count <= 1024 else { throw AudioExportError.invalidEncodedFile }
        var entries = UInt32(comments.count).littleEndian
        withUnsafeBytes(of: &entries) { comment.append(contentsOf: $0) }
        for value in comments { try appendString(value) }
        guard comment.count <= 0xFFFFFF else { throw AudioExportError.invalidEncodedFile }
        blocks.append((4, comment))
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: Data("fLaC".utf8))
        for (index, block) in blocks.enumerated() {
            let (kind, data) = block
            try output.write(contentsOf: Data([kind | (index == blocks.count - 1 ? 128 : 0),
                UInt8((data.count >> 16) & 255), UInt8((data.count >> 8) & 255), UInt8(data.count & 255)]))
            try output.write(contentsOf: data)
        }
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: 65536), !data.isEmpty else { break }
            try output.write(contentsOf: data)
        }
        try output.synchronize()
    }

    static func readExactly(_ count: Int, from file: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            try Task.checkCancellation()
            guard let part = try file.read(upToCount: count - data.count), !part.isEmpty else { throw AudioExportError.invalidEncodedFile }
            data.append(part)
        }
        return data
    }
}
