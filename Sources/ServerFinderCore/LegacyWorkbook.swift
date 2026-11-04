import Foundation

/// Reads the text typed into cells of an Excel 97–2003 workbook (.xls): a Compound File whose
/// `Workbook` stream is a list of BIFF8 records. Most cell text is stored once in the shared
/// string table (`SST`, continued in `CONTINUE` records); older writers put it in `LABEL` records.
/// Numbers and formulas aren't read.
enum LegacyWorkbook {
    private enum Record {
        static let bof: UInt16 = 0x0809
        static let filePass: UInt16 = 0x002F
        static let sst: UInt16 = 0x00FC
        static let `continue`: UInt16 = 0x003C
        static let label: UInt16 = 0x0204
        static let richLabel: UInt16 = 0x00D6
    }

    static func text(of data: Data, name: String) throws -> String {
        let file = try CompoundFile(data: data)
        guard let stream = try file.stream(named: "Workbook") else {
            if try file.stream(named: "Book") != nil {
                throw ExtractionError(reason: "\(name) was saved by Excel 95 or earlier")
            }
            throw ExtractionError(reason: "\(name) has no workbook")
        }
        guard stream.count >= 4, stream.uint16(at: 0) == Record.bof else {
            throw ExtractionError(reason: "\(name) isn't an Excel workbook")
        }

        var strings: [String] = []
        var characters = 0
        var offset = 0
        while offset + 4 <= stream.count, characters < TextExtractor.maxCharacters {
            let type = stream.uint16(at: offset)
            var end = offset + 4 + Int(stream.uint16(at: offset + 2))
            guard end <= stream.count else { break } // a cut-off last record: keep what was read
            switch type {
            case Record.filePass:
                throw ExtractionError(reason: "\(name) is password-protected")
            case Record.sst:
                var segments = [body(of: stream, from: offset, to: end)]
                while end + 4 <= stream.count, stream.uint16(at: end) == Record.continue {
                    let next = end + 4 + Int(stream.uint16(at: end + 2))
                    guard next <= stream.count else { break }
                    segments.append(body(of: stream, from: end, to: next))
                    end = next
                }
                let shared = sharedStrings(in: segments)
                strings += shared
                characters += shared.reduce(0) { $0 + $1.utf16.count }
            case Record.label, Record.richLabel:
                // Row, column and format (6 bytes), then the string.
                var cursor = Cursor(segments: [body(of: stream, from: offset, to: end)])
                if (try? cursor.skip(6)) != nil, let text = try? cursor.string() {
                    strings.append(text)
                    characters += text.utf16.count
                }
            default:
                break
            }
            offset = end
        }
        return strings.joined(separator: " ")
    }

    private static func body(of stream: Data, from offset: Int, to end: Int) -> Data {
        stream.subdata(in: stream.startIndex + offset + 4 ..< stream.startIndex + end)
    }

    /// The strings of the shared string table, in order. A damaged table yields what came before the damage.
    static func sharedStrings(in segments: [Data]) -> [String] {
        var cursor = Cursor(segments: segments)
        guard (try? cursor.skip(4)) != nil, let unique = try? cursor.uint32() else { return [] }
        var strings: [String] = []
        for _ in 0..<unique {
            guard let text = try? cursor.string() else { break }
            strings.append(text)
        }
        return strings
    }

    /// Reads across a record and its `CONTINUE` records as one stream of bytes, except that
    /// characters cut by a record boundary resume after a fresh flags byte (they may switch
    /// between one and two bytes per character there).
    private struct Cursor {
        let segments: [Data]
        var segment = 0
        var position = 0

        private static let ended = ExtractionError(reason: "The workbook is damaged")

        private var remainingInSegment: Int { segment < segments.count ? segments[segment].count - position : 0 }

        mutating func byte() throws -> UInt8 {
            while segment < segments.count, remainingInSegment == 0 { segment += 1; position = 0 }
            guard segment < segments.count else { throw Self.ended }
            let data = segments[segment]
            defer { position += 1 }
            return data[data.startIndex + position]
        }

        mutating func uint16() throws -> UInt16 { UInt16(try byte()) | UInt16(try byte()) << 8 }

        mutating func uint32() throws -> UInt32 { UInt32(try uint16()) | UInt32(try uint16()) << 16 }

        mutating func skip(_ count: Int) throws {
            var left = count
            while left > 0 {
                while segment < segments.count, remainingInSegment == 0 { segment += 1; position = 0 }
                guard segment < segments.count else { throw Self.ended }
                let step = min(left, remainingInSegment)
                position += step
                left -= step
            }
        }

        /// A BIFF8 Unicode string: character count, flags, optional formatting-run and
        /// phonetic sizes, the characters, then the formatting runs and phonetic data (skipped).
        mutating func string() throws -> String {
            let count = Int(try uint16())
            let flags = try byte()
            let runs = flags & 0x08 != 0 ? Int(try uint16()) : 0
            let phonetic = flags & 0x04 != 0 ? Int(try uint32()) : 0
            var units: [UInt16] = []
            units.reserveCapacity(count)
            var twoBytes = flags & 0x01 != 0
            while units.count < count {
                if remainingInSegment == 0 {
                    segment += 1
                    position = 0
                    guard segment < segments.count else { throw Self.ended }
                    twoBytes = try byte() & 0x01 != 0
                }
                units.append(twoBytes ? try uint16() : UInt16(try byte()))
            }
            try skip(runs * 4 + phonetic)
            // One byte per character means the first 256 Unicode characters (Latin-1).
            return String(decoding: units, as: UTF16.self)
        }
    }
}
