import Foundation
import SQLite3

/// Minimal wrapper over the system SQLite, with no third-party dependency.
///
/// Location history is the most sensitive data this app holds, so the
/// dependency surface around it is kept at zero deliberately: every line that
/// touches the database is in this repository and auditable.
///
/// All access is funnelled through a serial queue. SQLite connections are not
/// thread-safe under the default threading mode, and location callbacks arrive
/// on a different thread from the UI.
public final class SQLiteDatabase {

    public enum Error: Swift.Error, LocalizedError {
        case openFailed(String)
        case prepareFailed(String, sql: String)
        case stepFailed(String)
        case bindFailed(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let m): return "Could not open database: \(m)"
            case .prepareFailed(let m, let sql): return "Could not prepare statement: \(m) [\(sql)]"
            case .stepFailed(let m): return "Statement failed: \(m)"
            case .bindFailed(let m): return "Could not bind value: \(m)"
            }
        }
    }

    public enum Value {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    private var handle: OpaquePointer?
    private let queue: DispatchQueue
    private var statementCache: [String: OpaquePointer] = [:]
    private var statementOrder: [String] = []

    /// Ceiling on cached prepared statements.
    ///
    /// Most queries in the app are fixed strings, so the cache would normally
    /// settle at a couple of dozen. One is not: the bulk segment lookup builds
    /// its placeholder list from the chunk size, so a partial final chunk
    /// produces a distinct statement each time. Without a cap those accumulate
    /// for the life of the connection.
    private static let statementCacheLimit = 64

    /// - Parameter readOnly: city packs are opened read-only so a corrupt or
    ///   hostile pack cannot be used to mutate anything on disk.
    public init(path: String, readOnly: Bool = false) throws {
        self.queue = DispatchQueue(label: "walktracker.sqlite.\(URL(fileURLWithPath: path).lastPathComponent)")

        var flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        flags |= SQLITE_OPEN_NOMUTEX

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
            if let handle { sqlite3_close_v2(handle) }
            throw Error.openFailed(message)
        }
        self.handle = handle

        // Busy timeout rather than immediate failure: the tracking engine and
        // the UI can legitimately touch the database at the same moment.
        sqlite3_busy_timeout(handle, 5_000)

        if !readOnly {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
        }
        try execute("PRAGMA foreign_keys = ON")
    }

    deinit {
        for (_, statement) in statementCache {
            sqlite3_finalize(statement)
        }
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    // MARK: - Execution

    public func execute(_ sql: String) throws {
        try queue.sync { try executeLocked(sql) }
    }

    private func executeLocked(_ sql: String) throws {
        guard let handle else { throw Error.stepFailed("database is closed") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw Error.stepFailed(message)
        }
    }

    /// Runs a statement that returns no rows and reports the rows it changed.
    @discardableResult
    public func run(_ sql: String, _ parameters: [Value] = []) throws -> Int {
        try queue.sync {
            let statement = try prepareLocked(sql)
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try bind(parameters, to: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw Error.stepFailed(lastErrorMessage())
            }
            return Int(sqlite3_changes(handle))
        }
    }

    /// Runs a query, mapping each row with `decode`.
    public func query<T>(_ sql: String, _ parameters: [Value] = [], decode: (Row) throws -> T) throws -> [T] {
        try queue.sync {
            let statement = try prepareLocked(sql)
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try bind(parameters, to: statement)

            var output: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW {
                    output.append(try decode(Row(statement: statement)))
                } else if result == SQLITE_DONE {
                    break
                } else {
                    throw Error.stepFailed(lastErrorMessage())
                }
            }
            return output
        }
    }

    /// Folds the write-ahead log back into the main database file.
    ///
    /// Required before copying the file for a backup. Without it the most
    /// recent writes are still sitting in the sidecar log, and the copy is
    /// silently stale: the user would back up their walks and find the last
    /// few missing.
    public func checkpoint() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func lastInsertRowID() -> Int64 {
        queue.sync { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    ///
    /// Takes the same serial queue as every other call, so `body` must use the
    /// `unsafe*` entry points rather than re-entering the public API, which
    /// would deadlock.
    public func transaction<T>(_ body: (UnsafeHandle) throws -> T) throws -> T {
        try queue.sync {
            try executeLocked("BEGIN IMMEDIATE")
            do {
                let value = try body(UnsafeHandle(database: self))
                try executeLocked("COMMIT")
                return value
            } catch {
                // Best effort: if the rollback also fails the original error is
                // the useful one, so it is the one that propagates.
                try? executeLocked("ROLLBACK")
                throw error
            }
        }
    }

    /// Transaction-scoped access. Only valid inside `transaction(_:)`.
    public struct UnsafeHandle {
        fileprivate let database: SQLiteDatabase

        @discardableResult
        public func run(_ sql: String, _ parameters: [SQLiteDatabase.Value] = []) throws -> Int {
            let statement = try database.prepareLocked(sql)
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try database.bind(parameters, to: statement)
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE || result == SQLITE_ROW else {
                throw SQLiteDatabase.Error.stepFailed(database.lastErrorMessage())
            }
            return Int(sqlite3_changes(database.handle))
        }

        public func query<T>(
            _ sql: String,
            _ parameters: [SQLiteDatabase.Value] = [],
            decode: (Row) throws -> T
        ) throws -> [T] {
            let statement = try database.prepareLocked(sql)
            defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
            try database.bind(parameters, to: statement)
            var output: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW {
                    output.append(try decode(Row(statement: statement)))
                } else if result == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteDatabase.Error.stepFailed(database.lastErrorMessage())
                }
            }
            return output
        }

        /// Folds the write-ahead log back into the main database file.
    ///
    /// Required before copying the file for a backup. Without it the most
    /// recent writes are still sitting in the sidecar log, and the copy is
    /// silently stale: the user would back up their walks and find the last
    /// few missing.
    public func checkpoint() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func lastInsertRowID() -> Int64 {
            database.handle.map { sqlite3_last_insert_rowid($0) } ?? 0
        }
    }

    // MARK: - Internals

    /// Statements are cached and reused. Every query in this app runs on a hot
    /// path (one per GPS fix, or one per map redraw), and re-parsing SQL each
    /// time is the single most wasteful thing a SQLite client can do.
    fileprivate func prepareLocked(_ sql: String) throws -> OpaquePointer {
        if let cached = statementCache[sql] { return cached }
        guard let handle else { throw Error.prepareFailed("database is closed", sql: sql) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Error.prepareFailed(lastErrorMessage(), sql: sql)
        }

        // Safe to finalise an evicted statement here: everything runs on one
        // serial queue and no statement is held across calls, so nothing can
        // be mid-step while this runs.
        if statementOrder.count >= Self.statementCacheLimit, let oldest = statementOrder.first {
            statementOrder.removeFirst()
            if let evicted = statementCache.removeValue(forKey: oldest) {
                sqlite3_finalize(evicted)
            }
        }

        statementCache[sql] = statement
        statementOrder.append(sql)
        return statement
    }

    fileprivate func bind(_ parameters: [Value], to statement: OpaquePointer) throws {
        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .integer(let v):
                result = sqlite3_bind_int64(statement, index, v)
            case .real(let v):
                result = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                // SQLITE_TRANSIENT: SQLite copies the bytes, so the Swift
                // string is free to be deallocated before the step runs.
                result = sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case .blob(let v):
                result = v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            }
            guard result == SQLITE_OK else { throw Error.bindFailed(lastErrorMessage()) }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate func lastErrorMessage() -> String {
        guard let handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    // MARK: - Row

    public struct Row {
        fileprivate let statement: OpaquePointer

        public func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        public func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

        public func isNull(_ index: Int32) -> Bool {
            sqlite3_column_type(statement, index) == SQLITE_NULL
        }

        public func string(_ index: Int32) -> String? {
            guard let pointer = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: pointer)
        }

        public func blob(_ index: Int32) -> Data? {
            guard let pointer = sqlite3_column_blob(statement, index) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0 else { return Data() }
            return Data(bytes: pointer, count: count)
        }

        public func optionalInt(_ index: Int32) -> Int64? {
            isNull(index) ? nil : int(index)
        }
    }
}
