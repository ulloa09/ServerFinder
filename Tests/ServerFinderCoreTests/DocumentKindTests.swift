import Foundation
import Testing
@testable import ServerFinderCore

@Suite struct DocumentKindTests {
    @Test func everyReadableTypeBelongsToAKind() {
        #expect(DocumentKind.extensions(of: DocumentKind.allCases) == TextExtractor.supportedExtensions)
    }

    @Test func kindsDoNotOverlap() {
        let total = DocumentKind.allCases.map(\.extensions.count).reduce(0, +)
        #expect(total == DocumentKind.extensions(of: DocumentKind.allCases).count)
    }

    @Test func turningAKindOffRemovesItsText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentKindTests-\(UUID().uuidString)", isDirectory: true)
        let store = try IndexStore(url: directory.appendingPathComponent("index.sqlite"))
        let records = ["Plan.pdf", "Plan.docx"].map {
            FileRecord(relativePath: $0, name: $0, isDirectory: false, size: 10, modifiedAt: Date(timeIntervalSince1970: 1))
        }
        let names = try store.beginReplacing(share: "A", displayName: "Share")
        try names.insert(records)
        try names.commit()
        let updates = try store.beginContentUpdates(share: "A")
        let all = DocumentKind.extensions(of: DocumentKind.allCases)
        for file in try updates.pendingFiles(extensions: all, maxSize: 100) {
            try updates.record(file, outcome: .indexed, text: "proyecto")
        }

        try updates.removeStale(keepingExtensions: DocumentKind.extensions(of: [.word]))

        #expect(try store.searchContent(Query.parse("proyecto")).map(\.result.name) == ["Plan.docx"])
    }

    @Test func erasingAllContentsKeepsNames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentKindTests-\(UUID().uuidString)", isDirectory: true)
        let store = try IndexStore(url: directory.appendingPathComponent("index.sqlite"))
        let record = FileRecord(relativePath: "Nota.txt", name: "Nota.txt", isDirectory: false, size: 10, modifiedAt: nil)
        let names = try store.beginReplacing(share: "A", displayName: "Share")
        try names.insert([record])
        try names.commit()
        let updates = try store.beginContentUpdates(share: "A")
        for file in try updates.pendingFiles(extensions: ["txt"], maxSize: 100) {
            try updates.record(file, outcome: .indexed, text: "privado")
        }

        try store.eraseAllContents()

        #expect(try store.searchContent(Query.parse("privado")).isEmpty)
        #expect(try store.contentCounts(share: "A").isEmpty)
        #expect(try store.search(Query.parse("nota")).count == 1)
        #expect(try updates.pendingFiles(extensions: ["txt"], maxSize: 100).count == 1, "it will be read again")
    }
}
