import Foundation
import Testing
@testable import ServerFinderCore

@Suite struct ShareScannerTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func makeFile(_ path: String, bytes: Int = 3) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: url)
    }

    private func makeFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }

    private func scanAll(batchSize: Int = 500) async throws -> [FileRecord] {
        var records: [FileRecord] = []
        for try await batch in ShareScanner(batchSize: batchSize).scan(root: root) {
            records += batch
        }
        return records
    }

    @Test func findsEveryFileAndFolder() async throws {
        try makeFile("Top.txt")
        try makeFile("Clients/ACME/Cotización.xlsx")
        try makeFile("Clients/ACME/2024/Plano.dwg")
        try makeFolder("Empty Folder")

        let paths = Set(try await scanAll().map(\.relativePath))
        #expect(paths == [
            "Top.txt",
            "Clients",
            "Clients/ACME",
            "Clients/ACME/Cotización.xlsx",
            "Clients/ACME/2024",
            "Clients/ACME/2024/Plano.dwg",
            "Empty Folder",
        ])
    }

    @Test func recordsNameTypeAndSize() async throws {
        try makeFile("Docs/Report.pdf", bytes: 42)

        let records = try await scanAll()
        let file = try #require(records.first { $0.name == "Report.pdf" })
        #expect(file.isDirectory == false)
        #expect(file.size == 42)
        #expect(file.modifiedAt != nil)

        let folder = try #require(records.first { $0.name == "Docs" })
        #expect(folder.isDirectory)
        #expect(folder.size == 0)
    }

    @Test func emitsInBatches() async throws {
        for index in 0..<7 { try makeFile("File \(index).txt") }

        var batchSizes: [Int] = []
        for try await batch in ShareScanner(batchSize: 3).scan(root: root) {
            batchSizes.append(batch.count)
        }
        #expect(batchSizes == [3, 3, 1])
    }

    @Test func skipsHiddenFiles() async throws {
        try makeFile(".DS_Store")
        try makeFile("Visible.txt")

        #expect(try await scanAll().map(\.name) == ["Visible.txt"])
    }

    @Test func missingRootFailsClearly() async throws {
        let missing = root.appendingPathComponent("Not Mounted")

        await #expect(throws: ScanError.self) {
            for try await _ in ShareScanner().scan(root: missing) {}
        }
    }

    @Test func neverChangesTheScannedFolder() async throws {
        try makeFile("A/B/C.txt")
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

        _ = try await scanAll()

        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() == before)
    }
}
