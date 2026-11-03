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

    // MARK: PowerPoint

    private func slideXML(_ paragraphs: [[String]]) -> String {
        let body = paragraphs.map { runs in
            "<a:p><a:pPr/>" + runs.map { "<a:r><a:rPr lang=\"es-MX\"/><a:t>\($0)</a:t></a:r>" }.joined() + "</a:p>"
        }.joined()
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
            xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
            <p:cSld><p:spTree><p:sp><p:txBody>\(body)</p:txBody></p:sp></p:spTree></p:cSld></p:sld>
            """
    }

    /// Builds a .pptx the way PowerPoint lays it out, zipped with the system zip tool.
    private func makePresentation(_ slides: [Int: [[String]]], as name: String, compress: Bool = true) throws -> URL {
        let work = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let slidesFolder = work.appendingPathComponent("ppt/slides", isDirectory: true)
        try FileManager.default.createDirectory(at: slidesFolder, withIntermediateDirectories: true)
        try Data("<Types/>".utf8).write(to: work.appendingPathComponent("[Content_Types].xml"))
        for (number, paragraphs) in slides {
            try Data(slideXML(paragraphs).utf8).write(to: slidesFolder.appendingPathComponent("slide\(number).xml"))
        }
        return try zip(work, as: name, compress: compress)
    }

    /// Zips a folder's contents with the system zip tool, the way Office lays out its files.
    private func zip(_ work: URL, as name: String, compress: Bool = true) throws -> URL {
        let output = folder.appendingPathComponent(name)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = work
        zip.arguments = ["-q", "-r", compress ? "-6" : "-0", output.path, "."]
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        return output
    }

    @Test(arguments: [true, false])
    func readsSlidesInOrder(compressed: Bool) throws {
        let url = try makePresentation([
            1: [["Planeación anual"], ["Unidad 1"]],
            2: [["Criterios de ", "evaluación"]],
            10: [["Conclusiones &amp; tareas"]], // escaped, as PowerPoint writes it
        ], as: "clase.pptx", compress: compressed)

        #expect(try text(url) == "Planeación anual Unidad 1 Criterios de evaluación Conclusiones & tareas")
    }

    @Test func joinsAWordSplitIntoSeveralRuns() throws {
        let url = try makePresentation([1: [["Evalua", "ción ", "diagnós", "tica"]]], as: "partida.pptx")
        #expect(try text(url) == "Evaluación diagnóstica")
    }

    @Test func damagedPresentationThrows() throws {
        let url = try write(Data("PK not really a zip".utf8), as: "rota.pptx")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }

    @Test func archiveWithoutSlidesThrows() throws {
        let url = try makePresentation([:], as: "vacia.pptx")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }

    // MARK: Excel

    /// Builds an .xlsx with the given shared strings file and sheets (numbered from 1).
    private func makeWorkbook(sharedStrings: String?, sheets: [String], as name: String) throws -> URL {
        let work = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sheetsFolder = work.appendingPathComponent("xl/worksheets", isDirectory: true)
        try FileManager.default.createDirectory(at: sheetsFolder, withIntermediateDirectories: true)
        try Data("<Types/>".utf8).write(to: work.appendingPathComponent("[Content_Types].xml"))
        if let sharedStrings {
            try Data(sharedStrings.utf8).write(to: work.appendingPathComponent("xl/sharedStrings.xml"))
        }
        for (index, sheet) in sheets.enumerated() {
            try Data(sheet.utf8).write(to: sheetsFolder.appendingPathComponent("sheet\(index + 1).xml"))
        }
        return try zip(work, as: name)
    }

    private func sheetXML(_ cells: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetData><row r="1">\(cells)</row></sheetData><tableParts count="0"/></worksheet>
        """
    }

    @Test func readsSharedAndInlineStrings() throws {
        let shared = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3">\
            <si><t>Inventario de equipo</t></si>\
            <si><r><t>Costo </t></r><r><rPr><b/></rPr><t xml:space="preserve">unitario</t></r></si>\
            <si><t>Mantenimiento &amp; reparación</t><rPh sb="0" eb="1"><t>ignorar</t></rPh></si>\
            </sst>
            """
        let first = sheetXML(#"<c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1"><v>1250.5</v></c>"#)
        let second = sheetXML(#"<c r="A1" t="inlineStr"><is><t>Proveedor nuevo</t></is></c><c r="B1"><f>SUM(A1:A3)</f><v>42</v></c>"#)
        let url = try makeWorkbook(sharedStrings: shared, sheets: [first, second], as: "inventario.xlsx")

        #expect(try text(url) == "Inventario de equipo Costo unitario Mantenimiento & reparación Proveedor nuevo")
    }

    @Test func readsAWorkbookWithOnlyInlineStrings() throws {
        let sheet = sheetXML(#"<c r="A1" t="inlineStr"><is><r><t>Budget </t></r><r><t>review</t></r></is></c>"#)
        let url = try makeWorkbook(sharedStrings: nil, sheets: [sheet], as: "budget.xlsx")
        #expect(try text(url) == "Budget review")
    }

    @Test func damagedWorkbookThrows() throws {
        let url = try write(Data("PK not really a zip".utf8), as: "rota.xlsx")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }

    @Test func passwordProtectedWorkbookThrows() throws {
        // Excel saves an encrypted workbook as a Compound File, not a ZIP archive.
        let header: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        let url = try write(Data(header + [UInt8](repeating: 0, count: 504)), as: "protegido.xlsx")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }

    @Test func archiveWithoutSheetsThrows() throws {
        let url = try makeWorkbook(sharedStrings: nil, sheets: [], as: "vacio.xlsx")
        #expect(throws: ExtractionError.self) { try TextExtractor.text(of: url) }
    }
}
