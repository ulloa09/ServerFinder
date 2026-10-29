import AppKit
import Foundation
import Testing
@testable import ServerFinderCore

@Suite struct TextExtractorTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func writeDocument(_ text: String, as name: String, type: NSAttributedString.DocumentType) throws -> URL {
        let document = NSAttributedString(string: text)
        let data = try document.data(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [.documentType: type]
        )
        return try write(data, as: name)
    }

    private func text(_ url: URL) throws -> String {
        guard case .text(let text) = try TextExtractor.text(of: url) else {
            Issue.record("expected text from \(url.lastPathComponent)")
            return ""
        }
        return text
    }

    @Test func readsUTF8Text() throws {
        let url = try write(Data("Cotización del año\nGrupo 3A".utf8), as: "notas.txt")
        #expect(try text(url) == "Cotización del año Grupo 3A")
    }

    @Test func readsWindows1252Text() throws {
        // "Calificación" encoded the way older Windows programs save it.
        let data = "Calificación final".data(using: .windowsCP1252)!
        let url = try write(data, as: "viejo.txt")
        #expect(try text(url) == "Calificación final")
    }

    @Test func readsUTF16WithByteOrderMark() throws {
        let data = "Evaluación".data(using: .utf16)! // includes the byte-order mark
        let url = try write(data, as: "unicode.txt")
        #expect(try text(url) == "Evaluación")
    }

    @Test func readsCSV() throws {
        let url = try write(Data("Nombre,Calificación\nMaría López,9.5\n".utf8), as: "lista.CSV")
        #expect(try text(url) == "Nombre,Calificación María López,9.5")
    }

    @Test func readsXMLWithoutTheMarkup() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <alumnos><alumno nombre="x">Ana &amp; Luis</alumno><nota><![CDATA[Excelente <trabajo>]]></nota></alumnos>
            """
        let url = try write(Data(xml.utf8), as: "datos.xml")
        let result = try text(url)
        #expect(result.contains("Ana & Luis"))
        #expect(result.contains("Excelente <trabajo>"))
        #expect(!result.contains("<alumno"))
    }

    @Test(arguments: [
        ("informe.rtf", NSAttributedString.DocumentType.rtf),
        ("informe.docx", .officeOpenXML),
        ("informe.doc", .docFormat),
    ])
    func readsWordAndRTF(name: String, type: NSAttributedString.DocumentType) throws {
        let url = try writeDocument("Planeación de la unidad 4: evaluación diagnóstica", as: name, type: type)
        #expect(try text(url).contains("Planeación de la unidad 4: evaluación diagnóstica"))
    }

    @Test func damagedDocumentThrows() throws {
        let url = try write(Data("this is not a zip archive".utf8), as: "roto.docx")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }

    @Test func otherTypesAreUnsupported() throws {
        let url = try write(Data([0xFF, 0xD8, 0xFF]), as: "foto.jpg")
        #expect(try TextExtractor.text(of: url) == .unsupported)
    }

    @Test func capsVeryLongText() throws {
        let long = String(repeating: "palabra ", count: 100_000) // 800k characters
        let url = try write(Data(long.utf8), as: "largo.txt")
        #expect(try text(url).count <= TextExtractor.maxCharacters)
    }
}
