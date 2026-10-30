import Foundation
import PDFKit
import Vision

/// Reads scanned PDFs (pages that are only images) with the text recognition built into macOS.
/// Takes about a third of a second per page on Apple silicon; meant for a background pass.
public enum OCRReader {
    /// Pages beyond this are skipped: long scans are rare, and the first pages say what a document is.
    public static let maxPages = 100

    /// Pages are drawn at this size (longest side, in pixels) before recognition: about 240 dpi
    /// for a letter page, enough for small print without slowing recognition down.
    static let renderedLongestSide: CGFloat = 2_000

    /// The recognized text of every page (up to ``maxPages``), in order. Checks for task
    /// cancellation between pages.
    public static func text(ofScannedPDF url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError(reason: "Couldn't open \(url.lastPathComponent) as a PDF")
        }
        guard !document.isLocked else {
            throw ExtractionError(reason: "\(url.lastPathComponent) is password-protected")
        }
        var pages: [String] = []
        for index in 0..<min(document.pageCount, maxPages) {
            try Task.checkCancellation()
            // Rendered pages are large; free each one before the next.
            let text = try autoreleasepool { try document.page(at: index).map(recognizeText) ?? "" }
            pages.append(text)
        }
        return TextExtractor.compact(pages.joined(separator: "\n"))
    }

    private static func recognizeText(on page: PDFPage) throws -> String {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return "" }
        let scale = renderedLongestSide / max(bounds.width, bounds.height)
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["es-ES", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
        } catch {
            throw ExtractionError(reason: "Text recognition failed: \(error.localizedDescription)")
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
