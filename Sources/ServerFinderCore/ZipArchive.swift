import Compression
import Foundation

/// Reads files out of a ZIP archive held in memory (Office files like .pptx are ZIP archives).
/// Supports the two methods Office uses: stored and deflate. Read-only.
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    let entries: [Entry]

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    /// The uncompressed contents of `entry`.
    func contents(of entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard data.uint32(at: header) == 0x0403_4B50 else { throw Self.damaged }
        let nameLength = Int(data.uint16(at: header + 26))
        let extraLength = Int(data.uint16(at: header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw Self.damaged }
        let compressed = data.subdata(in: data.startIndex + start ..< data.startIndex + start + entry.compressedSize)

        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try inflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw ExtractionError(reason: "Unsupported ZIP compression method \(entry.method)")
        }
    }

    private func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        // A damaged archive could claim any size; nothing ServerFinder reads is this big.
        guard expectedSize <= 256 * 1_024 * 1_024 else { throw Self.damaged }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                // COMPRESSION_ZLIB is raw DEFLATE, exactly what ZIP stores.
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw Self.damaged }
        return output
    }

    private static let damaged = ExtractionError(reason: "The archive is damaged")

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        // The end-of-central-directory record sits in the last 22 bytes, plus up to 64 KB of comment.
        let minimumEnd = 22
        guard data.count >= minimumEnd else { throw damaged }
        var end = data.count - minimumEnd
        let lowestEnd = max(0, data.count - minimumEnd - 65_535)
        while end >= lowestEnd, data.uint32(at: end) != 0x0605_4B50 { end -= 1 }
        guard end >= lowestEnd else { throw damaged }

        let count = Int(data.uint16(at: end + 10))
        var offset = Int(data.uint32(at: end + 16))
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.uint32(at: offset) == 0x0201_4B50 else { throw damaged }
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            guard offset + 46 + nameLength <= data.count else { throw damaged }
            let nameStart = data.startIndex + offset + 46
            let name = String(decoding: data[nameStart ..< nameStart + nameLength], as: UTF8.self)
            entries.append(Entry(
                name: name,
                method: data.uint16(at: offset + 10),
                compressedSize: Int(data.uint32(at: offset + 20)),
                uncompressedSize: Int(data.uint32(at: offset + 24)),
                localHeaderOffset: Int(data.uint32(at: offset + 42))
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }
}

// Little-endian reads that return 0 past the end; callers check sizes where it matters.
extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
