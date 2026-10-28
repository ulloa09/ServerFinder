import Foundation
import Testing
@testable import ServerFinderCore

@Suite struct IndexStoreTests {
    let directory: URL
    let store: IndexStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = try IndexStore(url: directory.appendingPathComponent("index.sqlite"))
    }

    private func record(_ path: String, isDirectory: Bool = false, modified: TimeInterval = 0) -> FileRecord {
        FileRecord(
            relativePath: path,
            name: (path as NSString).lastPathComponent,
            isDirectory: isDirectory,
            size: isDirectory ? 0 : 1_024,
            modifiedAt: Date(timeIntervalSince1970: modified)
        )
    }

    private func index(_ records: [FileRecord], share: String = "A") throws {
        let replacement = try store.beginReplacing(share: share)
        try replacement.insert(records)
        try replacement.commit()
    }

    @Test func findsNamesContainingTheTextAnywhere() throws {
        try index([
            record("Ventas/2024_Cotizacion_Final.xlsx"),
            record("Ventas/Factura.pdf"),
        ])

        let names = try store.search("cotiz").map(\.name)
        #expect(names == ["2024_Cotizacion_Final.xlsx"])
    }

    @Test func ignoresUpperAndLowerCase() throws {
        try index([record("Informe Anual.docx")])

        #expect(try store.search("INFORME").map(\.name) == ["Informe Anual.docx"])
        #expect(try store.search("anual").map(\.name) == ["Informe Anual.docx"])
    }

    @Test func findsTextShorterThanThreeCharacters() throws {
        try index([record("A1.pdf"), record("B2.pdf")])

        #expect(try store.search("a1").map(\.name) == ["A1.pdf"])
    }

    @Test func returnsStoredDetails() throws {
        try index([record("Docs/Plan.pdf", modified: 1_700_000_000), record("Docs", isDirectory: true)])

        let plan = try #require(try store.search("plan").first)
        #expect(plan.share == "A")
        #expect(plan.relativePath == "Docs/Plan.pdf")
        #expect(plan.isDirectory == false)
        #expect(plan.size == 1_024)
        #expect(plan.modifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try store.search("docs").first?.isDirectory == true)
    }

    @Test func sortsMostRecentlyModifiedFirst() throws {
        try index([record("Old report.pdf", modified: 100), record("New report.pdf", modified: 200)])

        #expect(try store.search("report").map(\.name) == ["New report.pdf", "Old report.pdf"])
    }

    @Test func emptyOrBlankTextReturnsNothing() throws {
        try index([record("Anything.txt")])

        #expect(try store.search("").isEmpty)
        #expect(try store.search("   ").isEmpty)
    }

    @Test func rescanReplacesPreviousContents() throws {
        try index([record("Deleted.pdf"), record("Kept.pdf")])
        try index([record("Kept.pdf"), record("Added.pdf")])

        #expect(try store.search("deleted").isEmpty)
        #expect(try store.search(".pdf").count == 2)
        #expect(try store.count(share: "A") == 2)
    }

    @Test func unfinishedRescanKeepsPreviousContents() throws {
        try index([record("Original.pdf")])

        let replacement = try store.beginReplacing(share: "A")
        try replacement.insert([record("Partial.pdf")])
        #expect(try store.search("original").count == 1, "searches see the old index during a rescan")
        replacement.cancel()

        #expect(try store.search("original").count == 1)
        #expect(try store.search("partial").isEmpty)
    }

    @Test func sharesAreKeptSeparate() throws {
        try index([record("Shared.pdf")], share: "A")
        try index([record("Other.pdf")], share: "B")
        try index([], share: "B")

        #expect(try store.search("shared").map(\.share) == ["A"])
        #expect(try store.count(share: "B") == 0)

        try store.removeShare("A")
        #expect(try store.search("shared").isEmpty)
    }

    @Test func firstIndexBecomesSearchableWhileScanning() throws {
        let replacement = try store.beginReplacing(share: "A")
        let records = (0..<6_000).map { record("File \($0).txt") }
        let becameSearchable = try replacement.insert(records)

        #expect(becameSearchable)
        #expect(try store.count(share: "A") == 6_000)
        replacement.cancel()
    }

    @Test func survivesReopening() throws {
        try index([record("Persisted.pdf")])

        let reopened = try IndexStore(url: store.url)
        #expect(try reopened.search("persisted").count == 1)
    }
}
