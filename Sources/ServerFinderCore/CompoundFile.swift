import Foundation

/// Reads streams out of a Compound File held in memory: the container of older Office files
/// (.xls, .doc, .ppt) and of password-protected new ones. Read-only.
struct CompoundFile {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: Data
    /// Stream name → (first sector, size).
    private let streams: [String: (start: UInt32, size: Int)]

    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let damaged = ExtractionError(reason: "The file is damaged")

    init(data: Data) throws {
        guard data.count >= 512, data.starts(with: Self.signature) else { throw Self.damaged }
        self.data = data
        let sectorShift = Int(data.uint16(at: 0x1E))
        let miniSectorShift = Int(data.uint16(at: 0x20))
        guard sectorShift == 9 || sectorShift == 12, miniSectorShift == 6 else { throw Self.damaged }
        sectorSize = 1 << sectorShift
        miniSectorSize = 1 << miniSectorShift
        miniStreamCutoff = Int(data.uint32(at: 0x38))

        // The sectors holding the FAT are listed in the header (first 109), then in a DIFAT chain.
        var fatSectors: [UInt32] = (0..<109).map { data.uint32(at: 0x4C + $0 * 4) }
        var difatSector = data.uint32(at: 0x44)
        var visited = Set<UInt32>()
        while difatSector < 0xFFFF_FFFA, visited.insert(difatSector).inserted {
            let offset = (Int(difatSector) + 1) * sectorSize
            guard offset + sectorSize <= data.count else { throw Self.damaged }
            let perSector = sectorSize / 4 - 1
            fatSectors += (0..<perSector).map { data.uint32(at: offset + $0 * 4) }
            difatSector = data.uint32(at: offset + perSector * 4)
        }
        let fatCount = Int(data.uint32(at: 0x2C))
        var fat: [UInt32] = []
        for sector in fatSectors.prefix(fatCount) where sector < 0xFFFF_FFFA {
            let offset = (Int(sector) + 1) * sectorSize
            guard offset + sectorSize <= data.count else { throw Self.damaged }
            fat += (0..<sectorSize / 4).map { data.uint32(at: offset + $0 * 4) }
        }
        self.fat = fat

        let directory = try Self.chain(from: data.uint32(at: 0x30), fat: fat, sectorSize: sectorSize, in: data)
        var streams: [String: (start: UInt32, size: Int)] = [:]
        var root: (start: UInt32, size: Int)?
        for offset in stride(from: 0, to: directory.count - 127, by: 128) {
            let entry = directory.subdata(in: directory.startIndex + offset ..< directory.startIndex + offset + 128)
            let nameLength = min(Int(entry.uint16(at: 0x40)), 64)
            let type = entry[entry.startIndex + 0x42]
            let start = entry.uint32(at: 0x74)
            let size = Int(entry.uint32(at: 0x78)) // version 3 files keep only 32 bits here
            guard nameLength >= 2 else { continue }
            let name = String(decoding: (0..<(nameLength - 2) / 2).map { entry.uint16(at: $0 * 2) }, as: UTF16.self)
            switch type {
            case 5: root = (start, size)
            case 2: streams[name] = (start, size)
            default: break
            }
        }
        self.streams = streams

        // Small streams live inside the "mini stream", in 64-byte sectors chained by the mini FAT.
        let miniFATData = try Self.chain(from: data.uint32(at: 0x3C), fat: fat, sectorSize: sectorSize, in: data)
        miniFAT = (0..<miniFATData.count / 4).map { miniFATData.uint32(at: $0 * 4) }
        if let root, root.size > 0 {
            miniStream = try Self.chain(from: root.start, fat: fat, sectorSize: sectorSize, in: data).prefix(root.size)
        } else {
            miniStream = Data()
        }
    }

    /// The contents of the stream named `name` (top-level or nested), or nil if there's none.
    func stream(named name: String) throws -> Data? {
        guard let stream = streams[name] else { return nil }
        if stream.size < miniStreamCutoff {
            return try Self.chain(from: stream.start, fat: miniFAT, sectorSize: miniSectorSize, in: miniStream, headerSectors: 0)
                .prefix(stream.size)
        }
        return try Self.chain(from: stream.start, fat: fat, sectorSize: sectorSize, in: data).prefix(stream.size)
    }

    /// Joins the sectors of a chain. In the file itself, sector n starts after the header (one sector).
    private static func chain(
        from start: UInt32, fat: [UInt32], sectorSize: Int, in data: Data, headerSectors: Int = 1
    ) throws -> Data {
        var result = Data()
        var sector = start
        var steps = 0
        while sector != endOfChain, sector < 0xFFFF_FFFA {
            let offset = (Int(sector) + headerSectors) * sectorSize
            // A loop in a damaged chain would never end; no chain is longer than the FAT.
            guard offset + sectorSize <= data.count || headerSectors == 0 && offset < data.count,
                  Int(sector) < fat.count, steps <= fat.count
            else { throw damaged }
            let end = min(offset + sectorSize, data.count)
            result.append(data[data.startIndex + offset ..< data.startIndex + end])
            sector = fat[Int(sector)]
            steps += 1
        }
        return result
    }
}
