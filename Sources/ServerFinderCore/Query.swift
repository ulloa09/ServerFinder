import Foundation

/// What the user is looking for, in the normalized form the index stores.
public struct Query: Sendable, Equatable {
    /// The whole typed text, normalized (used to spot exact filename matches).
    public var text: String
    /// Words that must all appear in the item's path, normalized.
    public var terms: [String]
    /// File types to limit results to (lowercase, without the dot). Empty means any type.
    public var extensions: [String]

    public init(text: String, terms: [String], extensions: [String] = []) {
        self.text = text
        self.terms = terms
        self.extensions = extensions
    }

    public var isEmpty: Bool { terms.isEmpty && extensions.isEmpty }

    /// Turns typed text into a query: splits it into words and ignores case and accents.
    ///
    /// `ext:pdf`, `ext:pdf,docx` and a lone `.pdf` limit results to those file types.
    public static func parse(_ input: String) -> Query {
        var words: [String] = []
        var extensions: [String] = []
        for token in SearchText.normalize(input).split(whereSeparator: \.isWhitespace).map(String.init) {
            if let typed = fileTypes(in: token) {
                extensions.appendUnique(contentsOf: typed)
            } else {
                words.append(token)
            }
        }
        var terms: [String] = []
        terms.appendUnique(contentsOf: words)
        return Query(text: words.joined(separator: " "), terms: terms, extensions: extensions)
    }

    /// The file types a token asks for, or `nil` when the token is an ordinary word.
    private static func fileTypes(in token: String) -> [String]? {
        let list: Substring
        if token.hasPrefix("ext:") {
            list = token.dropFirst(4)
        } else if token.hasPrefix("."), isFileType(token.dropFirst()) {
            list = token.dropFirst()
        } else {
            return nil
        }
        return list.split(separator: ",")
            .map { $0.hasPrefix(".") ? $0.dropFirst() : $0 }
            .filter(isFileType)
            .map(String.init)
    }

    private static func isFileType(_ candidate: Substring) -> Bool {
        (1...10).contains(candidate.count) && candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

private extension Array where Element: Equatable {
    mutating func appendUnique(contentsOf elements: [Element]) {
        for element in elements where !contains(element) { append(element) }
    }
}

/// The one place that decides how names are compared, so the index and queries always agree.
public enum SearchText {
    /// Lowercases and removes accents: "Cotización" → "cotizacion".
    public static func normalize(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
