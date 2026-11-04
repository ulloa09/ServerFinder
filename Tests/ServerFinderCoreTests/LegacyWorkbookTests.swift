import Foundation
import Testing
@testable import ServerFinderCore

@Suite struct LegacyWorkbookTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyWorkbookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // MARK: Building .xls files (no tool on the Mac writes them)

    private func uint16(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)] }
    private func uint32(_ value: Int) -> [UInt8] { uint16(value & 0xFFFF) + uint16(value >> 16) }

    private func record(_ type: Int, _ body: [UInt8]) -> [UInt8] { uint16(type) + uint16(body.count) + body }

    /// Characters only: one byte each (Latin-1) or two (UTF-16).
    private func characters(_ text: String, twoBytes: Bool) -> [UInt8] {
        twoBytes ? text.utf16.flatMap { uint16(Int($0)) } : text.unicodeScalars.map { UInt8($0.value) }
    }

    /// A BIFF8 string: count, flags, characters.
    private func string(_ text: String, twoBytes: Bool = false) -> [UInt8] {
        uint16(text.utf16.count) + [twoBytes ? 1 : 0] + characters(text, twoBytes: twoBytes)
    }

    private var bof: [UInt8] { record(0x0809, uint16(0x0600) + uint16(0x0005) + [UInt8](repeating: 0, count: 12)) }
    private var eof: [UInt8] { record(0x000A, []) }

    private func sst(_ strings: [[UInt8]]) -> [UInt8] {
        record(0x00FC, uint32(strings.count) + uint32(strings.count) + strings.flatMap { $0 })
    }

    private func label(_ text: String, twoBytes: Bool = false) -> [UInt8] {
        record(0x0204, uint16(0) + uint16(0) + uint16(15) + string(text, twoBytes: twoBytes))
    }

    /// A version 3 Compound File (512-byte sectors) holding one stream. Streams under 4,096 bytes
    /// go in the mini stream, as Excel stores them.
    private func compoundFile(stream: [UInt8], named name: String) -> Data {
        let sectorSize = 512
        let endOfChain = 0xFFFF_FFFE, free = 0xFFFF_FFFF
        func sectors(_ bytes: [UInt8]) -> [[UInt8]] {
            stride(from: 0, to: bytes.count, by: sectorSize).map { start in
                let chunk = Array(bytes[start ..< min(start + sectorSize, bytes.count)])
                return chunk + [UInt8](repeating: 0, count: sectorSize - chunk.count)
            }
        }
        var fat = [0xFFFF_FFFD, endOfChain] // sector 0: the FAT itself; sector 1: the directory
        var body: [[UInt8]] = []
        func appendChain(_ chunks: [[UInt8]]) -> Int {
            let first = 2 + body.count
            for index in chunks.indices { fat.append(index == chunks.count - 1 ? endOfChain : first + index + 1) }
            body += chunks
            return first
        }

        let small = stream.count < 4_096
        var streamStart: Int
        var rootStart = endOfChain, rootSize = 0, miniFATStart = endOfChain, miniFATCount = 0
        if small {
            let miniSectors = (stream.count + 63) / 64
            let miniFAT = (0..<miniSectors).flatMap { uint32($0 == miniSectors - 1 ? endOfChain : $0 + 1) }
            miniFATStart = appendChain(sectors(miniFAT + [UInt8](repeating: 0xFF, count: sectorSize - miniFAT.count % sectorSize)))
            miniFATCount = 1
            let miniStream = stream + [UInt8](repeating: 0, count: miniSectors * 64 - stream.count)
            rootStart = appendChain(sectors(miniStream))
            rootSize = miniStream.count
            streamStart = 0
        } else {
            streamStart = appendChain(sectors(stream))
        }

        func entry(_ name: String, type: UInt8, child: Int, start: Int, size: Int) -> [UInt8] {
            let nameBytes = characters(name, twoBytes: true) + [0, 0]
            var bytes = nameBytes + [UInt8](repeating: 0, count: 64 - nameBytes.count)
            bytes += uint16(nameBytes.count) + [type, 1] + uint32(free) + uint32(free) + uint32(child)
            bytes += [UInt8](repeating: 0, count: 36) + uint32(start) + uint32(size) + uint32(0)
            return bytes
        }
        let directory = entry("Root Entry", type: 5, child: 1, start: rootStart, size: rootSize)
            + entry(name, type: 2, child: free, start: streamStart, size: stream.count)
            + [UInt8](repeating: 0, count: 256)

        var header: [UInt8] = CompoundFile.signature + [UInt8](repeating: 0, count: 16)
        header += uint16(0x3E) + uint16(3) + uint16(0xFFFE) + uint16(9) + uint16(6) + [UInt8](repeating: 0, count: 10)
        header += uint32(1) + uint32(1) + uint32(0) + uint32(4_096)
        header += uint32(miniFATStart) + uint32(miniFATCount) + uint32(endOfChain) + uint32(0)
        header += uint32(0) + (1..<109).flatMap { _ in uint32(free) }

        let fatSector = fat.flatMap { uint32($0) } + (fat.count..<128).flatMap { _ in uint32(free) }
        return Data(header + fatSector + directory + body.flatMap { $0 })
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func workbook(_ records: [UInt8], as name: String, large: Bool = false, stream: String = "Workbook") throws -> URL {
        var bytes = bof + records + eof
        if large { bytes += [UInt8](repeating: 0, count: 5_000) } // past the mini stream cutoff
        return try write(compoundFile(stream: bytes, named: stream), as: name)
    }

    private func text(_ url: URL) throws -> String {
        guard case .text(let text) = try TextExtractor.text(of: url) else {
            Issue.record("expected text from \(url.lastPathComponent)")
            return ""
        }
        return text
    }

    // MARK: Tests

    @Test(arguments: [false, true])
    func readsSharedStringsAndLabels(large: Bool) throws {
        let url = try workbook(
            sst([string("Póliza de seguro"), string("Résumé — 2024", twoBytes: true)]) + label("Gastos de oficina"),
            as: "polizas.xls", large: large
        )
        #expect(try text(url) == "Póliza de seguro Résumé — 2024 Gastos de oficina")
    }

    @Test func readsAStringSplitAcrossRecords() throws {
        // "Evaluación" starts in the SST record with one byte per character, then continues
        // in a CONTINUE record that switches to two bytes per character.
        let first = uint16(10) + [0] + characters("Evalua", twoBytes: false)
        let sstRecord = record(0x00FC, uint32(2) + uint32(2) + first)
        let continued = record(0x003C, [1] + characters("ción", twoBytes: true) + string("Final"))
        let url = try workbook(sstRecord + continued, as: "evaluacion.xls")
        #expect(try text(url) == "Evaluación Final")
    }

    @Test func skipsFormattingAndPhoneticData() throws {
        // Flags 0x0C: formatting runs (1 × 4 bytes) and phonetic data (3 bytes) follow the characters.
        let rich = uint16(5) + [0x0C] + uint16(1) + uint32(3) + characters("Total", twoBytes: false)
            + [UInt8](repeating: 0xAA, count: 4) + [0xBB, 0xBB, 0xBB]
        let url = try workbook(sst([rich, string("Pagado")]), as: "rico.xls")
        #expect(try text(url) == "Total Pagado")
    }

    @Test func passwordProtectedWorkbookThrows() throws {
        let url = try workbook(record(0x002F, [UInt8](repeating: 0, count: 54)) + sst([string("Secreto")]), as: "protegido.xls")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }

    @Test func damagedWorkbookThrows() throws {
        let url = try write(Data(CompoundFile.signature + [UInt8](repeating: 0x42, count: 600)), as: "roto.xls")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }

    @Test func excel95WorkbookThrows() throws {
        let url = try workbook(label("Viejo"), as: "viejo.xls", stream: "Book")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }

    @Test func readsAWebPageSavedAsXLS() throws {
        let html = """
            <html><head><meta charset="utf-8"><style>td { mso-number-format: "0.00"; }</style></head>
            <body><table><tr><td>Estado de cuenta</td><td>Comisi&#243;n &amp; IVA</td></tr></table></body></html>
            """
        let url = try write(Data(html.utf8), as: "estado.xls")
        #expect(try text(url) == "Estado de cuenta Comisión & IVA")
    }

    @Test func otherFilesNamedXLSThrow() throws {
        let url = try write(Data([0x00, 0x01, 0x02, 0x03]), as: "binario.xls")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }
}
