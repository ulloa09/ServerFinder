import Foundation

public struct SearchResult: Sendable, Hashable {
    /// Identifier of the share root the item belongs to.
    public let share: String
    public let relativePath: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date?
}

/// The local index of file names, stored in one SQLite file.
///
/// Searching is safe from any thread. Writing happens through a ``ShareReplacement``,
/// which swaps a share's contents in a single transaction, so searches keep seeing the
/// previous index until a scan finishes.
public final class IndexStore: @unchecked Sendable {
    public let url: URL
    let reader: Connection
    let readerLock = NSLock()

    private static let schemaVersion = 2

    /// `search_path` holds "<folder name>/<relative path>" lowercased and without accents, so any
    /// word of the path can be found. `name_norm` is the normalized name, used for ranking.
    private static let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE VIRTUAL TABLE IF NOT EXISTS entries USING fts5(
            search_path,
            name_norm UNINDEXED,
            name UNINDEXED,
            share UNINDEXED,
            relative_path UNINDEXED,
            is_dir UNINDEXED,
            size UNINDEXED,
            modified UNINDEXED,
            tokenize = 'trigram'
        );
        PRAGMA user_version = \(schemaVersion);
        """

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let setup = try Connection(url: url)
        // The index is only a cache of the server's file names: when its layout changes,
        // start over and let the next scan fill it again.
        if try setup.userVersion != Self.schemaVersion {
            try setup.execute("DROP TABLE IF EXISTS entries")
        }
        try setup.execute(Self.schema)
        // Document text lives in its own tables, kept even when the name index is rebuilt.
        try setup.execute(Self.contentSchema)
        self.url = url
        self.reader = try Connection(url: url)
    }

    /// Starts replacing everything stored for `share`. Nothing changes for searches
    /// until ``ShareReplacement/commit()`` — except on a share's very first index,
    /// where results are made searchable as they arrive.
    ///
    /// `displayName` is the share's folder name; its words also find the items inside it.
    public func beginReplacing(share: String, displayName: String) throws -> ShareReplacement {
        try ShareReplacement(connection: Connection(url: url), share: share, displayName: displayName)
    }

    /// Returns items whose path contains every term of `query` and, when the query names
    /// file types, only files of those types.
    ///
    /// Best matches first: the exact file name, then names containing every term, then items
    /// matched through their folders. Within each group, most recently modified first.
    public func search(_ query: Query, limit: Int = 200) throws -> [SearchResult] {
        guard !query.isEmpty else { return [] }

        var parameters: [SQLValue] = []
        func parameter(_ value: SQLValue) -> String {
            parameters.append(value)
            return "?\(parameters.count)"
        }

        // LIKE lets SQLite use the trigram index; instr() then checks each term exactly,
        // since "_" and "%" are wildcards for LIKE.
        var filters = query.terms.map { term in
            "search_path LIKE \(parameter(.text("%\(term)%"))) AND instr(search_path, \(parameter(.text(term)))) > 0"
        }
        if !query.extensions.isEmpty {
            // Compares the end of the name. (LIKE on an UNINDEXED column of an FTS5 table
            // wrongly matches nothing, so it can't be used here.)
            let anyExtension = query.extensions
                .map { ext in
                    let suffix = parameter(.text(".\(ext)"))
                    return "substr(name_norm, -length(\(suffix))) = \(suffix)"
                }
                .joined(separator: " OR ")
            filters.append("is_dir = 0 AND (\(anyExtension))")
        }

        let text = parameter(.text(query.text))
        let exactName = query.text.isEmpty
            ? "0"
            : "name_norm = \(text) OR substr(name_norm, 1, length(\(text)) + 1) = \(text) || '.'"
        let nameHasAllTerms = query.terms.isEmpty
            ? "1"
            : query.terms.map { "instr(name_norm, \(parameter(.text($0)))) > 0" }.joined(separator: " AND ")

        readerLock.lock()
        defer { readerLock.unlock() }
        let statement = try reader.prepare("""
            SELECT share, relative_path, name, is_dir, size, modified,
                CASE
                    WHEN \(exactName) THEN 0
                    WHEN \(nameHasAllTerms) THEN 1
                    ELSE 2
                END AS rank
            FROM entries
            WHERE \(filters.joined(separator: " AND "))
            ORDER BY rank, modified DESC, name_norm
            LIMIT \(parameter(.int(Int64(limit))))
            """)
        try statement.bind(parameters)
        var results: [SearchResult] = []
        while try statement.step() {
            results.append(SearchResult(
                share: statement.text(0),
                relativePath: statement.text(1),
                name: statement.text(2),
                isDirectory: statement.int(3) != 0,
                size: statement.int(4),
                modifiedAt: statement.optionalDouble(5).map(Date.init(timeIntervalSince1970:))
            ))
        }
        return results
    }

    public func count(share: String) throws -> Int {
        readerLock.lock()
        defer { readerLock.unlock() }
        let statement = try reader.prepare("SELECT count(*) FROM entries WHERE share = ?")
        try statement.bind([.text(share)])
        return try statement.step() ? Int(statement.int(0)) : 0
    }

    /// Deletes everything stored for `share`.
    public func removeShare(_ share: String) throws {
        let connection = try Connection(url: url)
        try connection.execute("BEGIN IMMEDIATE")
        for sql in [
            "DELETE FROM entries WHERE share = ?",
            "DELETE FROM contents WHERE rowid IN (SELECT content_rowid FROM content_state WHERE share = ?)",
            "DELETE FROM content_state WHERE share = ?",
        ] {
            let statement = try connection.prepare(sql)
            try statement.bind([.text(share)])
            _ = try statement.step()
        }
        try connection.execute("COMMIT")
    }
}

/// Replaces the stored contents of one share. Use it from a single task.
///
/// If it's discarded without ``commit()``, the share's previous contents are kept.
public final class ShareReplacement {
    public let share: String
    public private(set) var insertedCount = 0
    private let pathPrefix: String

    private let connection: Connection
    private let insertStatement: Statement
    /// On a share's first index there is nothing to protect, so rows are committed as they
    /// arrive and the user can search while a long first scan is still running.
    private let commitsProgressively: Bool
    private var uncommittedCount = 0
    private var isFinished = false
    private static let progressiveCommitSize = 5_000

    init(connection: Connection, share: String, displayName: String) throws {
        self.connection = connection
        self.share = share
        self.pathPrefix = SearchText.normalize(displayName) + "/"

        let existing = try connection.prepare("SELECT 1 FROM entries WHERE share = ? LIMIT 1")
        try existing.bind([.text(share)])
        commitsProgressively = try !existing.step()

        try connection.execute("BEGIN IMMEDIATE")
        let delete = try connection.prepare("DELETE FROM entries WHERE share = ?")
        try delete.bind([.text(share)])
        _ = try delete.step()
        insertStatement = try connection.prepare("""
            INSERT INTO entries (search_path, name_norm, name, share, relative_path, is_dir, size, modified)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """)
    }

    deinit {
        cancel()
    }

    /// Adds records. Returns `true` when newly added records just became searchable.
    @discardableResult
    public func insert(_ records: [FileRecord]) throws -> Bool {
        for record in records {
            try insertStatement.bind([
                .text(pathPrefix + SearchText.normalize(record.relativePath)),
                .text(SearchText.normalize(record.name)),
                .text(record.name),
                .text(share),
                .text(record.relativePath),
                .int(record.isDirectory ? 1 : 0),
                .int(record.size),
                record.modifiedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
            ])
            _ = try insertStatement.step()
        }
        insertedCount += records.count
        uncommittedCount += records.count

        guard commitsProgressively, uncommittedCount >= Self.progressiveCommitSize else { return false }
        try connection.execute("COMMIT; BEGIN IMMEDIATE")
        uncommittedCount = 0
        return true
    }

    public func commit() throws {
        guard !isFinished else { return }
        try connection.execute("COMMIT")
        isFinished = true
    }

    /// Discards uncommitted changes, keeping the share's previous contents.
    public func cancel() {
        guard !isFinished else { return }
        try? connection.execute("ROLLBACK")
        isFinished = true
    }
}
