import Foundation

/// What happened the last time a file's contents were read.
public enum ContentOutcome: String, Sendable, CaseIterable {
    case indexed
    /// Readable, but there was no text in it.
    case noText = "no_text"
    /// A PDF without a text layer, or a picture, waiting for text recognition.
    case needsOCR = "needs_ocr"
    /// A scanned PDF or a picture whose text was recognized.
    case recognized
    /// Damaged, password-protected or otherwise unreadable.
    case failed
}

/// A file whose contents should be read (it's new or changed since the last read).
public struct ContentCandidate: Sendable, Hashable {
    public let relativePath: String
    public let size: Int64
    public let modifiedAt: Date?
}

/// A document whose text matches a search.
public struct ContentResult: Sendable, Hashable {
    public let result: SearchResult
    /// The matching passage. Matched words are wrapped in ``ContentResult/highlightStart``
    /// and ``ContentResult/highlightEnd``.
    public let snippet: String

    public static let highlightStart: Character = "\u{1}"
    public static let highlightEnd: Character = "\u{2}"
}

extension IndexStore {
    /// `contents` holds document text, tokenized into words with accents removed (much smaller
    /// than the trigram name index). `content_state` remembers which version of each file was
    /// read, so later passes only read new or changed files.
    static let contentSchema = """
        CREATE VIRTUAL TABLE IF NOT EXISTS contents USING fts5(
            text,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        CREATE TABLE IF NOT EXISTS content_state (
            share TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            size INTEGER,
            modified REAL,
            outcome TEXT NOT NULL,
            content_rowid INTEGER,
            PRIMARY KEY (share, relative_path)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS content_state_rowid ON content_state(content_rowid);
        """

    /// Starts a session for reading one share's contents. Use it from a single task.
    public func beginContentUpdates(share: String) throws -> ContentUpdates {
        try ContentUpdates(connection: Connection(url: url), share: share)
    }

    /// Documents whose text contains every term of `query` (as word beginnings), best first.
    public func searchContent(_ query: Query, limit: Int = 50) throws -> [ContentResult] {
        guard !query.terms.isEmpty else { return [] }
        // Each term as a quoted prefix: "cotiz"* AND "acme"*. Quotes inside terms are doubled.
        let match = query.terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " AND ")

        var parameters: [SQLValue] = [.text(match)]
        var filters = ["contents MATCH ?1"]
        if !query.extensions.isEmpty {
            let anyExtension = query.extensions.map { ext -> String in
                parameters.append(.text(".\(ext)"))
                let suffix = "?\(parameters.count)"
                return "substr(lower(s.relative_path), -length(\(suffix))) = \(suffix)"
            }
            filters.append("(\(anyExtension.joined(separator: " OR ")))")
        }
        parameters.append(.int(Int64(limit)))

        readerLock.lock()
        defer { readerLock.unlock() }
        let statement = try reader.prepare("""
            SELECT s.share, s.relative_path, s.size, s.modified,
                   snippet(contents, 0, char(1), char(2), '…', 14)
            FROM contents
            JOIN content_state s ON s.content_rowid = contents.rowid
            WHERE \(filters.joined(separator: " AND "))
            ORDER BY rank
            LIMIT ?\(parameters.count)
            """)
        try statement.bind(parameters)
        var results: [ContentResult] = []
        while try statement.step() {
            let relativePath = statement.text(1)
            results.append(ContentResult(
                result: SearchResult(
                    share: statement.text(0),
                    relativePath: relativePath,
                    name: (relativePath as NSString).lastPathComponent,
                    isDirectory: false,
                    size: statement.int(2),
                    modifiedAt: statement.optionalDouble(3).map(Date.init(timeIntervalSince1970:))
                ),
                snippet: statement.text(4)
            ))
        }
        return results
    }

    /// How many of a share's files have had their contents read, by outcome.
    public func contentCounts(share: String) throws -> [ContentOutcome: Int] {
        readerLock.lock()
        defer { readerLock.unlock() }
        let statement = try reader.prepare("SELECT outcome, count(*) FROM content_state WHERE share = ? GROUP BY outcome")
        try statement.bind([.text(share)])
        var counts: [ContentOutcome: Int] = [:]
        while try statement.step() {
            if let outcome = ContentOutcome(rawValue: statement.text(0)) { counts[outcome] = Int(statement.int(1)) }
        }
        return counts
    }
}

/// Reads and records one share's contents. Every change is saved immediately, so work
/// survives quitting the app or losing the connection.
public final class ContentUpdates {
    public let share: String
    private let connection: Connection

    init(connection: Connection, share: String) throws {
        self.connection = connection
        self.share = share
    }

    /// Files of the given types, up to `maxSize` bytes, that are new or changed since they
    /// were last read, leaving out what `neverRead` matches. Smallest first, so many documents
    /// become searchable quickly.
    public func pendingFiles(
        extensions: Set<String>, maxSize: Int64, neverRead: ExclusionRules = .none
    ) throws -> [ContentCandidate] {
        let statement = try connection.prepare("""
            SELECT e.relative_path, e.size, e.modified
            FROM entries e
            LEFT JOIN content_state s ON s.share = e.share AND s.relative_path = e.relative_path
            WHERE e.share = ?1 AND e.is_dir = 0 AND e.size <= ?2
              AND (s.relative_path IS NULL OR s.size IS NOT e.size OR s.modified IS NOT e.modified)
            """)
        try statement.bind([.text(share), .int(maxSize)])
        var candidates: [ContentCandidate] = []
        while try statement.step() {
            let path = statement.text(0)
            guard extensions.contains((path as NSString).pathExtension.lowercased()),
                  !neverRead.excludesItemOrFolder(relativePath: path)
            else { continue }
            candidates.append(ContentCandidate(
                relativePath: path,
                size: statement.int(1),
                modifiedAt: statement.optionalDouble(2).map(Date.init(timeIntervalSince1970:))
            ))
        }
        return candidates.sorted { $0.size < $1.size }
    }

    /// Scanned PDFs and pictures waiting for text recognition, up to `maxSize` bytes and unchanged since they
    /// were found to need it (changed files are read normally first), leaving out what
    /// `neverRead` matches. Smallest first.
    public func pendingScans(maxSize: Int64, neverRead: ExclusionRules = .none) throws -> [ContentCandidate] {
        let statement = try connection.prepare("""
            SELECT s.relative_path, s.size, s.modified
            FROM content_state s
            JOIN entries e ON e.share = s.share AND e.relative_path = s.relative_path
            WHERE s.share = ?1 AND s.outcome = 'needs_ocr' AND s.size <= ?2
              AND s.size IS e.size AND s.modified IS e.modified
            """)
        try statement.bind([.text(share), .int(maxSize)])
        var candidates: [ContentCandidate] = []
        while try statement.step() {
            let path = statement.text(0)
            guard !neverRead.excludesItemOrFolder(relativePath: path) else { continue }
            candidates.append(ContentCandidate(
                relativePath: path,
                size: statement.int(1),
                modifiedAt: statement.optionalDouble(2).map(Date.init(timeIntervalSince1970:))
            ))
        }
        return candidates.sorted { $0.size < $1.size }
    }

    /// Saves what reading `file` produced. `text` is stored only for ``ContentOutcome/indexed``
    /// and ``ContentOutcome/recognized``.
    public func record(_ file: ContentCandidate, outcome: ContentOutcome, text: String? = nil) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            try deleteContent(of: file.relativePath)
            var contentRowID: SQLValue = .null
            let keepsText = outcome == .indexed || outcome == .recognized
            if keepsText, let text, !text.isEmpty {
                let insert = try connection.prepare("INSERT INTO contents (text) VALUES (?)")
                try insert.bind([.text(text)])
                _ = try insert.step()
                contentRowID = .int(connection.lastInsertedRowID)
            }
            let state = try connection.prepare("""
                INSERT OR REPLACE INTO content_state (share, relative_path, size, modified, outcome, content_rowid)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            let finalOutcome = (keepsText && contentRowID == .null) ? ContentOutcome.noText : outcome
            try state.bind([
                .text(share), .text(file.relativePath), .int(file.size),
                file.modifiedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .text(finalOutcome.rawValue), contentRowID,
            ])
            _ = try state.step()
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    /// Forgets the contents of files that are no longer in the share's name index
    /// (deleted, moved, excluded), no longer of an enabled type, or now matched by `neverRead`.
    @discardableResult
    public func removeStale(keepingExtensions extensions: Set<String>, neverRead: ExclusionRules = .none) throws -> Int {
        var current = Set<String>()
        let files = try connection.prepare("SELECT relative_path FROM entries WHERE share = ? AND is_dir = 0")
        try files.bind([.text(share)])
        while try files.step() { current.insert(files.text(0)) }

        var stale: [String] = []
        let stored = try connection.prepare("SELECT relative_path FROM content_state WHERE share = ?")
        try stored.bind([.text(share)])
        while try stored.step() {
            let path = stored.text(0)
            if !current.contains(path) || !extensions.contains((path as NSString).pathExtension.lowercased())
                || neverRead.excludesItemOrFolder(relativePath: path) {
                stale.append(path)
            }
        }
        guard !stale.isEmpty else { return 0 }

        try connection.execute("BEGIN IMMEDIATE")
        do {
            for path in stale { try deleteContent(of: path, forgettingState: true) }
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
        return stale.count
    }

    /// Makes deleted text unrecoverable from the index file: rebuilds the word index without it
    /// and empties the write-ahead log. Slower than a normal delete; use after privacy removals.
    public func scrubDeletedText() throws {
        try connection.execute("INSERT INTO contents(contents) VALUES ('optimize')")
        try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func deleteContent(of relativePath: String, forgettingState: Bool = false) throws {
        let delete = try connection.prepare("""
            DELETE FROM contents WHERE rowid = (
                SELECT content_rowid FROM content_state WHERE share = ? AND relative_path = ?
            )
            """)
        try delete.bind([.text(share), .text(relativePath)])
        _ = try delete.step()
        guard forgettingState else { return }
        let forget = try connection.prepare("DELETE FROM content_state WHERE share = ? AND relative_path = ?")
        try forget.bind([.text(share), .text(relativePath)])
        _ = try forget.step()
    }
}
