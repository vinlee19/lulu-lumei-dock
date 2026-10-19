import EurekaKit
import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite(\(code)): \(message)" }
}

public enum SQLiteValue {
    case text(String)
    case int(Int64)
    case real(Double)
    case null

    public static func date(_ date: Date?) -> SQLiteValue {
        date.map { .real($0.timeIntervalSince1970) } ?? .null
    }

    public static func string(_ value: String?) -> SQLiteValue {
        value.map { .text($0) } ?? .null
    }
}

/// Lightweight reader for a query result row
public struct SQLiteRow {
    let statement: OpaquePointer

    public func text(_ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    public func int(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    public func real(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    /// BLOB column (NULL → nil; zero length → empty Data)
    public func blob(_ index: Int32) -> Data? {
        guard !isNull(index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    public func date(_ index: Int32) -> Date? {
        isNull(index) ? nil : Date(timeIntervalSince1970: real(index))
    }
}

/// Thin wrapper over the system libsqlite3: used serially (callers own the queue constraint), WAL
/// mode. Data engineers can query and debug the DB directly with `sqlite3 eureka.sqlite`.
public final class SQLiteDB {
    /// Maximum wait on lock contention (milliseconds). Scans use one short transaction per file; 5s
    /// absorbs all contention.
    private static let busyTimeoutMs: Int32 = 5000

    private var handle: OpaquePointer?

    /// readOnly=true opens an external DB read-only (e.g. opencode.db): never creates or writes it,
    /// nor changes its journal mode.
    public init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? L10n.text("Unable to open", zhHans: "无法打开")
            sqlite3_close_v2(db)
            throw SQLiteError(code: SQLITE_CANTOPEN, message: message)
        }
        handle = db
        // On lock contention wait up to 5s before returning, instead of throwing SQLITE_BUSY
        // immediately. With multiple connections (UsageService / SessionBrowser) and cross-process
        // writers (the --usage-snapshot CLI) writing concurrently, this plus WAL + BEGIN IMMEDIATE
        // avoids "database is locked".
        sqlite3_busy_timeout(db, Self.busyTimeoutMs)
        if !readOnly {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? L10n.text("execute failed", zhHans: "execute 失败")
            sqlite3_free(errorMessage)
            throw SQLiteError(code: sqlite3_errcode(handle), message: "\(message) — \(sql)")
        }
    }

    public func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// Whether a table exists (for external databases that swap tables across versions: querying a
    /// missing table errors out outright)
    public func tableExists(_ name: String) -> Bool {
        ((try? query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            [.text(name)]) { _ in true }) ?? []).isEmpty == false
    }

    public func query<T>(
        _ sql: String, _ bindings: [SQLiteValue] = [], map: (SQLiteRow) -> T
    ) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var results: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                results.append(map(SQLiteRow(statement: statement!)))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
        return results
    }

    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    /// Rows actually changed by the last statement (tells whether INSERT OR IGNORE really inserted:
    /// 0 = ignored)
    public var changes: Int {
        Int(sqlite3_changes(handle))
    }

    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ bindings: [SQLiteValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(
                code: sqlite3_errcode(handle),
                message: "\(String(cString: sqlite3_errmsg(handle))) — \(sql)")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string): sqlite3_bind_text(statement, index, string, -1, transient)
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }
}
