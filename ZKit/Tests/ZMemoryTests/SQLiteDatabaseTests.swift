import Foundation
import XCTest
import ZCore
@testable import ZMemory

final class SQLiteDatabaseTests: XCTestCase {
    func testRoundTripsEveryValueType() throws {
        let db = try SQLiteDatabase()
        try db.exec("CREATE TABLE t (a INTEGER, b REAL, c TEXT, d BLOB, e TEXT)")
        let text = "héllo \"quoted\" 'single' 🚀\nsecond line"
        let blob = Data([0, 1, 2, 254, 255])
        try db.execute("INSERT INTO t VALUES (?, ?, ?, ?, ?)", [.integer(-42), .real(3.25), .text(text), .blob(blob), .null])
        let rows = try db.query("SELECT a, b, c, d, e FROM t")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.columns, ["a", "b", "c", "d", "e"])
        XCTAssertEqual(row["a"], .integer(-42))
        XCTAssertEqual(row["b"], .real(3.25))
        XCTAssertEqual(row["c"], .text(text))
        XCTAssertEqual(row["d"], .blob(blob))
        XCTAssertEqual(row["e"], .null)
        XCTAssertEqual(row["missing"], .null)
        XCTAssertEqual(row[0].int64Value, -42)
        XCTAssertEqual(row[2].stringValue, text)
    }

    func testEmptyStringAndEmptyBlobAreNotNull() throws {
        let db = try SQLiteDatabase()
        try db.exec("CREATE TABLE t (s TEXT, b BLOB)")
        try db.execute("INSERT INTO t VALUES (?, ?)", [.text(""), .blob(Data())])
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM t WHERE s IS NOT NULL AND b IS NOT NULL"), .integer(1))
        XCTAssertEqual(try db.scalar("SELECT s FROM t"), .text(""))
        XCTAssertEqual(try db.scalar("SELECT length(b) FROM t"), .integer(0))
    }

    func testLastInsertRowIDAndChanges() throws {
        let db = try SQLiteDatabase()
        try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
        try db.execute("INSERT INTO t (v) VALUES (?)", ["one"])
        XCTAssertEqual(db.lastInsertRowID, 1)
        try db.execute("INSERT INTO t (v) VALUES (?)", ["two"])
        XCTAssertEqual(db.lastInsertRowID, 2)
        let changed = try db.withConnection { connection -> Int in
            try connection.execute("UPDATE t SET v = 'x'")
            return connection.changes
        }
        XCTAssertEqual(changed, 2)
    }

    func testPreparedStatementReuseAndNamedParameters() throws {
        let db = try SQLiteDatabase()
        try db.exec("CREATE TABLE t (n INTEGER, label TEXT)")
        try db.withConnection { connection in
            let insert = try connection.prepare("INSERT INTO t VALUES (?, ?)")
            for n in 1...5 { try insert.run([.integer(Int64(n)), .text("row \(n)")]) }
            let named = try connection.prepare("SELECT label FROM t WHERE n = :n")
            XCTAssertEqual(named.parameterCount, 1)
            try named.bind(.integer(3), named: ":n")
            XCTAssertTrue(try named.step())
            XCTAssertEqual(named.string(0), "row 3")
            XCTAssertFalse(try named.step())
        }
        XCTAssertEqual(try db.scalar("SELECT sum(n) FROM t").int64Value, 15)
    }

    func testTransactionRollsBackOnError() throws {
        let db = try SQLiteDatabase()
        try db.exec("CREATE TABLE t (v INTEGER)")
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction { connection in
            try connection.execute("INSERT INTO t VALUES (1)")
            try connection.execute("INSERT INTO t VALUES (2)")
            throw Boom()
        })
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM t"), .integer(0))
        let value = try db.transaction { connection -> Int in
            try connection.execute("INSERT INTO t VALUES (7)")
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM t"), .integer(1))
    }

    func testNestedTransactionUsesSavepoint() throws {
        let db = try SQLiteDatabase()
        try db.exec("CREATE TABLE t (v INTEGER)")
        struct Boom: Error {}
        try db.transaction { connection in
            try connection.execute("INSERT INTO t VALUES (1)")
            XCTAssertThrowsError(try connection.transaction {
                try connection.execute("INSERT INTO t VALUES (2)")
                throw Boom()
            })
            try connection.transaction {
                try connection.execute("INSERT INTO t VALUES (3)")
            }
        }
        let values = try db.query("SELECT v FROM t ORDER BY v").map { $0[0] }
        XCTAssertEqual(values, [.integer(1), .integer(3)])
    }

    func testErrorsMapToZError() throws {
        let db = try SQLiteDatabase()
        XCTAssertThrowsError(try db.exec("SELEC nonsense")) { error in
            guard case .invalidArgument(let message)? = error as? ZError else {
                return XCTFail("expected ZError.invalidArgument, got \(error)")
            }
            XCTAssertTrue(message.contains("SQLite"), message)
        }
        try db.exec("CREATE TABLE u (id TEXT PRIMARY KEY)")
        try db.execute("INSERT INTO u VALUES ('a')")
        XCTAssertThrowsError(try db.execute("INSERT INTO u VALUES ('a')")) { error in
            XCTAssertNotNil(error as? ZError)
        }
        XCTAssertThrowsError(try SQLiteDatabase(path: "/nonexistent-dir-\(UUID().uuidString)/x.sqlite", readOnly: true)) { error in
            XCTAssertNotNil(error as? ZError)
        }
    }

    func testClosedDatabaseThrows() throws {
        let db = try SQLiteDatabase()
        XCTAssertTrue(db.isOpen)
        db.close()
        XCTAssertFalse(db.isOpen)
        XCTAssertThrowsError(try db.exec("SELECT 1"))
        db.close()  // closing twice is harmless
    }

    func testFileDatabasePersistsAcrossReopen() throws {
        let folder = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite").path
        do {
            let db = try SQLiteDatabase(path: path)
            try db.exec("CREATE TABLE t (v TEXT)")
            try db.execute("INSERT INTO t VALUES (?)", ["kept"])
            db.close()
        }
        let reopened = try SQLiteDatabase(path: path)
        XCTAssertEqual(try reopened.scalar("SELECT v FROM t"), .text("kept"))
    }

    func testConcurrentWritesAreSerialised() async throws {
        let db = try SQLiteDatabase()
        try db.exec("CREATE TABLE t (v INTEGER)")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<64 {
                group.addTask {
                    try db.transaction { connection in
                        try connection.execute("INSERT INTO t VALUES (?)", [.integer(Int64(n))])
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM t"), .integer(64))
        XCTAssertEqual(try db.scalar("SELECT sum(v) FROM t"), .integer(Int64((0..<64).reduce(0, +))))
    }

    func testLibraryInfo() {
        XCTAssertFalse(SQLiteDatabase.libraryVersion.isEmpty)
        XCTAssertTrue(SQLiteDatabase.libraryVersion.hasPrefix("3."))
    }
}
