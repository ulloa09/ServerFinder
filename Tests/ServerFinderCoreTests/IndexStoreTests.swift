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

    private func index(_ records: [FileRecord], share: String = "A", folderName: String = "Share") throws {
        let replacement = try store.beginReplacing(share: share, displayName: folderName)
        try replacement.insert(records)
        try replacement.commit()
    }

    private func search(_ text: String) throws -> [SearchResult] {
        try store.search(Query.parse(text))
    }

    @Test func findsNamesContainingTheTextAnywhere() throws {
        try index([
            record("Ventas/2024_Cotizacion_Final.xlsx"),
            record("Ventas/Factura.pdf"),
        ])

        let names = try search("cotiz").map(\.name)
        #expect(names == ["2024_Cotizacion_Final.xlsx"])
    }

    @Test func ignoresUpperAndLowerCase() throws {
        try index([record("Informe Anual.docx")])

        #expect(try search("INFORME").map(\.name) == ["Informe Anual.docx"])
        #expect(try search("anual").map(\.name) == ["Informe Anual.docx"])
    }

    @Test func findsTextShorterThanThreeCharacters() throws {
        try index([record("A1.pdf"), record("B2.pdf")])

        #expect(try search("a1").map(\.name) == ["A1.pdf"])
    }

    @Test func returnsStoredDetails() throws {
        try index([record("Docs/Plan.pdf", modified: 1_700_000_000), record("Docs", isDirectory: true)])

        let plan = try #require(try search("plan").first)
        #expect(plan.share == "A")
        #expect(plan.relativePath == "Docs/Plan.pdf")
        #expect(plan.isDirectory == false)
        #expect(plan.size == 1_024)
        #expect(plan.modifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try search("docs").first?.isDirectory == true)
    }

    @Test func sortsMostRecentlyModifiedFirst() throws {
        try index([record("Old report.pdf", modified: 100), record("New report.pdf", modified: 200)])

        #expect(try search("report").map(\.name) == ["New report.pdf", "Old report.pdf"])
    }

    @Test func ignoresAccentsInNamesAndInTheQuery() throws {
        try index([record("Cotización_Final.xlsx"), record("Año escolar.docx")])

        #expect(try search("cotizacion").map(\.name) == ["Cotización_Final.xlsx"])
        #expect(try search("COTIZACIÓN").map(\.name) == ["Cotización_Final.xlsx"])
        #expect(try search("ano escolar").map(\.name) == ["Año escolar.docx"])
    }

    @Test func requiresEveryWord() throws {
        try index([
            record("ACME/2024/Plano planta.dwg"),
            record("ACME/2023/Plano planta.dwg"),
            record("Otro/2024/Plano planta.dwg"),
        ])

        #expect(try search("acme 2024 plano").map(\.relativePath) == ["ACME/2024/Plano planta.dwg"])
    }

    @Test func wordsCanMatchFolderNames() throws {
        try index([record("Clientes/ACME/Factura 001.pdf"), record("Clientes/Beta/Factura 002.pdf")])

        #expect(try search("acme factura").map(\.name) == ["Factura 001.pdf"])
    }

    @Test func wordsCanMatchTheSharedFolderName() throws {
        try index([record("Examenes/Final.pdf")], share: "A", folderName: "Projects")
        try index([record("Examenes/Final.pdf")], share: "B", folderName: "Accounting")

        #expect(try search("proj final").map(\.share) == ["A"])
    }

    @Test func ranksExactNamesThenNameMatchesThenFolderMatches() throws {
        try index([
            record("Informe/Resumen.pdf", modified: 400),            // only the folder matches
            record("Informe trimestral.xlsx", modified: 300),        // name contains the word
            record("Archivo/Informe.docx", modified: 100),           // exact name (without extension)
            record("Informe", isDirectory: true, modified: 200),     // exact name
        ])

        #expect(try search("informe").map(\.relativePath) == [
            "Informe",
            "Archivo/Informe.docx",
            "Informe trimestral.xlsx",
            "Informe/Resumen.pdf",
        ])
    }

    @Test func treatsUnderscoreAndPercentLiterally() throws {
        try index([record("final_v2.pdf"), record("final-v2.pdf"), record("100% listo.txt"), record("1000 listo.txt")])

        #expect(try search("final_v2").map(\.name) == ["final_v2.pdf"])
        #expect(try search("100%").map(\.name) == ["100% listo.txt"])
    }

    @Test func respectsTheResultLimit() throws {
        try index((0..<50).map { record("Foto \($0).jpg") })

        #expect(try store.search(Query.parse("foto"), limit: 10).count == 10)
    }

    @Test func emptyOrBlankTextReturnsNothing() throws {
        try index([record("Anything.txt")])

        #expect(try search("").isEmpty)
        #expect(try search("   ").isEmpty)
    }

    @Test func rescanReplacesPreviousContents() throws {
        try index([record("Deleted.pdf"), record("Kept.pdf")])
        try index([record("Kept.pdf"), record("Added.pdf")])

        #expect(try search("deleted").isEmpty)
        #expect(try search(".pdf").count == 2)
        #expect(try store.count(share: "A") == 2)
    }

    @Test func unfinishedRescanKeepsPreviousContents() throws {
        try index([record("Original.pdf")])

        let replacement = try store.beginReplacing(share: "A", displayName: "Share")
        try replacement.insert([record("Partial.pdf")])
        #expect(try search("original").count == 1, "searches see the old index during a rescan")
        replacement.cancel()

        #expect(try search("original").count == 1)
        #expect(try search("partial").isEmpty)
    }

    @Test func rescanResultsAppearOnlyWhenTheScanFinishes() throws {
        try index([record("Original.pdf")])

        let replacement = try store.beginReplacing(share: "A", displayName: "Share")
        try replacement.insert([record("Nuevo.pdf")])
        #expect(try search("nuevo").isEmpty)
        #expect(try search("original").count == 1)

        try replacement.commit()
        #expect(try search("nuevo").count == 1)
        #expect(try search("original").isEmpty)
    }

    @Test func sharesAreKeptSeparate() throws {
        try index([record("Shared.pdf")], share: "A")
        try index([record("Other.pdf")], share: "B")
        try index([], share: "B")

        #expect(try search("shared").map(\.share) == ["A"])
        #expect(try store.count(share: "B") == 0)

        try store.removeShare("A")
        #expect(try search("shared").isEmpty)
    }

    @Test func firstIndexBecomesSearchableWhileScanning() throws {
        let replacement = try store.beginReplacing(share: "A", displayName: "Share")
        let records = (0..<6_000).map { record("File \($0).txt") }
        let becameSearchable = try replacement.insert(records)

        #expect(becameSearchable)
        #expect(try store.count(share: "A") == 6_000)
        replacement.cancel()
    }

    @Test func survivesReopening() throws {
        try index([record("Persisted.pdf")])

        let reopened = try IndexStore(url: store.url)
        #expect(try reopened.search(Query.parse("persisted")).count == 1)
    }

    @Test func filtersByFileType() throws {
        try index([
            record("Planos/Plano A.pdf"),
            record("Planos/Plano B.PDF"),
            record("Planos/Plano C.dwg"),
            record("Planos/Plano D.docx"),
        ])

        #expect(Set(try search("plano ext:pdf").map(\.name)) == ["Plano A.pdf", "Plano B.PDF"])
        #expect(Set(try search("plano .pdf").map(\.name)) == ["Plano A.pdf", "Plano B.PDF"])
        #expect(Set(try search("plano ext:dwg ext:pdf").map(\.name)) == ["Plano A.pdf", "Plano B.PDF", "Plano C.dwg"])
    }

    @Test func fileTypeAloneListsEveryFileOfThatType() throws {
        try index([record("Uno.pdf"), record("Dos.pdf"), record("Tres.docx")])

        #expect(Set(try search(".pdf").map(\.name)) == ["Uno.pdf", "Dos.pdf"])
    }

    @Test func fileTypeMustBeTheRealExtension() throws {
        try index([record("Reporte.pdf.zip"), record("pdf notes.txt"), record("Reporte.pdf")])

        #expect(try search(".pdf").map(\.name) == ["Reporte.pdf"])
    }

    @Test func foldersAreResultsButNotOfAFileType() throws {
        try index([record("Proyectos", isDirectory: true), record("Archivo.pdf", isDirectory: true), record("Proyectos/Plan.pdf")])

        #expect(try search("proyectos").first?.isDirectory == true)
        #expect(try search(".pdf").map(\.name) == ["Plan.pdf"])
    }
}
