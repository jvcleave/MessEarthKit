import Foundation
import SQLite3

/// The host owns this local file's location and retention. All database access
/// is serialized here; native SQLite objects never leave the actor's ownership.
public actor EarthRequestUsageStore
{
    static let window: TimeInterval = 30 * 24 * 60 * 60
    private let fileURL: URL
    private let now: @Sendable () -> Date
    private var database: EarthUsageDatabase?
    private var missedEventAt: Date?

    public init(fileURL: URL)
    {
        self.fileURL = fileURL
        now = { Date() }
    }

    init(fileURL: URL, now: @escaping @Sendable () -> Date)
    {
        self.fileURL = fileURL
        self.now = now
    }

    /// Storage trouble is reported by the next snapshot, never thrown back into
    /// the source job. Completion only updates an existing, uncleared attempt.
    public func record(_ event: EarthRequestEvent)
    {
        do { try connection().record(event, cutoff: now().addingTimeInterval(-Self.window)) }
        catch { missedEventAt = missedEventAt ?? now(); database = nil }
    }

    public func snapshot() -> EarthRequestUsageSnapshot
    {
        let date = now()
        do { return try connection().snapshot(at: date) }
        catch { database = nil; return .unavailable(at: date) }
    }

    /// Atomic reset of request statistics only. Late completions have no row to
    /// update; a new attempt in the same source job is counted normally.
    public func clear() -> EarthRequestUsageSnapshot
    {
        let date = now()
        do
        {
            let connection = try connection()
            try connection.clear(at: date)
            missedEventAt = nil
            return try connection.snapshot(at: date)
        }
        catch { database = nil; return .unavailable(at: date) }
    }

    private func connection() throws -> EarthUsageDatabase
    {
        if database == nil { database = try EarthUsageDatabase(fileURL: fileURL, createdAt: now()) }
        guard let database else { throw EarthUsageDatabase.Failure.storage }
        if let missedEventAt
        {
            try database.markIncomplete(at: missedEventAt)
            self.missedEventAt = nil
        }
        return database
    }
}

/// Private connection lifetime, used only through EarthRequestUsageStore. Its
/// destructor closes SQLite without requiring an actor-isolated deinitializer.
private final class EarthUsageDatabase
{
    enum Failure: Error { case storage }
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileURL: URL, createdAt: Date) throws
    {
        guard fileURL.isFileURL else { throw Failure.storage }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(fileURL.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let connection
        else
        {
            if let connection { sqlite3_close(connection) }
            throw Failure.storage
        }
        handle = connection
        do
        {
            sqlite3_busy_timeout(handle, 2000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS usage_metadata (key TEXT PRIMARY KEY, value REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS request_attempts (id TEXT PRIMARY KEY, kind TEXT NOT NULL, started REAL NOT NULL, outcome TEXT, finished REAL, status INTEGER, bytes INTEGER)")
            try execute("CREATE INDEX IF NOT EXISTS request_attempts_started ON request_attempts(started)")
            try statement("INSERT OR IGNORE INTO usage_metadata(key,value) VALUES('trackingStartedAt',?)")
            { query in try bind(createdAt.timeIntervalSince1970, to: query, at: 1); try done(query) }
        }
        catch { sqlite3_close(handle); handle = nil; throw error }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func markIncomplete(at date: Date) throws
    {
        try statement("INSERT OR IGNORE INTO usage_metadata(key,value) VALUES('incompleteSince',?)")
        { query in try bind(date.timeIntervalSince1970, to: query, at: 1); try done(query) }
    }

    func setMetadata(_ key: String, date: Date) throws
    {
        try statement("INSERT OR REPLACE INTO usage_metadata(key,value) VALUES(?,?)")
        { query in try bind(key, to: query, at: 1); try bind(date.timeIntervalSince1970, to: query, at: 2); try done(query) }
    }

    func record(_ event: EarthRequestEvent, cutoff: Date) throws
    {
        switch event
        {
            case let .started(id, kind, at):
                guard at.timeIntervalSince1970.isFinite else { throw Failure.storage }
                guard at > cutoff else { return }
                try statement("INSERT OR IGNORE INTO request_attempts(id,kind,started) SELECT ?,?,? WHERE ? >= COALESCE((SELECT value FROM usage_metadata WHERE key='lastClearedAt'),-1.0e30)")
                { query in
                    try bind(id.uuidString, to: query, at: 1)
                    try bind(kind.rawValue, to: query, at: 2)
                    try bind(at.timeIntervalSince1970, to: query, at: 3)
                    try bind(at.timeIntervalSince1970, to: query, at: 4)
                    try done(query)
                }
            case let .finished(id, outcome, at, status, bytes):
                guard at.timeIntervalSince1970.isFinite, bytes.map({ $0 >= 0 }) != false else { throw Failure.storage }
                try statement("UPDATE request_attempts SET outcome=?,finished=?,status=?,bytes=? WHERE id=? AND outcome IS NULL")
                { query in
                    try bind(outcome.rawValue, to: query, at: 1)
                    try bind(at.timeIntervalSince1970, to: query, at: 2)
                    if let status { try bind(status, to: query, at: 3) }
                    if let bytes { try bind(bytes, to: query, at: 4) }
                    try bind(id.uuidString, to: query, at: 5)
                    try done(query)
                }
        }
    }

    func clear(at date: Date) throws
    {
        try execute("BEGIN IMMEDIATE")
        do
        {
            try execute("DELETE FROM request_attempts")
            try execute("DELETE FROM usage_metadata WHERE key='incompleteSince'")
            try setMetadata("trackingStartedAt", date: date)
            try setMetadata("lastClearedAt", date: date)
            try execute("COMMIT")
        }
        catch { try? execute("ROLLBACK"); throw error }
    }

    func snapshot(at date: Date) throws -> EarthRequestUsageSnapshot
    {
        try execute("BEGIN IMMEDIATE")
        do
        {
            let result = try readSnapshot(at: date)
            try execute("COMMIT")
            return result
        }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func readSnapshot(at date: Date) throws -> EarthRequestUsageSnapshot
    {
        let cutoff = date.addingTimeInterval(-EarthRequestUsageStore.window)
        try statement("DELETE FROM request_attempts WHERE started <= ?")
        { query in try bind(cutoff.timeIntervalSince1970, to: query, at: 1); try done(query) }
        var metadata: [String: Date] = [:]
        try statement("SELECT key,value FROM usage_metadata")
        { query in
            while true
            {
                let result = sqlite3_step(query)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW, let key = sqlite3_column_text(query, 0) else { throw Failure.storage }
                let value = sqlite3_column_double(query, 1)
                guard value.isFinite else { throw Failure.storage }
                metadata[String(cString: key)] = Date(timeIntervalSince1970: value)
            }
        }
        var counts = Array(repeating: 0, count: 7)
        var nextExpiration: Date?
        try statement(
            "SELECT COUNT(*),COALESCE(SUM(kind='session'),0),COALESCE(SUM(kind='metadata'),0),COALESCE(SUM(kind='tile'),0),COALESCE(SUM(outcome='succeeded'),0),COALESCE(SUM(outcome='failed'),0),COALESCE(SUM(outcome='cancelled'),0),MIN(started) FROM request_attempts WHERE started>? AND started<=?"
        )
        { query in
            try bind(cutoff.timeIntervalSince1970, to: query, at: 1)
            try bind(date.timeIntervalSince1970, to: query, at: 2)
            guard sqlite3_step(query) == SQLITE_ROW else { throw Failure.storage }
            for index in counts.indices { counts[index] = Int(sqlite3_column_int64(query, Int32(index))) }
            if sqlite3_column_type(query, 7) != SQLITE_NULL
            { nextExpiration = Date(timeIntervalSince1970: sqlite3_column_double(query, 7) + EarthRequestUsageStore.window) }
        }
        return EarthRequestUsageSnapshot(
            asOf: date,
            trackingStartedAt: metadata["trackingStartedAt"],
            lastClearedAt: metadata["lastClearedAt"],
            totalRequests: counts[0],
            sessionRequests: counts[1],
            metadataRequests: counts[2],
            tileRequests: counts[3],
            succeededRequests: counts[4],
            failedRequests: counts[5],
            cancelledRequests: counts[6],
            pendingRequests: counts[0] - counts[4] - counts[5] - counts[6],
            nextExpiration: nextExpiration,
            trackingIssue: metadata["incompleteSince"] == nil ? nil : "Some request history could not be recorded. Counts are incomplete since the last clear."
        )
    }

    private func execute(_ sql: String) throws
    {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.storage }
    }

    private func statement<T>(_ sql: String, _ operation: (OpaquePointer) throws -> T) throws -> T
    {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK, let query
        else
        {
            if let query { sqlite3_finalize(query) }
            throw Failure.storage
        }
        defer { sqlite3_finalize(query) }
        return try operation(query)
    }

    private func done(_ query: OpaquePointer) throws
    {
        guard sqlite3_step(query) == SQLITE_DONE else { throw Failure.storage }
    }

    private func bind(_ value: String, to query: OpaquePointer, at index: Int32) throws
    {
        guard sqlite3_bind_text(query, index, value, -1, Self.transient) == SQLITE_OK else { throw Failure.storage }
    }

    private func bind(_ value: Double, to query: OpaquePointer, at index: Int32) throws
    {
        guard sqlite3_bind_double(query, index, value) == SQLITE_OK else { throw Failure.storage }
    }

    private func bind(_ value: Int, to query: OpaquePointer, at index: Int32) throws
    {
        guard sqlite3_bind_int64(query, index, Int64(value)) == SQLITE_OK else { throw Failure.storage }
    }
}
