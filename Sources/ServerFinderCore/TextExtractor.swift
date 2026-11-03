import AppKit
import Foundation
import PDFKit

/// The outcome of reading a document's text.
public enum Extraction: Equatable, Sendable {
    case text(String)
    /// A document with no text layer (e.g. a scanned PDF); only text recognition can read it.
    case needsOCR
    /// Not a type ServerFinder can read.
    case unsupported
}

public struct ExtractionError: Error, Equatable {
    public let reason: String
}

/// Reads the text inside documents. Only reads; never changes the file.
public enum TextExtractor {
    /// Longer documents are cut here, to keep the index a reasonable size.
    public static let maxCharacters = 500_000

    /// File types (lowercase extensions) this version can read.
    public static let supportedExtensions: Set<String> = ["txt", "csv", "xml", "rtf", "docx", "doc", "pdf", "pptx", "xlsx"]

    /// A PDF with fewer readable characters than this per page, on average, is treated as
    /// scanned (a page number or a stamp doesn't make a scan searchable).
    static let minimumCharactersPerPage = 20

    public static func text(of url: URL) throws -> Extraction {
        let raw: String
        switch url.pathExtension.lowercased() {
        case "txt", "csv":
            raw = try decodePlainText(Data(contentsOf: url))
        case "xml":
            raw = stripMarkup(try decodePlainText(Data(contentsOf: url)))
        case "rtf":
            raw = try attributedText(of: url, type: .rtf)
        case "docx":
            raw = try attributedText(of: url, type: .officeOpenXML)
        case "doc":
            raw = try attributedText(of: url, type: .docFormat)
        case "pdf":
            return try pdfText(of: url)
        case "pptx":
            raw = try presentationText(of: url)
        case "xlsx":
            raw = try workbookText(of: url)
        default:
            return .unsupported
        }
        return .text(compact(raw))
    }

    // MARK: Formats

    /// The text of every slide, in order. A .pptx is a ZIP archive with one XML file per slide
    /// (`ppt/slides/slide1.xml`, …) where visible text sits in `<a:t>` runs inside `<a:p>` paragraphs.
    private static func presentationText(of url: URL) throws -> String {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: Data(contentsOf: url))
        } catch {
            throw ExtractionError(reason: "Couldn't open \(url.lastPathComponent) as a presentation")
        }
        let slides = archive.entries
            .compactMap { entry -> (number: Int, entry: ZipArchive.Entry)? in
                guard entry.name.hasPrefix("ppt/slides/slide"), entry.name.hasSuffix(".xml"),
                      let number = Int(entry.name.dropFirst("ppt/slides/slide".count).dropLast(".xml".count))
                else { return nil }
                return (number, entry)
            }
            .sorted { $0.number < $1.number }
        guard !slides.isEmpty else {
            throw ExtractionError(reason: "\(url.lastPathComponent) has no slides")
        }
        return try slides
            .map { try slideText(String(decoding: archive.contents(of: $0.entry), as: UTF8.self)) }
            .joined(separator: " ")
    }

    private static let paragraphPattern = try! NSRegularExpression(pattern: "<a:p[ >].*?</a:p>", options: .dotMatchesLineSeparators)
    private static let runPattern = try! NSRegularExpression(pattern: "<a:t(?: [^>]*)?>(.*?)</a:t>", options: .dotMatchesLineSeparators)

    /// Pieces of one paragraph are joined as-is (PowerPoint may split a word into several runs);
    /// paragraphs are separated by spaces.
    static func slideText(_ xml: String) -> String {
        let whole = NSRange(xml.startIndex..., in: xml)
        return paragraphPattern.matches(in: xml, range: whole).map { paragraph in
            runPattern.matches(in: xml, range: paragraph.range).compactMap { run in
                Range(run.range(at: 1), in: xml).map { stripMarkup(String(xml[$0])) }
            }.joined()
        }.joined(separator: " ")
    }

    /// The text typed into cells. An .xlsx is a ZIP archive where most cell text is stored once
    /// in `xl/sharedStrings.xml` (`<si>` items) and the rest inline in the sheets
    /// (`xl/worksheets/sheet1.xml`, …, `<is>` items). Numbers and formulas aren't read.
    private static func workbookText(of url: URL) throws -> String {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: Data(contentsOf: url))
        } catch {
            // Password-protected workbooks aren't ZIP archives either.
            throw ExtractionError(reason: "Couldn't open \(url.lastPathComponent) as a workbook")
        }
        let shared = archive.entries.first { $0.name == "xl/sharedStrings.xml" }
        let sheets = archive.entries
            .compactMap { entry -> (number: Int, entry: ZipArchive.Entry)? in
                guard entry.name.hasPrefix("xl/worksheets/sheet"), entry.name.hasSuffix(".xml"),
                      let number = Int(entry.name.dropFirst("xl/worksheets/sheet".count).dropLast(".xml".count))
                else { return nil }
                return (number, entry)
            }
            .sorted { $0.number < $1.number }
        guard shared != nil || !sheets.isEmpty else {
            throw ExtractionError(reason: "\(url.lastPathComponent) has no sheets")
        }
        var parts: [String] = []
        if let shared {
            parts.append(cellText(String(decoding: try archive.contents(of: shared), as: UTF8.self), item: sharedItemPattern))
        }
        for sheet in sheets {
            parts.append(cellText(String(decoding: try archive.contents(of: sheet.entry), as: UTF8.self), item: inlineItemPattern))
        }
        return parts.joined(separator: " ")
    }

    private static let sharedItemPattern = try! NSRegularExpression(pattern: "<si(?: [^>]*)?>(.*?)</si>", options: .dotMatchesLineSeparators)
    private static let inlineItemPattern = try! NSRegularExpression(pattern: "<is(?: [^>]*)?>(.*?)</is>", options: .dotMatchesLineSeparators)
    private static let textPattern = try! NSRegularExpression(pattern: "<t(?: [^>]*)?>(.*?)</t>", options: .dotMatchesLineSeparators)
    private static let phoneticPattern = try! NSRegularExpression(pattern: "<rPh[ >].*?</rPh>", options: .dotMatchesLineSeparators)

    /// One string per cell, separated by spaces. The `<t>` pieces of a cell with mixed formatting
    /// are joined as-is; phonetic guides (`<rPh>`, used for Japanese) are skipped.
    static func cellText(_ xml: String, item: NSRegularExpression) -> String {
        item.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: xml) else { return nil }
            var cell = String(xml[range])
            if cell.contains("<rPh") {
                cell = phoneticPattern.stringByReplacingMatches(in: cell, range: NSRange(cell.startIndex..., in: cell), withTemplate: "")
            }
            return textPattern.matches(in: cell, range: NSRange(cell.startIndex..., in: cell)).compactMap { run in
                Range(run.range(at: 1), in: cell).map { stripMarkup(String(cell[$0])) }
            }.joined()
        }.joined(separator: " ")
    }

    private static func pdfText(of url: URL) throws -> Extraction {
        guard let document = PDFDocument(url: url) else {
            throw ExtractionError(reason: "Couldn't open \(url.lastPathComponent) as a PDF")
        }
        guard !document.isLocked else {
            throw ExtractionError(reason: "\(url.lastPathComponent) is password-protected")
        }
        let text = compact(document.string ?? "")
        let visibleCharacters = text.unicodeScalars.lazy.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        if visibleCharacters < max(document.pageCount, 1) * minimumCharactersPerPage {
            return .needsOCR
        }
        return .text(text)
    }

    private static func attributedText(of url: URL, type: NSAttributedString.DocumentType) throws -> String {
        do {
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
        } catch {
            throw ExtractionError(reason: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Text files from a Windows server are usually UTF-8, UTF-16 with a byte-order mark,
    /// or the older Windows-1252 encoding (which can decode any bytes).
    static func decodePlainText(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) {
            return text
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Turns XML into its readable text: tags removed, common entities decoded.
    static func stripMarkup(_ xml: String) -> String {
        // CDATA is literal text that may contain "<" and ">": escape it so it survives tag removal.
        var text = ""
        var rest = Substring(xml)
        while let start = rest.range(of: "<![CDATA["), let end = rest[start.upperBound...].range(of: "]]>") {
            text += rest[..<start.lowerBound]
            text += rest[start.upperBound..<end.lowerBound]
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            rest = rest[end.upperBound...]
        }
        text += rest
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }

    /// Collapses runs of whitespace (keeps the index small and previews tidy) and caps the length.
    static func compact(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(min(text.utf8.count, maxCharacters))
        var lastWasSpace = true
        var count = 0 // String.count is O(n), so keep our own
        for character in text {
            if character.isWhitespace || character == "\u{0}" {
                guard !lastWasSpace else { continue }
                result.append(" ")
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
            count += 1
            if count >= maxCharacters { break }
        }
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}
