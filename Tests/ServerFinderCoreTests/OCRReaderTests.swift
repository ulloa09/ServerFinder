import AppKit
import Foundation
import Testing
@testable import ServerFinderCore

// One recognition at a time, like the app: on a Mac with few cores (such as GitHub's, with 3),
// several running at once starve each other inside Vision and never finish.
// The time limit can't interrupt a stuck recognition; the CI workflow's watchdog stops those.
@Suite(.serialized, .timeLimit(.minutes(1))) struct OCRReaderTests {
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

    // MARK: Images

    /// Saves pictures as one file (several pages only for TIFF), with optional EXIF orientation.
    private func writeImage(_ images: [CGImage], type: String, as name: String, orientation: Int? = nil) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil))
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        for image in images { CGImageDestinationAddImage(destination, image, properties) }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// The image turned a quarter turn counterclockwise, the way a phone held sideways stores it.
    private func rotatedCounterclockwise(_ image: CGImage) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.translateBy(x: CGFloat(image.height), y: 0)
        context.rotate(by: .pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try #require(context.makeImage())
    }

    @Test func picturesGoStraightToRecognition() throws {
        // Not opened by the text reader, so even a broken picture waits for recognition.
        let url = folder.appendingPathComponent("foto.JPG")
        try Data("not an image".utf8).write(to: url)
        #expect(try TextExtractor.text(of: url) == .needsOCR)
    }

    @Test func recognizesAPNG() throws {
        let url = try writeImage([pageImage(["Acta de entrega", "Inventory checklist"])], type: "public.png", as: "acta.png")
        let text = try OCRReader.text(of: url)
        #expect(text.contains("Acta de entrega"))
        #expect(text.contains("Inventory checklist"))
    }

    @Test func readsEveryPageOfATIFF() throws {
        let url = try writeImage(
            [pageImage(["Primera hoja del fax"]), pageImage(["Second page of the fax"])],
            type: "public.tiff", as: "fax.tif"
        )
        let text = try OCRReader.text(of: url)
        #expect(text.contains("Primera hoja"))
        #expect(text.contains("Second page"))
        #expect(text.firstRange(of: "Primera")!.lowerBound < text.firstRange(of: "Second")!.lowerBound, "pages stay in order")
    }

    @Test func readsSidewaysPhotos() throws {
        let sideways = try rotatedCounterclockwise(pageImage(["Recibo de pago número 42"]))
        // Orientation 6: show it turned a quarter turn clockwise.
        let url = try writeImage([sideways], type: "public.jpeg", as: "recibo.jpeg", orientation: 6)
        #expect(try OCRReader.text(of: url).contains("Recibo de pago"))
    }

    @Test func tinyPictureHasNoText() throws {
        let context = try #require(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        let url = try writeImage([try #require(context.makeImage())], type: "public.png", as: "icono.png")
        #expect(try OCRReader.text(of: url).isEmpty)
    }

    @Test func damagedPictureThrows() throws {
        let url = folder.appendingPathComponent("rota.png")
        try Data("not an image".utf8).write(to: url)
        #expect(throws: ExtractionError.self) { try OCRReader.text(of: url) }
    }
}
