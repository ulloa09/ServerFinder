import AppKit
import Foundation

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
    public static let supportedExtensions: Set<String> = ["txt", "csv", "xml", "rtf", "docx", "doc"]

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
        default:
            return .unsupported
        }
        return .text(compact(raw))
    }

    // MARK: Formats

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
