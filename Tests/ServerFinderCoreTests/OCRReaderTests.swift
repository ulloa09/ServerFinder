import AppKit
import Foundation
import Testing
@testable import ServerFinderCore

@Suite struct OCRReaderTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OCRReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A picture of printed lines, like a scanner produces: pixels only, no text layer.
    private func pageImage(_ lines: [String]) throws -> CGImage {
        let width = 1_700, height = 2_200 // a letter page at 200 dpi
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, line) in lines.enumerated() {
            let text = CTLineCreateWithAttributedString(NSAttributedString(
                string: line, attributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
            ))
            context.textPosition = CGPoint(x: 150, y: height - 300 - index * 100)
            CTLineDraw(text, context)
        }
        return try #require(context.makeImage())
    }

    /// A PDF whose pages are only images.
    private func makeScannedPDF(_ pages: [[String]], as name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for lines in pages {
            context.beginPDFPage(nil)
            context.draw(try pageImage(lines), in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    @Test func recognizesSpanishAndEnglishInAScan() throws {
        let url = try makeScannedPDF([
            ["Constancia de calificación", "Evaluación del primer trimestre"],
            ["Homework schedule for next week"],
        ], as: "escaneo.pdf")
        #expect(try TextExtractor.text(of: url) == .needsOCR, "the fixture must look like a scan")

        let text = try OCRReader.text(ofScannedPDF: url)
        #expect(text.contains("calificación"))
        #expect(text.contains("Evaluación del primer trimestre"))
        #expect(text.contains("Homework schedule"))
        #expect(text.firstRange(of: "calificación")!.lowerBound < text.firstRange(of: "Homework")!.lowerBound,
                "pages stay in order")
    }

    @Test func blankScanHasNoText() throws {
        let url = try makeScannedPDF([[]], as: "en blanco.pdf")
        #expect(try OCRReader.text(ofScannedPDF: url).isEmpty)
    }

    @Test func damagedPDFThrows() throws {
        let url = folder.appendingPathComponent("roto.pdf")
        try Data("%PDF-1.7 not really".utf8).write(to: url)
        #expect(throws: ExtractionError.self) { try OCRReader.text(ofScannedPDF: url) }
    }
}
