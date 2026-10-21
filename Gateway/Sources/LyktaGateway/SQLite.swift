#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
}

protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .integer(self) } }
extension Int: SQLBindable { var sqlValue: SQLValue { .integer(Int64(self)) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .real(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .integer(self ? 1 : 0) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite \(code): \(message)" }
}

struct Row: Sendable {
    private let values: [String: SQLValue]

    init(_ values: [String: SQLValue]) {
        self.values = values
    }

    subscript(column: String) -> SQLValue { values[column] ?? .null }

    func string(_ column: String) throws -> String {
        guard case let .text(value) = self[column] else { throw mismatch(column) }
        return value
    }

    func optionalString(_ column: String) throws -> String? {
        self[column] == .null ? nil : try string(column)
    }

    func integer(_ column: String) throws -> Int64 {
        guard case let .integer(value) = self[column] else { throw mismatch(column) }
        return value
    }

    func optionalInteger(_ column: String) throws -> Int64? {
        self[column] == .null ? nil : try integer(column)
    }

    func optionalReal(_ column: String) throws -> Double? {
        switch self[column] {
        case .null: nil
        case let .real(value): value
        case let .integer(value): Double(value)
        case .text: throw mismatch(column)
        }
    }

    private func mismatch(_ column: String) -> SQLiteError {
        SQLiteError(code: SQLITE_MISMATCH, message: "Unexpected value in column \(column)")
    }
}

final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK else {
            let error = SQLiteError(code: status, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed")
            sqlite3_close(handle)
            throw error
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func run(_ sql: String, _ values: any SQLBindable...) throws {
        _ = try rows(sql, values)
    }

    func query(_ sql: String, _ values: any SQLBindable...) throws -> [Row] {
        try rows(sql, values)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func rows(_ sql: String, _ values: [any SQLBindable]) throws -> [Row] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            try check(bind(value.sqlValue, to: statement, at: Int32(offset + 1)))
        }
        var rows: [Row] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw failure(status) }
            var row: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                row[String(cString: sqlite3_column_name(statement, column))] = value(of: statement, at: column)
            }
            rows.append(Row(row))
        }
    }

    private func bind(_ value: SQLValue, to statement: OpaquePointer?, at index: Int32) -> Int32 {
        switch value {
        case .null: sqlite3_bind_null(statement, index)
        case let .integer(value): sqlite3_bind_int64(statement, index, value)
        case let .real(value): sqlite3_bind_double(statement, index, value)
        case let .text(value): sqlite3_bind_text(statement, index, value, -1, Self.transient)
        }
    }

    private func value(of statement: OpaquePointer?, at column: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: .text(String(cString: sqlite3_column_text(statement, column)))
        default: .null
        }
    }

    private func check(_ status: Int32) throws {
        guard status == SQLITE_OK else { throw failure(status) }
    }

    private func failure(_ status: Int32) -> SQLiteError {
        SQLiteError(code: status, message: String(cString: sqlite3_errmsg(handle)))
    }

    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
}
