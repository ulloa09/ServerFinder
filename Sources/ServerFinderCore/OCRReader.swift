import Foundation
import ImageIO
import PDFKit
import Vision

/// Reads scanned PDFs (pages that are only images) and pictures with the text recognition built
/// into macOS. Takes about a third of a second per page on Apple silicon; meant for a background pass.
public enum OCRReader {
    /// Pages beyond this are skipped: long scans are rare, and the first pages say what a document is.
    public static let maxPages = 100

    /// Pages are drawn at this size (longest side, in pixels) before recognition: about 240 dpi
    /// for a letter page, enough for small print without slowing recognition down.
    static let renderedLongestSide: CGFloat = 2_000

    /// Pictures smaller than this (in pixels, either side) are icons or bullets, not documents.
    static let minimumSide = 32

    /// The recognized text of a scanned PDF or a picture, depending on the file type.
    public static func text(of url: URL) throws -> String {
        if TextExtractor.imageExtensions.contains(url.pathExtension.lowercased()) {
            return try text(ofImage: url)
        }
        return try text(ofScannedPDF: url)
    }

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

    /// The recognized text of a photo or scanned picture. Every page of a multi-page TIFF (a common
    /// scanner and fax format) is read, up to ``maxPages``, in order.
    public static func text(ofImage url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ExtractionError(reason: "Couldn't open \(url.lastPathComponent) as an image")
        }
        // Decoded straight to the recognition size (never larger), turned upright as the camera recorded.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: renderedLongestSide,
        ]
        var pages: [String] = []
        for index in 0..<min(CGImageSourceGetCount(source), maxPages) {
            try Task.checkCancellation()
            let text = try autoreleasepool {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                    throw ExtractionError(reason: "Couldn't decode \(url.lastPathComponent)")
                }
                return try recognizeText(in: image)
            }
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
        return try recognizeText(in: cgImage)
    }

    private static func recognizeText(in cgImage: CGImage) throws -> String {
        guard cgImage.width >= minimumSide, cgImage.height >= minimumSide else { return "" }
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
