import Foundation
import SQLite3

/// Minimal, dependency-free SQLite wrapper. One connection; callers serialise access
/// (the `Database` actor does this for the app's own catalogue).
public final class SQLiteConnection {
    public struct Error: Swift.Error, LocalizedError, CustomStringConvertible {
        public let code: Int32
        public let message: String
        public var description: String { "SQLite error \(code): \(message)" }
        public var errorDescription: String? { description }
    }

    public enum Value: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    public struct Row {
        fileprivate let names: [String: Int]
        fileprivate let values: [Value]

        public subscript(_ name: String) -> Value {
            guard let i = names[name] else { return .null }
            return values[i]
        }
        public func int(_ name: String) -> Int64? {
            switch self[name] {
            case .integer(let v): return v
            case .real(let v): return Int64(v)
            case .text(let s): return Int64(s)
            default: return nil
            }
        }
        public func double(_ name: String) -> Double? {
            switch self[name] {
            case .integer(let v): return Double(v)
            case .real(let v): return v
            case .text(let s): return Double(s)
            default: return nil
            }
        }
        public func string(_ name: String) -> String? {
            switch self[name] {
            case .text(let s): return s
            case .integer(let v): return String(v)
            case .real(let v): return String(v)
            case .blob(let d): return String(data: d, encoding: .utf8)
            default: return nil
            }
        }
        public func blob(_ name: String) -> Data? {
            switch self[name] {
            case .blob(let d): return d
            case .text(let s): return s.data(using: .utf8)
            default: return nil
            }
        }
        public func bool(_ name: String) -> Bool { (int(name) ?? 0) != 0 }
        public func date(_ name: String) -> Date? {
            guard let d = double(name) else { return nil }
            return Date(timeIntervalSince1970: d)
        }
    }

    private var db: OpaquePointer?
    public let path: String

    public init(path: String, readOnly: Bool = false, create: Bool = true) throws {
        self.path = path
        var flags: Int32 = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        if create && !readOnly { flags |= SQLITE_OPEN_CREATE }
        flags |= SQLITE_OPEN_NOMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let h = handle { sqlite3_close(h) }
            throw Error(code: rc, message: msg)
        }
        db = h
        sqlite3_busy_timeout(h, 10_000)
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    private func check(_ rc: Int32, _ ok: Int32 = SQLITE_OK) throws {
        guard rc == ok else {
            throw Error(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown")
        }
    }

    public func execute(_ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    /// Changes whenever this or any other connection commits something. Cheap; used to reuse expensive summaries.
    public var changeStamp: String {
        let other = (try? scalarInt("PRAGMA data_version")) ?? 0
        return "\(other)/\(sqlite3_total_changes64(db))"
    }
    public var changes: Int { Int(sqlite3_changes(db)) }

    /// Runs a statement with bound parameters, discarding rows.
    @discardableResult
    public func run(_ sql: String, _ params: [Value] = []) throws -> Int {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { try check(rc); return 0 }
        return changes
    }

    public func query(_ sql: String, _ params: [Value] = []) throws -> [Row] {
        var rows: [Row] = []
        try query(sql, params) { rows.append($0) }
        return rows
    }

    /// Streams rows to `body`; return false from body to stop early.
    static let traceSQL = ProcessInfo.processInfo.environment["BACKUPHQ_TRACE_SQL"] != nil
    public func query(_ sql: String, _ params: [Value] = [], _ body: (Row) throws -> Void) throws {
        let stmt = try prepare(sql, params)
        let t0 = Self.traceSQL ? Date() : nil
        defer {
            sqlite3_finalize(stmt)
            if let t0 { let ms = Date().timeIntervalSince(t0) * 1000; if ms > 50 { FileHandle.standardError.write("SQL \(Int(ms)) ms: \(sql.replacingOccurrences(of: "\n", with: " ").prefix(160))\n".data(using: .utf8)!) } }
        }
        let count = Int(sqlite3_column_count(stmt))
        var names: [String: Int] = [:]
        for i in 0..<count { names[String(cString: sqlite3_column_name(stmt, Int32(i)))] = i }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { try check(rc); break }
            var values: [Value] = []
            values.reserveCapacity(count)
            for i in 0..<count {
                let col = Int32(i)
                switch sqlite3_column_type(stmt, col) {
                case SQLITE_INTEGER: values.append(.integer(sqlite3_column_int64(stmt, col)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(stmt, col)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(stmt, col))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, col))
                    if let p = sqlite3_column_blob(stmt, col), n > 0 {
                        values.append(.blob(Data(bytes: p, count: n)))
                    } else { values.append(.blob(Data())) }
                default: values.append(.null)
                }
            }
            try body(Row(names: names, values: values))
        }
    }

    public func scalarInt(_ sql: String, _ params: [Value] = []) throws -> Int64 {
        let rows = try query(sql, params)
        guard let r = rows.first, let v = r.values.first else { return 0 }
        switch v {
        case .integer(let i): return i
        case .real(let d): return Int64(d)
        case .text(let s): return Int64(s) ?? 0
        default: return 0
        }
    }

    public func scalarString(_ sql: String, _ params: [Value] = []) throws -> String? {
        let rows = try query(sql, params)
        guard let r = rows.first, let v = r.values.first else { return nil }
        switch v {
        case .text(let s): return s
        case .integer(let i): return String(i)
        case .real(let d): return String(d)
        default: return nil
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try execute("COMMIT")
            return r
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        guard let s = stmt else { throw Error(code: SQLITE_ERROR, message: "prepare failed") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .null: sqlite3_bind_null(s, idx)
            case .integer(let v): sqlite3_bind_int64(s, idx, v)
            case .real(let v): sqlite3_bind_double(s, idx, v)
            case .text(let v): sqlite3_bind_text(s, idx, v, -1, transient)
            case .blob(let d):
                if d.isEmpty { sqlite3_bind_zeroblob(s, idx, 0) }
                else { d.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(d.count), transient) } }
            }
        }
        return s
    }
}

// Convenience conversions for binding.
public extension SQLiteConnection.Value {
    init(_ s: String?) { self = s.map { .text($0) } ?? .null }
    init(_ i: Int64?) { self = i.map { .integer($0) } ?? .null }
    init(_ i: Int?) { self = i.map { .integer(Int64($0)) } ?? .null }
    init(_ d: Double?) { self = d.map { .real($0) } ?? .null }
    init(_ b: Bool) { self = .integer(b ? 1 : 0) }
    init(_ d: Date?) { self = d.map { .real($0.timeIntervalSince1970) } ?? .null }
    init(_ d: Data?) { self = d.map { .blob($0) } ?? .null }
}
