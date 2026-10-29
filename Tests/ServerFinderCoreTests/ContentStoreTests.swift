import Foundation
import Testing
@testable import ServerFinderCore

@Suite struct ContentStoreTests {
    let store: IndexStore
    let types: Set<String> = ["txt", "docx", "pdf"]

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = try IndexStore(url: directory.appendingPathComponent("index.sqlite"))
    }

    private func file(_ path: String, size: Int64 = 100, modified: TimeInterval = 1_000) -> FileRecord {
        FileRecord(
            relativePath: path, name: (path as NSString).lastPathComponent, isDirectory: false,
            size: size, modifiedAt: Date(timeIntervalSince1970: modified)
        )
    }

    /// Indexes names, then "reads" each file with the given text.
    private func index(_ documents: [(FileRecord, String)], share: String = "A") throws {
        let names = try store.beginReplacing(share: share, displayName: "Share")
        try names.insert(documents.map(\.0))
        try names.commit()
        let updates = try store.beginContentUpdates(share: share)
        let pending = try updates.pendingFiles(extensions: types, maxSize: 20_000_000)
        for (record, text) in documents {
            guard let candidate = pending.first(where: { $0.relativePath == record.relativePath }) else { continue }
            try updates.record(candidate, outcome: .indexed, text: text)
        }
    }

    private func search(_ text: String) throws -> [String] {
        try store.searchContent(Query.parse(text)).map(\.result.relativePath)
    }

    @Test func findsDocumentsByAWordInside() throws {
        try index([
            (file("Examenes/Final.docx"), "Examen final de María López, grupo 3A"),
            (file("Notas.txt"), "Lista de materiales para el taller"),
        ])

        #expect(try search("maria") == ["Examenes/Final.docx"])
        #expect(try search("taller") == ["Notas.txt"])
    }

    @Test func matchesWordBeginningsIgnoringCaseAndAccents() throws {
        try index([(file("Ventas.txt"), "Cotización para ACME")])

        #expect(try search("cotiz") == ["Ventas.txt"])
        #expect(try search("COTIZACION") == ["Ventas.txt"])
        #expect(try search("acm") == ["Ventas.txt"])
        #expect(try search("izacion").isEmpty, "only word beginnings match inside documents")
    }

    @Test func requiresEveryWord() throws {
        try index([
            (file("A.txt"), "Planeación de la unidad 4"),
            (file("B.txt"), "Planeación anual"),
        ])

        #expect(try search("planeacion unidad") == ["A.txt"])
    }

    @Test func appliesTheFileTypeFilter() throws {
        try index([(file("Plan.docx"), "proyecto escolar"), (file("Plan.txt"), "proyecto escolar")])

        #expect(try search("proyecto .docx") == ["Plan.docx"])
        #expect(Set(try search("proyecto")) == ["Plan.docx", "Plan.txt"])
    }

    @Test func snippetHighlightsTheWords() throws {
        try index([(file("Carta.txt"), "Estimados padres de familia, les informamos que la evaluación será el lunes.")])

        let snippet = try #require(try store.searchContent(Query.parse("evaluacion")).first?.snippet)
        #expect(snippet.contains("\u{1}evaluación\u{2}"))
    }

    @Test func returnsFileDetails() throws {
        try index([(file("Docs/Guía.docx", size: 4_096, modified: 1_700_000_000), "contenido")])

        let result = try #require(try store.searchContent(Query.parse("contenido")).first?.result)
        #expect(result.name == "Guía.docx")
        #expect(result.size == 4_096)
        #expect(result.modifiedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func onlyNewOrChangedFilesArePending() throws {
        try index([(file("Igual.txt"), "uno"), (file("Cambia.txt", modified: 1_000), "dos")])

        let names = try store.beginReplacing(share: "A", displayName: "Share")
        try names.insert([file("Igual.txt"), file("Cambia.txt", modified: 2_000), file("Nuevo.txt")])
        try names.commit()

        let pending = try store.beginContentUpdates(share: "A").pendingFiles(extensions: types, maxSize: 20_000_000)
        #expect(Set(pending.map(\.relativePath)) == ["Cambia.txt", "Nuevo.txt"])
    }

    @Test func onlyEnabledTypesUnderTheSizeLimitArePending() throws {
        let names = try store.beginReplacing(share: "A", displayName: "Share")
        try names.insert([file("Chico.txt", size: 10), file("Enorme.txt", size: 30_000_000), file("Foto.jpg")])
        try names.commit()

        let pending = try store.beginContentUpdates(share: "A").pendingFiles(extensions: types, maxSize: 20_000_000)
        #expect(pending.map(\.relativePath) == ["Chico.txt"])
    }

    @Test func rereadingReplacesTheOldText() throws {
        try index([(file("Doc.txt", modified: 1), "versión vieja")])
        try index([(file("Doc.txt", modified: 2), "versión nueva")])

        #expect(try search("vieja").isEmpty)
        #expect(try search("nueva") == ["Doc.txt"])
    }

    @Test func deletedFilesDisappearFromContentResults() throws {
        try index([(file("Borrado.txt"), "secreto"), (file("Queda.txt"), "secreto")])

        let names = try store.beginReplacing(share: "A", displayName: "Share")
        try names.insert([file("Queda.txt")])
        try names.commit()
        let removed = try store.beginContentUpdates(share: "A").removeStale(keepingExtensions: types)

        #expect(removed == 1)
        #expect(try search("secreto") == ["Queda.txt"])
    }

    @Test func recordsOutcomesWithoutText() throws {
        let names = try store.beginReplacing(share: "A", displayName: "Share")
        try names.insert([file("Vacio.txt"), file("Roto.docx")])
        try names.commit()
        let updates = try store.beginContentUpdates(share: "A")
        let pending = try updates.pendingFiles(extensions: types, maxSize: 20_000_000)
        for candidate in pending {
            try updates.record(candidate, outcome: candidate.relativePath == "Roto.docx" ? .failed : .indexed, text: "")
        }

        #expect(try store.contentCounts(share: "A") == [.noText: 1, .failed: 1])
        #expect(try updates.pendingFiles(extensions: types, maxSize: 20_000_000).isEmpty, "unreadable files aren't retried until they change")
    }

    @Test func removingAShareRemovesItsContents() throws {
        try index([(file("Doc.txt"), "privado")], share: "A")
        try store.removeShare("A")

        #expect(try search("privado").isEmpty)
        #expect(try store.contentCounts(share: "A").isEmpty)
    }

    @Test func contentSurvivesRebuildingTheNameIndex() throws {
        try index([(file("Doc.txt"), "persistente")])

        let reopened = try IndexStore(url: store.url)
        #expect(try reopened.searchContent(Query.parse("persistente")).count == 1)
    }

    @Test func neverReadFilesAreSkippedAndTheirTextRemoved() throws {
        try index([(file("Contabilidad/Contraseña.txt"), "secreto123"), (file("Contabilidad/Notas.txt"), "notas")])
        #expect(try search("secreto123").count == 1)

        let updates = try store.beginContentUpdates(share: "A")
        let removed = try updates.removeStale(keepingExtensions: types, neverRead: .sensitiveDefaults)

        #expect(removed == 1)
        #expect(try search("secreto123").isEmpty)
        #expect(try search("notas") == ["Contabilidad/Notas.txt"])
        let pending = try updates.pendingFiles(extensions: types, maxSize: 20_000_000, neverRead: .sensitiveDefaults)
        #expect(pending.isEmpty, "the password file is never read again")
        #expect(try store.search(Query.parse("contraseña")).count == 1, "it's still found by name")
    }

    @Test(arguments: ["Contraseña.txt", "contrasena (1).txt", "MIS PASSWORDS.docx", "claves banco.txt", "passwd.txt"])
    func sensitiveDefaultsCoverPasswordFiles(name: String) {
        #expect(ExclusionRules.sensitiveDefaults.excludes(name: name, relativePath: "Docs/\(name)"))
    }

    @Test func filesInsideAPrivateFolderAreNeverReadEither() throws {
        // Names from the server can use a decomposed "ñ" (n + combining tilde).
        let privateFile = "Contabilidad/Contrasen\u{303}as viejas/datos.txt"
        try index([(file(privateFile), "secreto456"), (file("Contabilidad/Notas.txt"), "notas")])

        let updates = try store.beginContentUpdates(share: "A")
        try updates.removeStale(keepingExtensions: types, neverRead: .sensitiveDefaults)

        #expect(try search("secreto456").isEmpty)
        #expect(try search("notas") == ["Contabilidad/Notas.txt"])
        #expect(try updates.pendingFiles(extensions: types, maxSize: 20_000_000, neverRead: .sensitiveDefaults).isEmpty)
    }

    @Test func aNewlySupportedTypeOnlyQueuesThoseFiles() throws {
        // Before PDF support: text files were read; PDFs were never looked at.
        let names = try store.beginReplacing(share: "A", displayName: "Share")
        try names.insert([file("Notas.txt"), file("Reglamento.pdf")])
        try names.commit()
        let updates = try store.beginContentUpdates(share: "A")
        for candidate in try updates.pendingFiles(extensions: ["txt"], maxSize: 20_000_000) {
            try updates.record(candidate, outcome: .indexed, text: "notas")
        }

        // After: only the PDF is new work.
        let pending = try updates.pendingFiles(extensions: ["txt", "pdf"], maxSize: 20_000_000)
        #expect(pending.map(\.relativePath) == ["Reglamento.pdf"])
    }
}
