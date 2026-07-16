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

/// 查询结果行的轻量读取器
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

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    public func date(_ index: Int32) -> Date? {
        isNull(index) ? nil : Date(timeIntervalSince1970: real(index))
    }
}

/// 系统 libsqlite3 薄封装：串行使用（调用方负责队列约束），WAL 模式。
/// 数据工程师可直接 `sqlite3 eureka.sqlite` 查库调试。
public final class SQLiteDB {
    /// 锁争用等待上限（毫秒）。扫描是每文件一个短事务，5s 足以吸收所有争用。
    private static let busyTimeoutMs: Int32 = 5000

    private var handle: OpaquePointer?

    /// readOnly=true 用于只读打开外部库（如 opencode.db）：绝不建库/写入，也不改 journal 模式。
    public init(path: String, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开"
            sqlite3_close_v2(db)
            throw SQLiteError(code: SQLITE_CANTOPEN, message: message)
        }
        handle = db
        // 锁争用时最多等待 5s 再返回，而非立刻抛 SQLITE_BUSY。
        // 多连接（UsageService / SessionBrowser）与跨进程（--usage-snapshot CLI）
        // 并发写时，配合 WAL + BEGIN IMMEDIATE 即可避免 "database is locked"。
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
            let message = errorMessage.map { String(cString: $0) } ?? "execute 失败"
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

    /// 最近一条语句实际改动的行数（INSERT OR IGNORE 判定是否真插入：0=被忽略）
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
