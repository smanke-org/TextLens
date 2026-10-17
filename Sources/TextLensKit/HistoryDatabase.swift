import Foundation
import SQLite3

/// The capture history on disk: one SQLite database holding every entry, its picture and a
/// full-text index, so saving a capture writes one row instead of rewriting the whole
/// history, and searching doesn't read every entry.
///
/// Also keeps sync bookkeeping: tombstones for deleted entries, which synced files have
/// been read, and small values in `kv`.
public final class HistoryDatabase: @unchecked Sendable {
    public struct DatabaseError: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw DatabaseError("Couldn't open the history database: \(message)")
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    // MARK: Schema

    private func migrate() throws {
        let version = try scalarInt("PRAGMA user_version") ?? 0
        if version < 1 {
            try transaction {
                try exec("""
                    CREATE TABLE IF NOT EXISTS entries (
                        rowid INTEGER PRIMARY KEY,
                        id TEXT NOT NULL UNIQUE,
                        date REAL NOT NULL,
                        modified REAL NOT NULL,
                        meta BLOB NOT NULL
                    )
                    """)
                try exec("CREATE INDEX IF NOT EXISTS entries_date ON entries(date DESC)")
                try exec("CREATE TABLE IF NOT EXISTS images (id TEXT PRIMARY KEY, png BLOB NOT NULL)")
                // Trigram: finds any part of a word, in any language, ignoring case and accents.
                try exec("CREATE VIRTUAL TABLE IF NOT EXISTS entry_text USING fts5(body, tokenize = 'trigram remove_diacritics 1')")
                try exec("CREATE TABLE IF NOT EXISTS tombstones (id TEXT PRIMARY KEY, at REAL NOT NULL)")
                try exec("CREATE TABLE IF NOT EXISTS seen_files (name TEXT PRIMARY KEY, mtime REAL NOT NULL)")
                try exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB)")
                try exec("PRAGMA user_version = 1")
            }
        }
    }

    // MARK: Entries

    /// Every entry, newest first.
    public func allEntries() -> [HistoryEntry] {
        (try? rows("SELECT meta FROM entries ORDER BY date DESC") { Self.decode($0, 0) })?.compactMap { $0 } ?? []
    }

    public func entry(_ id: UUID) -> HistoryEntry? {
        (try? rows("SELECT meta FROM entries WHERE id = ?", [id.uuidString]) { Self.decode($0, 0) })?.first ?? nil
    }

    public var count: Int { (try? scalarInt("SELECT count(*) FROM entries")) ?? 0 }

    /// Adds or replaces entries (and their pictures, where given), keeping the index in step.
    public func upsert(_ entries: [(HistoryEntry, png: Data?)]) throws {
        try transaction {
            for (entry, png) in entries {
                let meta = try Self.encoder.encode(entry)
                let id = entry.id.uuidString
                try run("""
                    INSERT INTO entries (id, date, modified, meta) VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET date = excluded.date, modified = excluded.modified, meta = excluded.meta
                    """, [id, entry.date.timeIntervalSinceReferenceDate, entry.lastModified.timeIntervalSinceReferenceDate, meta])
                guard let rowid = try scalarInt("SELECT rowid FROM entries WHERE id = ?", [id]) else { continue }
                try run("DELETE FROM entry_text WHERE rowid = ?", [rowid])
                try run("INSERT INTO entry_text (rowid, body) VALUES (?, ?)", [rowid, HistoryQuery.searchBody(entry)])
                if let png { try run("INSERT OR REPLACE INTO images (id, png) VALUES (?, ?)", [id, png]) }
                try run("DELETE FROM tombstones WHERE id = ?", [id])
            }
        }
    }

    public func upsert(_ entry: HistoryEntry, png: Data? = nil) throws { try upsert([(entry, png: png)]) }

    /// Removes entries and their pictures. `tombstone` records the deletion so it can sync.
    public func delete(_ ids: [UUID], tombstone: Date?) throws {
        try transaction {
            for id in ids.map(\.uuidString) {
                if let rowid = try scalarInt("SELECT rowid FROM entries WHERE id = ?", [id]) {
                    try run("DELETE FROM entry_text WHERE rowid = ?", [rowid])
                }
                try run("DELETE FROM entries WHERE id = ?", [id])
                try run("DELETE FROM images WHERE id = ?", [id])
                if let tombstone {
                    try run("INSERT OR REPLACE INTO tombstones (id, at) VALUES (?, ?)", [id, tombstone.timeIntervalSinceReferenceDate])
                }
            }
        }
    }

    public func image(_ id: UUID) -> Data? {
        (try? rows("SELECT png FROM images WHERE id = ?", [id.uuidString]) { Self.blob($0, 0) })?.first
    }

    /// The IDs of entries matching every word of `query`, newest first. Words of three or
    /// more letters go through the index; shorter ones are checked on what it returns.
    public func search(_ query: String) -> [UUID] {
        let terms = HistoryQuery.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else {
            return (try? rows("SELECT id FROM entries ORDER BY date DESC") { UUID(uuidString: Self.text($0, 0)) })?.compactMap { $0 } ?? []
        }
        let indexable = terms.filter { $0.count >= 3 }
        let short = terms.filter { $0.count < 3 }
        let candidates: [HistoryEntry]
        if indexable.isEmpty {
            candidates = allEntries()
        } else {
            let match = indexable.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND ")
            candidates = (try? rows("""
                SELECT e.meta FROM entry_text t JOIN entries e ON e.rowid = t.rowid
                WHERE entry_text MATCH ? ORDER BY e.date DESC
                """, [match]) { Self.decode($0, 0) })?.compactMap { $0 } ?? []
        }
        guard !short.isEmpty else { return candidates.map(\.id) }
        return candidates.filter { HistoryQuery.matches($0, terms: short) }.map(\.id)
    }

    // MARK: Tombstones

    public func tombstone(_ id: UUID) -> Date? {
        (try? rows("SELECT at FROM tombstones WHERE id = ?", [id.uuidString]) { Date(timeIntervalSinceReferenceDate: sqlite3_column_double($0, 0)) })?.first
    }

    public func tombstones() -> [(UUID, Date)] {
        (try? rows("SELECT id, at FROM tombstones") { stmt -> (UUID, Date)? in
            guard let id = UUID(uuidString: Self.text(stmt, 0)) else { return nil }
            return (id, Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1)))
        })?.compactMap { $0 } ?? []
    }

    public func removeTombstone(_ id: UUID) throws {
        try run("DELETE FROM tombstones WHERE id = ?", [id.uuidString])
    }

    // MARK: Synced files already read

    public func seenFiles() -> [String: Date] {
        var out: [String: Date] = [:]
        _ = try? rows("SELECT name, mtime FROM seen_files") { stmt in
            out[Self.text(stmt, 0)] = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
        }
        return out
    }

    public func setSeen(_ files: [String: Date?]) throws {
        try transaction {
            for (name, mtime) in files {
                if let mtime {
                    try run("INSERT OR REPLACE INTO seen_files (name, mtime) VALUES (?, ?)", [name, mtime.timeIntervalSinceReferenceDate])
                } else {
                    try run("DELETE FROM seen_files WHERE name = ?", [name])
                }
            }
        }
    }

    public func forgetSeenFiles() throws { try run("DELETE FROM seen_files") }

    // MARK: Key-value

    public func data(forKey key: String) -> Data? {
        (try? rows("SELECT value FROM kv WHERE key = ?", [key]) { Self.blob($0, 0) })?.first
    }

    public func set(_ data: Data?, forKey key: String) throws {
        if let data {
            try run("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, data])
        } else {
            try run("DELETE FROM kv WHERE key = ?", [key])
        }
    }

    public func string(forKey key: String) -> String? { data(forKey: key).flatMap { String(data: $0, encoding: .utf8) } }
    public func set(_ string: String?, forKey key: String) throws { try set(string.map { Data($0.utf8) }, forKey: key) }

    // MARK: SQLite plumbing

    public func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        let nested = sqlite3_get_autocommit(db) == 0
        if nested { return try body() }
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw DatabaseError("Database error: \(message)")
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError("Database error: \(String(cString: sqlite3_errmsg(db)))")
        }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, index)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), Self.transient) }
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    func run(_ sql: String, _ args: [Any?] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError("Database error: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func rows<T>(_ sql: String, _ args: [Any?] = [], _ map: (OpaquePointer?) -> T) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(map(stmt)) }
        return out
    }

    func scalarInt(_ sql: String, _ args: [Any?] = []) throws -> Int? {
        try rows(sql, args) { sqlite3_column_type($0, 0) == SQLITE_NULL ? nil : Int(sqlite3_column_int64($0, 0)) }.first ?? nil
    }

    static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    static func blob(_ stmt: OpaquePointer?, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, column))
        guard count > 0, let pointer = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        return encoder
    }()

    static func decode(_ stmt: OpaquePointer?, _ column: Int32) -> HistoryEntry? {
        try? JSONDecoder().decode(HistoryEntry.self, from: blob(stmt, column))
    }
}

/// One capture as it travels through iCloud Drive (sealed with the sync key), or the
/// record that it was deleted.
public struct SyncedCapture: Codable, Equatable, Sendable {
    public var version = 1
    public var id: UUID
    public var modified: Date
    public var entry: HistoryEntry?
    public var png: Data?

    public var isDeletion: Bool { entry == nil }

    public init(entry: HistoryEntry, png: Data?) {
        id = entry.id
        modified = entry.lastModified
        self.entry = entry
        self.png = png
    }

    public init(deleted id: UUID, at date: Date) {
        self.id = id
        modified = date
    }

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SyncedCapture {
        try PropertyListDecoder().decode(SyncedCapture.self, from: data)
    }

    /// Whether this copy should replace what a Mac has: newer wins; on a tie a deletion wins,
    /// so a delete and a pin at the same second can't bring an entry back.
    public static func wins(_ incoming: Date, incomingIsDeletion: Bool, over local: Date?, localIsDeletion: Bool) -> Bool {
        guard let local else { return true }
        if incoming != local { return incoming > local }
        return incomingIsDeletion && !localIsDeletion
    }
}
