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
    private let reader: Connection
    private let readerLock = NSLock()

    private static let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE VIRTUAL TABLE IF NOT EXISTS entries USING fts5(
            name,
            share UNINDEXED,
            relative_path UNINDEXED,
            is_dir UNINDEXED,
            size UNINDEXED,
            modified UNINDEXED,
            tokenize = 'trigram'
        );
        PRAGMA user_version = 1;
        """

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Connection(url: url).execute(Self.schema)
        self.url = url
        self.reader = try Connection(url: url)
    }

    /// Starts replacing everything stored for `share`. Nothing changes for searches
    /// until ``ShareReplacement/commit()`` — except on a share's very first index,
    /// where results are made searchable as they arrive.
    public func beginReplacing(share: String) throws -> ShareReplacement {
        try ShareReplacement(connection: Connection(url: url), share: share)
    }

    /// Returns items whose name contains `text`, ignoring case. Most recently modified first.
    public func search(_ text: String, limit: Int = 200) throws -> [SearchResult] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        readerLock.lock()
        defer { readerLock.unlock() }
        let statement = try reader.prepare("""
            SELECT share, relative_path, name, is_dir, size, modified
            FROM entries WHERE name LIKE ?
            ORDER BY modified DESC LIMIT ?
            """)
        try statement.bind([.text("%\(text)%"), .int(Int64(limit))])
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
        let statement = try connection.prepare("DELETE FROM entries WHERE share = ?")
        try statement.bind([.text(share)])
        _ = try statement.step()
    }
}

/// Replaces the stored contents of one share. Use it from a single task.
///
/// If it's discarded without ``commit()``, the share's previous contents are kept.
public final class ShareReplacement {
    public let share: String
    public private(set) var insertedCount = 0

    private let connection: Connection
    private let insertStatement: Statement
    /// On a share's first index there is nothing to protect, so rows are committed as they
    /// arrive and the user can search while a long first scan is still running.
    private let commitsProgressively: Bool
    private var uncommittedCount = 0
    private var isFinished = false
    private static let progressiveCommitSize = 5_000

    init(connection: Connection, share: String) throws {
        self.connection = connection
        self.share = share

        let existing = try connection.prepare("SELECT 1 FROM entries WHERE share = ? LIMIT 1")
        try existing.bind([.text(share)])
        commitsProgressively = try !existing.step()

        try connection.execute("BEGIN IMMEDIATE")
        let delete = try connection.prepare("DELETE FROM entries WHERE share = ?")
        try delete.bind([.text(share)])
        _ = try delete.step()
        insertStatement = try connection.prepare("""
            INSERT INTO entries (name, share, relative_path, is_dir, size, modified)
            VALUES (?, ?, ?, ?, ?, ?)
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
