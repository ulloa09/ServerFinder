import Foundation

/// The groups of file types whose contents can be searched, as shown in Settings.
public enum DocumentKind: String, CaseIterable, Codable, Sendable {
    case pdf
    case word
    case powerPoint
    case text
    case xml

    public var extensions: Set<String> {
        switch self {
        case .pdf: ["pdf"]
        case .word: ["docx", "doc"]
        case .powerPoint: ["pptx"]
        case .text: ["txt", "csv", "rtf"]
        case .xml: ["xml"]
        }
    }

    /// Every extension of the given kinds.
    public static func extensions(of kinds: some Sequence<DocumentKind>) -> Set<String> {
        kinds.reduce(into: Set<String>()) { $0.formUnion($1.extensions) }
    }
}

extension IndexStore {
    /// Deletes all stored document text and reading history, and makes it unrecoverable from
    /// the index file. Names are kept; contents are read again if content search stays on.
    public func eraseAllContents() throws {
        let connection = try Connection(url: url)
        try connection.execute("BEGIN IMMEDIATE")
        do {
            try connection.execute("DELETE FROM contents")
            try connection.execute("DELETE FROM content_state")
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
        try connection.execute("INSERT INTO contents(contents) VALUES ('optimize')")
        try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try connection.execute("VACUUM")
    }
}
