import Foundation
import SQLite3

public struct IndexStoreError: Error, CustomStringConvertible {
    public let description: String
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

/// A thin wrapper over one SQLite connection. Not thread-safe: callers serialize access.
final class Connection {
    let handle: OpaquePointer

    init(url: URL) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw IndexStoreError(description: "Couldn't open \(url.path): \(message)")
        }
        handle = db
        // Readers and the scan writer share the file; wait instead of failing when it's busy.
        sqlite3_busy_timeout(db, 60_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(error)
            throw IndexStoreError(description: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        try Statement(connection: self, sql: sql)
    }

    var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }
}

final class Statement {
    private let handle: OpaquePointer
    private let connection: Connection

    init(connection: Connection, sql: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IndexStoreError(description: connection.errorMessage)
        }
        self.handle = statement
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// Resets the statement so it can run again with new values.
    func bind(_ values: [SQLValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(handle, index, text, -1, SQLITE_TRANSIENT)
            case .int(let number): result = sqlite3_bind_int64(handle, index, number)
            case .double(let number): result = sqlite3_bind_double(handle, index, number)
            case .null: result = sqlite3_bind_null(handle, index)
            }
            guard result == SQLITE_OK else { throw IndexStoreError(description: connection.errorMessage) }
        }
    }

    /// Advances to the next row. Returns `false` when there are no more rows.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw IndexStoreError(description: connection.errorMessage)
        }
    }

    func text(_ column: Int32) -> String {
        sqlite3_column_text(handle, column).map { String(cString: $0) } ?? ""
    }

    func int(_ column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    func optionalDouble(_ column: Int32) -> Double? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : sqlite3_column_double(handle, column)
    }
}
