import CSQLite
import Foundation
import ZCore

// A minimal wrapper over the SQLite C API. One `SQLiteDatabase` owns one connection; every use of the raw handle
// happens under a lock, because a sqlite3 handle must not be used from two threads at the same time.

/// A value bound to, or read from, a SQLite statement.
public enum SQLiteValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

extension SQLiteValue: ExpressibleByNilLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .real(value) }
    public init(stringLiteral value: String) { self = .text(value) }
}

public extension SQLiteValue {
    init(_ value: Int) { self = .integer(Int64(value)) }
    init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    init(_ value: String?) { self = value.map { .text($0) } ?? .null }

    var isNull: Bool { if case .null = self { return true }; return false }

    var int64Value: Int64? {
        switch self {
        case .integer(let v): return v
        case .real(let v): return Int64(exactly: v.rounded(.towardZero))
        case .text(let s): return Int64(s)
        case .null, .blob: return nil
        }
    }

    var intValue: Int? { int64Value.flatMap { Int(exactly: $0) } }

    var doubleValue: Double? {
        switch self {
        case .integer(let v): return Double(v)
        case .real(let v): return v
        case .text(let s): return Double(s)
        case .null, .blob: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .text(let s): return s
        case .integer(let v): return String(v)
        case .real(let v): return String(v)
        case .blob(let d): return String(decoding: d, as: UTF8.self)
        case .null: return nil
        }
    }

    var dataValue: Data? {
        switch self {
        case .blob(let d): return d
        case .text(let s): return Data(s.utf8)
        case .null, .integer, .real: return nil
        }
    }
}

/// One result row: column names plus values, in select order.
public struct SQLiteRow: Sendable, Hashable {
    public let columns: [String]
    public let values: [SQLiteValue]

    public init(columns: [String], values: [SQLiteValue]) {
        self.columns = columns; self.values = values
    }

    public subscript(index: Int) -> SQLiteValue {
        values.indices.contains(index) ? values[index] : .null
    }

    public subscript(column: String) -> SQLiteValue {
        guard let index = columns.firstIndex(of: column) else { return .null }
        return self[index]
    }
}

/// SQLITE_TRANSIENT: makes SQLite copy a bound text/blob buffer before the bind call returns.
private var sqliteTransient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// A prepared statement. Not `Sendable`: create and use it inside one `withConnection`/`transaction` block.
public final class SQLiteStatement {
    public let sql: String
    let handle: OpaquePointer
    let db: OpaquePointer

    init(db: OpaquePointer, sql: String) throws {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw SQLiteDatabase.error(code: rc, message: SQLiteDatabase.message(db), sql: sql)
        }
        guard let statement else {
            throw ZError.invalidArgument("SQLite: no statement in \"\(sql.prefix(160))\"")
        }
        self.handle = statement
        self.db = db
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    // MARK: Binding (indices are 1-based, as in SQLite)

    public func bind(_ value: SQLiteValue, at index: Int) throws {
        let i = Int32(clamping: index)
        let rc: Int32
        switch value {
        case .null:
            rc = sqlite3_bind_null(handle, i)
        case .integer(let v):
            rc = sqlite3_bind_int64(handle, i, v)
        case .real(let v):
            rc = sqlite3_bind_double(handle, i, v)
        case .text(let s):
            rc = sqlite3_bind_text(handle, i, s, Int32(clamping: s.utf8.count), sqliteTransient)
        case .blob(let d):
            if d.isEmpty {
                rc = sqlite3_bind_zeroblob(handle, i, 0)
            } else {
                rc = d.withUnsafeBytes { raw in
                    sqlite3_bind_blob(handle, i, raw.baseAddress, Int32(clamping: raw.count), sqliteTransient)
                }
            }
        }
        guard rc == SQLITE_OK else { throw SQLiteDatabase.error(code: rc, message: SQLiteDatabase.message(db), sql: sql) }
    }

    /// Binds positional values starting at parameter 1.
    public func bind(_ values: [SQLiteValue]) throws {
        for (offset, value) in values.enumerated() { try bind(value, at: offset + 1) }
    }

    /// Binds a named parameter (`:name`, `@name` or `$name`; pass the name including its prefix).
    public func bind(_ value: SQLiteValue, named name: String) throws {
        let index = sqlite3_bind_parameter_index(handle, name)
        guard index > 0 else { throw ZError.invalidArgument("SQLite: no parameter named \(name) in \"\(sql.prefix(160))\"") }
        try bind(value, at: Int(index))
    }

    public var parameterCount: Int { Int(sqlite3_bind_parameter_count(handle)) }

    // MARK: Stepping

    /// Advances to the next row. Returns `true` when a row is available, `false` when the statement is done.
    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw SQLiteDatabase.error(code: rc, message: SQLiteDatabase.message(db), sql: sql)
    }

    /// Resets the statement so it can be stepped again (bindings are kept).
    public func reset() { sqlite3_reset(handle) }

    public func clearBindings() { sqlite3_clear_bindings(handle) }

    /// Resets, binds `values`, and steps to completion.
    public func run(_ values: [SQLiteValue] = []) throws {
        reset()
        clearBindings()
        try bind(values)
        while try step() {}
    }

    // MARK: Columns (indices are 0-based, as in SQLite)

    public var columnCount: Int { Int(sqlite3_column_count(handle)) }

    public func columnName(_ index: Int) -> String {
        guard let name = sqlite3_column_name(handle, Int32(clamping: index)) else { return "" }
        return String(cString: name)
    }

    public var columnNames: [String] { (0..<columnCount).map { columnName($0) } }

    public func isNull(_ index: Int) -> Bool {
        sqlite3_column_type(handle, Int32(clamping: index)) == SQLITE_NULL
    }

    public func int64(_ index: Int) -> Int64 { sqlite3_column_int64(handle, Int32(clamping: index)) }

    public func int(_ index: Int) -> Int { Int(truncatingIfNeeded: int64(index)) }

    public func double(_ index: Int) -> Double { sqlite3_column_double(handle, Int32(clamping: index)) }

    public func string(_ index: Int) -> String? {
        let i = Int32(clamping: index)
        guard sqlite3_column_type(handle, i) != SQLITE_NULL else { return nil }
        let bytes = sqlite3_column_text(handle, i)
        let count = Int(sqlite3_column_bytes(handle, i))
        guard let bytes, count > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    public func data(_ index: Int) -> Data? {
        let i = Int32(clamping: index)
        guard sqlite3_column_type(handle, i) != SQLITE_NULL else { return nil }
        let bytes = sqlite3_column_blob(handle, i)
        let count = Int(sqlite3_column_bytes(handle, i))
        guard let bytes, count > 0 else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    /// Reads a blob column without copying it. The buffer is only valid inside `body`.
    public func withBlob<R>(_ index: Int, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        let i = Int32(clamping: index)
        let bytes = sqlite3_column_blob(handle, i)
        let count = Int(sqlite3_column_bytes(handle, i))
        guard let bytes, count > 0 else { return try body(UnsafeRawBufferPointer(start: nil, count: 0)) }
        return try body(UnsafeRawBufferPointer(start: bytes, count: count))
    }

    public func value(_ index: Int) -> SQLiteValue {
        switch sqlite3_column_type(handle, Int32(clamping: index)) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(int64(index))
        case SQLITE_FLOAT: return .real(double(index))
        case SQLITE_BLOB: return .blob(data(index) ?? Data())
        default: return .text(string(index) ?? "")
        }
    }

    /// The current row as values.
    public func currentValues() -> [SQLiteValue] { (0..<columnCount).map { value($0) } }
}

/// The raw connection, handed out only inside `SQLiteDatabase.withConnection` / `transaction`, while the lock is held.
/// Do not store it or send it elsewhere.
public struct SQLiteConnection {
    let handle: OpaquePointer

    init(handle: OpaquePointer) { self.handle = handle }

    /// Runs one or more SQL statements without bindings (schema, pragmas).
    public func exec(_ sql: String) throws {
        var errorText: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorText)
        let detail = errorText.map { String(cString: $0) }
        sqlite3_free(errorText)
        guard rc == SQLITE_OK else {
            throw SQLiteDatabase.error(code: rc, message: detail ?? SQLiteDatabase.message(handle), sql: sql)
        }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(db: handle, sql: sql)
    }

    /// Prepares, binds and runs one statement to completion.
    public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        while try statement.step() {}
    }

    /// Prepares, binds and collects every row.
    public func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        let columns = statement.columnNames
        var rows: [SQLiteRow] = []
        while try statement.step() {
            rows.append(SQLiteRow(columns: columns, values: statement.currentValues()))
        }
        return rows
    }

    /// The first column of the first row, or `.null` when there is no row.
    public func scalar(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> SQLiteValue {
        let statement = try prepare(sql)
        try statement.bind(bindings)
        guard try statement.step(), statement.columnCount > 0 else { return .null }
        return statement.value(0)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Rows changed by the most recent INSERT/UPDATE/DELETE.
    public var changes: Int { Int(sqlite3_changes(handle)) }

    public var isInTransaction: Bool { sqlite3_get_autocommit(handle) == 0 }

    /// Runs `body` in a transaction: commits when it returns, rolls back when it throws.
    /// Nested calls use a savepoint, so an inner failure only undoes the inner block.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if isInTransaction {
            try exec("SAVEPOINT zkit_savepoint")
            do {
                let result = try body()
                try exec("RELEASE SAVEPOINT zkit_savepoint")
                return result
            } catch {
                try? exec("ROLLBACK TO SAVEPOINT zkit_savepoint")
                try? exec("RELEASE SAVEPOINT zkit_savepoint")
                throw error
            }
        }
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            if isInTransaction { try? exec("ROLLBACK") }
            throw error
        }
    }
}

extension NSRecursiveLock {
    @inline(__always)
    func zkitLocked<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// One SQLite connection, safe to share between tasks: every call is serialised by a lock.
public final class SQLiteDatabase: @unchecked Sendable {
    /// The file path, or ":memory:".
    public let path: String
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    /// Opens (creating when needed) the database at `path`. Use ":memory:" for a private in-memory database.
    public init(path: String = ":memory:", readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let mode = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        let rc = sqlite3_open_v2(path, &db, mode | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let message = SQLiteDatabase.message(db)
            sqlite3_close_v2(db)
            throw SQLiteDatabase.error(code: rc, message: message, sql: nil)
        }
        self.path = path
        self.handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 5_000)
        try exec("PRAGMA foreign_keys = ON")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    public var isOpen: Bool { lock.zkitLocked { handle != nil } }

    /// Closes the connection. Later calls throw.
    public func close() {
        lock.zkitLocked {
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
        }
    }

    /// Runs `body` with exclusive use of the connection.
    public func withConnection<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try lock.zkitLocked {
            guard let handle else { throw ZError.invalidArgument("SQLite database \(path) is closed") }
            return try body(SQLiteConnection(handle: handle))
        }
    }

    /// Runs `body` in a transaction with exclusive use of the connection.
    public func transaction<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try withConnection { connection in
            try connection.transaction { try body(connection) }
        }
    }

    public func exec(_ sql: String) throws {
        try withConnection { try $0.exec(sql) }
    }

    public func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        try withConnection { try $0.execute(sql, bindings) }
    }

    public func query(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> [SQLiteRow] {
        try withConnection { try $0.query(sql, bindings) }
    }

    public func scalar(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> SQLiteValue {
        try withConnection { try $0.scalar(sql, bindings) }
    }

    /// Row id of the most recent INSERT on this connection. With concurrent writers, read it inside the same
    /// `withConnection`/`transaction` block as the insert.
    public var lastInsertRowID: Int64 {
        (try? withConnection { $0.lastInsertRowID }) ?? 0
    }

    /// The SQLite library version string ("3.45.1").
    public static var libraryVersion: String {
        guard let version = sqlite3_libversion() else { return "unknown" }
        return String(cString: version)
    }

    /// Whether the library was compiled with an option, e.g. "ENABLE_FTS5".
    public static func isCompileOptionEnabled(_ option: String) -> Bool {
        sqlite3_compileoption_used(option) == 1
    }

    // MARK: Errors

    static func message(_ db: OpaquePointer?) -> String {
        guard let db, let text = sqlite3_errmsg(db) else { return "unknown error" }
        return String(cString: text)
    }

    /// Maps a SQLite result code to `ZError` (ZCore has no storage case, so the nearest case is used and the
    /// SQLite code + message are kept in the text).
    static func error(code: Int32, message: String, sql: String?) -> ZError {
        let name = sqlite3_errstr(code).map { String(cString: $0) } ?? "error"
        var text = "SQLite \(code) (\(name)): \(message)"
        if let sql { text += " [\(sql.prefix(160))]" }
        switch code & 0xFF {
        case SQLITE_CANTOPEN, SQLITE_NOTFOUND:
            return .notFound(text)
        case SQLITE_INTERRUPT, SQLITE_ABORT:
            return .cancelled
        case SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_FORMAT, SQLITE_MISMATCH:
            return .decoding(text)
        default:
            return .invalidArgument(text)
        }
    }
}
