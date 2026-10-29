import Foundation
import SQLite3

struct EarthPreparedAsset
{
    let id: String
    let bytes: Int
    let hash: String
    let estimate: EarthCaptureGeometryEstimate
}

struct EarthPreparationUnit
{
    let ordinal: Int
    let tile: EarthTileset.Tile
    let asset: EarthPreparedAsset
}

/// A worker-local connection. Planning rows, spatial sorting and the model
/// catalog stay on disk; public callers receive bounded pages of immutable values.
final class EarthPreparationIndex
{
    let files: EarthAcquisitionFiles
    private var handle: OpaquePointer?
    private var hasStoredModelCount = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directoryURL: URL, profile: EarthPreparationProfile? = nil, origin: EarthGeographicOrigin? = nil, sourceIdentifier: String? = nil, coversEntireSource: Bool = true) throws
    {
        guard directoryURL.isFileURL else { throw EarthPreparationError.invalidCollection }
        files = EarthAcquisitionFiles(directoryURL: directoryURL.standardizedFileURL)
        let creating = profile != nil
        if creating
        {
            guard !FileManager.default.fileExists(atPath: directoryURL.path), origin != nil, sourceIdentifier != nil else { throw EarthPreparationError.invalidCollection }
            do
            {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
                for path in ["models", "staging", "derived"] { try FileManager.default.createDirectory(at: directoryURL.appendingPathComponent(path), withIntermediateDirectories: false) }
            }
            catch { throw EarthPreparationError.storage }
        }
        else
        {
            guard let values = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { throw EarthPreparationError.invalidCollection }
            do { _ = try files.checked("preparation.sqlite", regularFile: true) }
            catch { throw EarthPreparationError.invalidCollection }
        }
        for path in ["preparation.sqlite", "preparation.sqlite-wal", "preparation.sqlite-shm"] { _ = try files.checked(path) }
        var database: OpaquePointer?
        let flags = (creating ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(directoryURL.appendingPathComponent("preparation.sqlite").path, &database, flags, nil) == SQLITE_OK, let database
        else
        {
            if let database { sqlite3_close(database) }
            throw EarthPreparationError.storage
        }
        handle = database
        sqlite3_busy_timeout(database, 2000)
        if let profile, let origin, let sourceIdentifier
        {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE job (id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL,profile TEXT NOT NULL,origin TEXT NOT NULL,source_id TEXT NOT NULL,state TEXT NOT NULL,coverage INTEGER NOT NULL,issue TEXT,model_count INTEGER NOT NULL DEFAULT 0)")
            hasStoredModelCount = true
            try execute("CREATE TABLE assets (id TEXT PRIMARY KEY,bytes INTEGER NOT NULL,hash TEXT NOT NULL,estimate TEXT NOT NULL)")
            try execute("CREATE TABLE units (ordinal INTEGER PRIMARY KEY,asset TEXT NOT NULL,x REAL NOT NULL,z REAL NOT NULL,tile TEXT NOT NULL)")
            try execute("CREATE INDEX units_spatial ON units(x,z,ordinal)")
            try execute("CREATE TABLE models (id INTEGER PRIMARY KEY,tiles INTEGER NOT NULL,estimate TEXT NOT NULL,bytes INTEGER NOT NULL)")
            try execute("CREATE TABLE model_assets (model INTEGER NOT NULL,asset TEXT NOT NULL,PRIMARY KEY(model,asset))")
            try execute("CREATE TABLE derivatives (source TEXT NOT NULL,ordinal INTEGER NOT NULL,asset TEXT NOT NULL,PRIMARY KEY(source,ordinal))")
            try execute("CREATE INDEX derivatives_asset ON derivatives(asset)")
            try statement("INSERT INTO job(id,version,profile,origin,source_id,state,coverage,issue) VALUES(1,1,?,?,?,'preparing',?,NULL)")
            { query in
                try bind(encoded(profile), query, 1); try bind(encoded(origin), query, 2); try bind(sourceIdentifier, query, 3)
                try bind(coversEntireSource ? 1 : 0, query, 4); try done(query)
            }
        }
        else
        {
            // Earlier experimental catalogs remain read-only and readable.
            hasStoredModelCount = try statement("PRAGMA table_info(job)")
            { query in
                var found = false
                while try row(query) { if string(query, 1) == "model_count" { found = true } }
                return found
            }
            _ = try snapshot()
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func snapshot() throws -> EarthPreparedCollection
    {
        let count = hasStoredModelCount ? "model_count" : "(SELECT COUNT(*) FROM models)"
        return try statement("SELECT version,profile,origin,source_id,state,coverage,issue,\(count) FROM job WHERE id=1")
        { query in
            guard sqlite3_step(query) == SQLITE_ROW, sqlite3_column_int(query, 0) == 1,
                  let profile = try? JSONDecoder().decode(EarthPreparationProfile.self, from: Data(string(query, 1).utf8)),
                  let origin = try? JSONDecoder().decode(EarthGeographicOrigin.self, from: Data(string(query, 2).utf8)),
                  let state = EarthPreparedCollection.State(rawValue: string(query, 4))
            else { throw EarthPreparationError.invalidCollection }
            if state == .ready { _ = try files.checked("tileset.json", regularFile: true) }
            return EarthPreparedCollection(
                directoryURL: files.directoryURL,
                profile: profile,
                geographicOrigin: origin,
                sourceIdentifier: string(query, 3),
                state: state,
                modelCount: Int(sqlite3_column_int64(query, 7)),
                coversEntireSource: sqlite3_column_int(query, 5) == 1 && state == .ready,
                interruptionReason: sqlite3_column_type(query, 6) == SQLITE_NULL ? nil : string(query, 6)
            )
        }
    }

    func asset(id: String) throws -> EarthPreparedAsset?
    {
        try statement("SELECT id,bytes,hash,estimate FROM assets WHERE id=?")
        { query in try bind(id, query, 1); return sqlite3_step(query) == SQLITE_ROW ? try readAsset(query) : nil }
    }

    func addAsset(_ asset: EarthPreparedAsset) throws
    {
        try statement("INSERT OR IGNORE INTO assets VALUES(?,?,?,?)")
        { query in try bind(asset.id, query, 1); try bind(asset.bytes, query, 2); try bind(asset.hash, query, 3); try bind(estimateText(asset.estimate), query, 4); try done(query) }
    }

    func addUnit(_ unit: EarthPreparationUnit, east: Double, south: Double) throws
    {
        guard east.isFinite, south.isFinite else { throw EarthPreparationError.sourceChanged }
        try statement("INSERT INTO units VALUES(?,?,?,?,?)")
        { query in
            try bind(unit.ordinal, query, 1); try bind(unit.asset.id, query, 2)
            guard sqlite3_bind_double(query, 3, east) == SQLITE_OK, sqlite3_bind_double(query, 4, south) == SQLITE_OK else { throw EarthPreparationError.storage }
            try bind(encoded(unit.tile), query, 5); try done(query)
        }
    }

    func addDerivative(_ asset: EarthPreparedAsset, sourceID: String, ordinal: Int) throws
    {
        try addAsset(asset)
        try statement("INSERT INTO derivatives VALUES(?,?,?)")
        { query in try bind(sourceID, query, 1); try bind(ordinal, query, 2); try bind(asset.id, query, 3); try done(query) }
    }

    @discardableResult
    func forEachDerivative(sourceID: String, _ visit: (EarthPreparedAsset) throws -> Void) throws -> Int
    {
        try statement("SELECT a.id,a.bytes,a.hash,a.estimate FROM derivatives d JOIN assets a ON d.asset=a.id WHERE d.source=? ORDER BY d.ordinal")
        { query in
            try bind(sourceID, query, 1)
            var count = 0
            while try row(query) { try visit(readAsset(query)); count += 1 }
            return count
        }
    }

    func isDerivative(id: String) throws -> Bool
    {
        try statement("SELECT 1 FROM derivatives WHERE asset=? LIMIT 1")
        { query in try bind(id, query, 1); return try row(query) }
    }

    func forEachUnit(_ visit: (EarthPreparationUnit) throws -> Void) throws
    {
        try statement("SELECT a.id,a.bytes,a.hash,a.estimate,u.ordinal,u.tile FROM units u JOIN assets a ON u.asset=a.id ORDER BY u.x,u.z,u.ordinal")
        { query in
            while try row(query)
            {
                let asset = try readAsset(query)
                let tile = try JSONDecoder().decode(EarthTileset.Tile.self, from: Data(string(query, 5).utf8))
                try visit(EarthPreparationUnit(ordinal: Int(sqlite3_column_int64(query, 4)), tile: tile, asset: asset))
            }
        }
    }

    func commitModel(id: Int, tileCount: Int, estimate: EarthCaptureGeometryEstimate, bytes: Int, assets: [EarthPreparedAsset]) throws
    {
        try execute("BEGIN IMMEDIATE")
        do
        {
            try statement("INSERT INTO models VALUES(?,?,?,?)")
            { query in try bind(id, query, 1); try bind(tileCount, query, 2); try bind(estimateText(estimate), query, 3); try bind(bytes, query, 4); try done(query) }
            for asset in assets
            {
                try addAsset(asset)
                try statement("INSERT INTO model_assets VALUES(?,?)")
                { query in try bind(id, query, 1); try bind(asset.id, query, 2); try done(query) }
            }
            try execute("UPDATE job SET model_count=model_count+1 WHERE id=1")
            try execute("COMMIT")
        }
        catch { try? execute("ROLLBACK"); throw error }
    }

    func models(offset: Int, limit: Int) throws -> [EarthPreparedModel]
    {
        try statement("SELECT id,tiles,estimate,bytes FROM models ORDER BY id LIMIT ? OFFSET ?")
        { query in
            try bind(limit, query, 1); try bind(offset, query, 2)
            var result: [EarthPreparedModel] = []
            while try row(query) { result.append(try readModel(query)) }
            return result
        }
    }

    func model(id: Int) throws -> EarthPreparedModel
    {
        try statement("SELECT id,tiles,estimate,bytes FROM models WHERE id=?")
        { query in try bind(id, query, 1); guard try row(query) else { throw EarthPreparationError.invalidCollection }; return try readModel(query) }
    }

    func forEachModel(_ visit: (EarthPreparedModel) throws -> Void) throws
    {
        try statement("SELECT id,tiles,estimate,bytes FROM models ORDER BY id")
        { query in while try row(query) { try visit(readModel(query)) } }
    }

    func forEachAsset(modelID: Int, _ visit: (EarthPreparedAsset) throws -> Void) throws
    {
        try statement("SELECT a.id,a.bytes,a.hash,a.estimate FROM model_assets m JOIN assets a ON m.asset=a.id WHERE m.model=? ORDER BY a.id")
        { query in try bind(modelID, query, 1); while try row(query) { try visit(readAsset(query)) } }
    }

    func validate(_ selection: EarthModelSelection) throws -> Int
    {
        let count = try selection.count(modelCount: snapshot().modelCount)
        let ids: Set<Int>
        switch selection { case let .all(excluding): ids = excluding; case let .only(selected): ids = selected }
        for id in ids
        {
            let exists = try statement("SELECT id FROM models WHERE id=?") { query in try bind(id, query, 1); return try row(query) }
            guard exists else { throw EarthPreparationError.invalidCollection }
        }
        return count
    }

    func finish(_ state: EarthPreparedCollection.State, issue: String? = nil) throws
    {
        try statement("UPDATE job SET state=?,issue=? WHERE id=1")
        { query in
            try bind(state.rawValue, query, 1)
            if let issue { try bind(issue, query, 2) } else { sqlite3_bind_null(query, 2) }
            try done(query)
        }
    }

    private func readAsset(_ query: OpaquePointer) throws -> EarthPreparedAsset
    { try EarthPreparedAsset(id: string(query, 0), bytes: Int(sqlite3_column_int64(query, 1)), hash: string(query, 2), estimate: readEstimate(query, 3)) }

    private func readModel(_ query: OpaquePointer) throws -> EarthPreparedModel
    {
        let id = Int(sqlite3_column_int64(query, 0))
        guard id > 0 else { throw EarthPreparationError.invalidCollection }
        let root = try files.checked("models/model-\(id)/tileset.json", regularFile: true)
        return try EarthPreparedModel(id: id, tileCount: Int(sqlite3_column_int64(query, 1)), estimate: readEstimate(query, 2), sourceByteCount: Int(sqlite3_column_int64(query, 3)), rootSourceURL: root)
    }

    private func estimateText(_ value: EarthCaptureGeometryEstimate) throws -> String
    { try encoded([value.vertexCount, value.indexCount, value.decodedTextureBytes, value.largestTextureDimension]) }

    private func readEstimate(_ query: OpaquePointer, _ column: Int32) throws -> EarthCaptureGeometryEstimate
    {
        let values = try JSONDecoder().decode([Int].self, from: Data(string(query, column).utf8))
        guard values.count == 4, values.allSatisfy({ $0 >= 0 }) else { throw EarthPreparationError.invalidCollection }
        return try EarthCaptureGeometryEstimate(vertices: values[0], indices: values[1], textureBytes: values[2], textureDimension: values[3])
    }

    private func encoded(_ value: some Encodable) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    private func string(_ query: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(query, column).map { String(cString: $0) } ?? "" }
    private func execute(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw EarthPreparationError.storage } }
    private func row(_ query: OpaquePointer) throws -> Bool
    {
        let value = sqlite3_step(query)
        guard value == SQLITE_ROW || value == SQLITE_DONE else { throw EarthPreparationError.storage }
        return value == SQLITE_ROW
    }

    private func done(_ query: OpaquePointer) throws { guard sqlite3_step(query) == SQLITE_DONE else { throw EarthPreparationError.storage } }
    private func bind(_ value: String, _ query: OpaquePointer, _ column: Int32) throws { guard sqlite3_bind_text(query, column, value, -1, Self.transient) == SQLITE_OK else { throw EarthPreparationError.storage } }
    private func bind(_ value: Int, _ query: OpaquePointer, _ column: Int32) throws { guard sqlite3_bind_int64(query, column, Int64(value)) == SQLITE_OK else { throw EarthPreparationError.storage } }
    private func statement<T>(_ sql: String, _ visit: (OpaquePointer) throws -> T) throws -> T
    {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK, let query
        else
        {
            if let query { sqlite3_finalize(query) }
            throw EarthPreparationError.storage
        }
        defer { sqlite3_finalize(query) }
        return try visit(query)
    }
}
