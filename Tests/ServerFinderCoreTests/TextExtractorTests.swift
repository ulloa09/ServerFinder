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

    // MARK: PDF

    /// Draws a PDF in the test: one page per entry, with that text (or just a box, like a scan).
    private func makePDF(_ pages: [String?], as name: String, password: String? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var options: [CFString: Any] = [:]
        if let password {
            options[kCGPDFContextUserPassword] = password
            options[kCGPDFContextOwnerPassword] = password
        }
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, options as CFDictionary))
        for page in pages {
            context.beginPDFPage(nil)
            if let page {
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: page, attributes: [.font: NSFont.systemFont(ofSize: 14)]
                ))
                context.textPosition = CGPoint(x: 72, y: 700)
                CTLineDraw(line, context)
            } else {
                context.setFillColor(gray: 0.5, alpha: 1)
                context.fill(CGRect(x: 72, y: 72, width: 400, height: 600)) // an "image" of a page
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    @Test func readsPDFText() throws {
        let url = try makePDF([
            "Reglamento escolar: evaluación del primer trimestre",
            "Segunda página con la calificación final",
        ], as: "reglamento.pdf")

        let result = try text(url)
        #expect(result.contains("evaluación del primer trimestre"))
        #expect(result.contains("calificación final"))
    }

    @Test func scannedPDFNeedsTextRecognition() throws {
        let url = try makePDF([nil, nil], as: "escaneo.pdf")
        #expect(try TextExtractor.text(of: url) == .needsOCR)
    }

    @Test func aPageNumberDoesNotMakeAScanSearchable() throws {
        let url = try makePDF(["1", nil, "3"], as: "escaneo con folio.PDF")
        #expect(try TextExtractor.text(of: url) == .needsOCR)
    }

    @Test func passwordProtectedPDFThrows() throws {
        let url = try makePDF(["Confidencial"], as: "protegido.pdf", password: "1234")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }

    @Test func damagedPDFThrows() throws {
        let url = try write(Data("%PDF-1.7 not really".utf8), as: "roto.pdf")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }
}
