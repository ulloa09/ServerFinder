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
            records += batch.records
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
            batchSizes.append(batch.records.count)
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

    @Test func skipsAndReportsFoldersItCannotRead() async throws {
        try makeFile("Public/Report.pdf")
        try makeFile("Private/Salaries.xlsx")
        let privateFolder = root.appendingPathComponent("Private")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: privateFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: privateFolder.path) }

        var records: [FileRecord] = []
        var unreadable: [String] = []
        for try await batch in ShareScanner().scan(root: root) {
            records += batch.records
            unreadable += batch.unreadableFolders
        }

        #expect(Set(records.map(\.relativePath)) == ["Public", "Public/Report.pdf", "Private"])
        #expect(unreadable == ["Private"])
    }

    @Test func shareDisappearingMidScanFailsInsteadOfReturningAPartialList() throws {
        for index in 0..<20 { try makeFile("Folder \(index)/File.txt") }

        var removed = false
        #expect(throws: ScanError.connectionLost(path: root.standardizedFileURL.path)) {
            try ShareScanner.walk(root: root, batchSize: 2) { _ in
                guard !removed else { return }
                removed = true
                try? FileManager.default.removeItem(at: root)
            }
        }
    }

    @Test func cancellingStopsTheWalk() async throws {
        for index in 0..<200 { try makeFile("File \(index).txt") }

        let root = root
        let task = Task.detached { () -> (records: Int, error: (any Error)?) in
            var count = 0
            do {
                try ShareScanner.walk(root: root, batchSize: 10) { batch in
                    count += batch.records.count
                    if count >= 20 { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return (count, nil)
            } catch {
                return (count, error)
            }
        }
        let outcome = await task.value

        #expect(outcome.error is CancellationError)
        #expect(outcome.records < 200)
    }
}
