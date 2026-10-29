import Foundation
import SQLite3

/// Connection lifetime belongs to the acquisition worker. The journal stores
/// sanitized hierarchy, pending/completed payloads and paged placement records.
/// Each tile commits small rows, never a growing whole-capture JSON document.
final class EarthAcquisitionIndex
{
    struct Payload
    {
        let bytes: Int
        let hash: String
        let validatedRun: Int
        let completed: Bool
    }

    let files: EarthAcquisitionFiles
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directoryURL: URL, creating request: EarthDownloadRequest?, readOnly: Bool = false) throws
    {
        guard directoryURL.isFileURL else { throw EarthAcquisitionError.invalidArchive }
        files = EarthAcquisitionFiles(directoryURL: directoryURL.standardizedFileURL)
        if let request
        {
            guard !FileManager.default.fileExists(atPath: directoryURL.path) else { throw EarthAcquisitionError.invalidArchive }
            do
            {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
                for child in ["tiles", "metadata", "staging"]
                { try FileManager.default.createDirectory(at: directoryURL.appendingPathComponent(child), withIntermediateDirectories: false) }
            }
            catch { throw EarthAcquisitionError.storage }
            try connect(readOnly: false, create: true)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE job (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, request TEXT NOT NULL, state TEXT NOT NULL, run INTEGER NOT NULL DEFAULT 0, requests INTEGER NOT NULL DEFAULT 0, issue TEXT)")
            try execute("CREATE TABLE metadata (id TEXT PRIMARY KEY, hash TEXT NOT NULL)")
            try execute("CREATE TABLE payloads (id TEXT PRIMARY KEY, bytes INTEGER NOT NULL DEFAULT 0, hash TEXT NOT NULL DEFAULT '', completed INTEGER NOT NULL DEFAULT 0, validated_run INTEGER NOT NULL DEFAULT 0)")
            try execute("CREATE TABLE placements (run INTEGER NOT NULL, ordinal INTEGER NOT NULL, tile TEXT NOT NULL, PRIMARY KEY(run,ordinal))")
            let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            try statement("INSERT INTO job(id,version,request,state) VALUES(1,1,?,'paused')")
            { query in try bind(encoded, query, 1); try done(query) }
        }
        else
        {
            guard let values = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true
            else { throw EarthAcquisitionError.invalidArchive }
            _ = try files.checked("acquisition.sqlite", regularFile: true)
            try connect(readOnly: readOnly, create: false)
            _ = try snapshot()
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func begin(request: EarthDownloadRequest) throws -> Int
    {
        guard try snapshot().request == request else { throw EarthAcquisitionError.invalidArchive }
        try execute("BEGIN IMMEDIATE")
        do
        {
            try execute("DELETE FROM placements")
            try execute("UPDATE job SET run=run+1,state='downloading',issue=NULL WHERE id=1")
            let run = try scalar("SELECT run FROM job WHERE id=1")
            try execute("COMMIT")
            return run
        }
        catch { try? execute("ROLLBACK"); throw error }
    }

    func snapshot() throws -> EarthSourceArchive
    {
        try statement("SELECT version,request,state,requests,issue,run FROM job WHERE id=1")
        { query in
            guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_int(query, 0) == 1,
                  let state = EarthSourceArchive.State(rawValue: string(query, 2)),
                  let data = string(query, 1).data(using: .utf8),
                  let request = try? JSONDecoder().decode(EarthDownloadRequest.self, from: data)
            else { throw EarthAcquisitionError.invalidArchive }
            let count = try scalar("SELECT COUNT(*) FROM payloads WHERE completed=1")
            let bytes = try scalar("SELECT COALESCE(SUM(bytes),0) FROM payloads WHERE completed=1")
            let placements = try scalar("SELECT COUNT(*) FROM placements WHERE run=(SELECT run FROM job WHERE id=1)")
            if state == .downloaded { _ = try files.checked("tileset.json", regularFile: true) }
            return EarthSourceArchive(
                directoryURL: files.directoryURL,
                request: request,
                state: state,
                completedPayloadCount: count,
                selectedTileCount: placements,
                sourceRequests: Int(sqlite3_column_int64(query, 3)),
                downloadedBytes: bytes,
                interruptionReason: sqlite3_column_type(query, 4) == SQLITE_NULL ? nil : string(query, 4)
            )
        }
    }

    func requestStarted() throws { try execute("UPDATE job SET requests=requests+1 WHERE id=1") }

    func registerMetadata(id: String, data: Data) throws
    {
        let hash = EarthSourceAccess.digest(data)
        let previous: String? = try statement("SELECT hash FROM metadata WHERE id=?")
        { query in try bind(id, query, 1); return sqlite3_step(query) == SQLITE_ROW ? string(query, 0) : nil }
        if let previous
        {
            guard previous == hash else { throw EarthAcquisitionError.sourceChanged }
            // A crash before the first file publication can be repaired here.
        }
        else
        {
            try statement("INSERT INTO metadata(id,hash) VALUES(?,?)")
            { query in try bind(id, query, 1); try bind(hash, query, 2); try done(query) }
        }
        try files.write(data, to: "metadata/\(id).json")
    }

    func payload(_ id: String) throws -> Payload?
    {
        try statement("SELECT bytes,hash,validated_run,completed FROM payloads WHERE id=?")
        { query in
            try bind(id, query, 1)
            guard sqlite3_step(query) == SQLITE_ROW else { return nil }
            return Payload(bytes: Int(sqlite3_column_int64(query, 0)), hash: string(query, 1), validatedRun: Int(sqlite3_column_int64(query, 2)), completed: sqlite3_column_int(query, 3) == 1)
        }
    }

    func pending(_ id: String) throws
    {
        try statement("INSERT INTO payloads(id) VALUES(?) ON CONFLICT(id) DO UPDATE SET completed=0,validated_run=0")
        { query in try bind(id, query, 1); try done(query) }
    }

    func stage(_ id: String, bytes: Int, hash: String) throws
    {
        try statement("UPDATE payloads SET bytes=?,hash=? WHERE id=?")
        { query in try bind(bytes, query, 1); try bind(hash, query, 2); try bind(id, query, 3); try done(query) }
    }

    func complete(_ id: String, run: Int) throws
    {
        try statement("UPDATE payloads SET completed=1,validated_run=? WHERE id=?")
        { query in try bind(run, query, 1); try bind(id, query, 2); try done(query) }
    }

    func place(tile: EarthTileset.Tile, run: Int, ordinal: Int) throws
    {
        let data = try JSONEncoder().encode(tile)
        try statement("INSERT INTO placements(run,ordinal,tile) VALUES(?,?,?)")
        { query in try bind(run, query, 1); try bind(ordinal, query, 2); try bind(String(decoding: data, as: UTF8.self), query, 3); try done(query) }
    }

    func forEachPlacement(_ visit: (Data) throws -> Void) throws
    {
        try statement("SELECT tile FROM placements WHERE run=(SELECT run FROM job WHERE id=1) ORDER BY ordinal")
        { query in
            while true
            {
                let result = sqlite3_step(query)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw EarthAcquisitionError.storage }
                try visit(Data(string(query, 0).utf8))
            }
        }
    }

    func finish(state: EarthSourceArchive.State, issue: String? = nil) throws
    {
        try statement("UPDATE job SET state=?,issue=? WHERE id=1")
        { query in
            try bind(state.rawValue, query, 1)
            if let issue { try bind(issue, query, 2) } else { sqlite3_bind_null(query, 2) }
            try done(query)
        }
    }

    private func connect(readOnly: Bool, create: Bool) throws
    {
        for path in ["acquisition.sqlite", "acquisition.sqlite-wal", "acquisition.sqlite-shm"] { _ = try files.checked(path) }
        var connection: OpaquePointer?
        let path = try files.checked("acquisition.sqlite")
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path.path, &connection, flags, nil) == SQLITE_OK, let connection
        else
        {
            if let connection { sqlite3_close(connection) }
            throw EarthAcquisitionError.storage
        }
        handle = connection
        sqlite3_busy_timeout(connection, 2000)
        if !readOnly { try execute("PRAGMA synchronous=FULL") }
    }

    private func scalar(_ sql: String) throws -> Int
    {
        try statement(sql)
        { query in
            guard sqlite3_step(query) == SQLITE_ROW else { throw EarthAcquisitionError.storage }
            return Int(sqlite3_column_int64(query, 0))
        }
    }

    private func execute(_ sql: String) throws
    { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw EarthAcquisitionError.storage } }

    private func statement<T>(_ sql: String, _ operation: (OpaquePointer) throws -> T) throws -> T
    {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK, let query
        else
        {
            if let query { sqlite3_finalize(query) }
            throw EarthAcquisitionError.storage
        }
        defer { sqlite3_finalize(query) }
        return try operation(query)
    }

    private func string(_ query: OpaquePointer, _ column: Int32) -> String
    { sqlite3_column_text(query, column).map { String(cString: $0) } ?? "" }

    private func done(_ query: OpaquePointer) throws
    { guard sqlite3_step(query) == SQLITE_DONE else { throw EarthAcquisitionError.storage } }

    private func bind(_ value: String, _ query: OpaquePointer, _ index: Int32) throws
    { guard sqlite3_bind_text(query, index, value, -1, Self.transient) == SQLITE_OK else { throw EarthAcquisitionError.storage } }

    private func bind(_ value: Int, _ query: OpaquePointer, _ index: Int32) throws
    { guard sqlite3_bind_int64(query, index, Int64(value)) == SQLITE_OK else { throw EarthAcquisitionError.storage } }
}
