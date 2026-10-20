import Foundation

/// The app's own catalogue. A single actor owns the SQLite connection so all access is serialised.
public actor Database {
    public static let schemaVersion = 1

    private let conn: SQLiteConnection
    public let url: URL

    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Backup HQ", isDirectory: true)
        let old = base.appendingPathComponent("Silas Photos", isDirectory: true)   // the folder's name before the app was renamed
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.sqlite")
    }

    public init(url: URL) throws {
        self.url = url
        conn = try SQLiteConnection(path: url.path)
        try conn.execute("PRAGMA journal_mode=WAL")
        try conn.execute("PRAGMA synchronous=NORMAL")
        try conn.execute("PRAGMA foreign_keys=ON")
        try Self.migrate(conn)
    }

    private static func migrate(_ conn: SQLiteConnection) throws {
        let v = try conn.scalarInt("PRAGMA user_version")
        if v < 1 {
            try conn.execute("""
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS content(
                sha256 TEXT PRIMARY KEY, size INTEGER NOT NULL, kind TEXT NOT NULL, content_type TEXT,
                display_name TEXT NOT NULL, capture_date TEXT, capture_day TEXT, width INTEGER, height INTEGER,
                first_seen REAL NOT NULL, updated REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS content_capture_day ON content(capture_day);
            CREATE TABLE IF NOT EXISTS cloud_assets(
                asset_id TEXT PRIMARY KEY, sha256 TEXT NOT NULL, file_name TEXT NOT NULL, file_size INTEGER NOT NULL,
                content_type TEXT, subtype TEXT NOT NULL, capture_date TEXT, will_not_upload_master INTEGER NOT NULL DEFAULT 0,
                deleted INTEGER NOT NULL DEFAULT 0, rating INTEGER, user_created TEXT, user_updated TEXT,
                metadata_json BLOB, synced_at REAL NOT NULL);
            CREATE INDEX IF NOT EXISTS cloud_assets_sha ON cloud_assets(sha256);
            CREATE INDEX IF NOT EXISTS cloud_assets_deleted ON cloud_assets(deleted, will_not_upload_master);
            CREATE TABLE IF NOT EXISTS locations(
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, name TEXT NOT NULL,
                root_path TEXT, volume_uuid TEXT,
                s3_region TEXT, s3_bucket TEXT, s3_prefix TEXT, s3_storage_class TEXT, s3_profile TEXT,
                enabled INTEGER NOT NULL DEFAULT 1, is_primary INTEGER NOT NULL DEFAULT 0, auto_upload INTEGER NOT NULL DEFAULT 1,
                created REAL NOT NULL, last_verified REAL);
            CREATE TABLE IF NOT EXISTS copies(
                id INTEGER PRIMARY KEY AUTOINCREMENT, sha256 TEXT NOT NULL, location_id INTEGER NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
                path TEXT NOT NULL, size INTEGER, status TEXT NOT NULL, etag TEXT, storage_class TEXT,
                verified_at REAL, created REAL NOT NULL, UNIQUE(location_id, path));
            CREATE INDEX IF NOT EXISTS copies_sha ON copies(sha256);
            CREATE INDEX IF NOT EXISTS copies_loc_status ON copies(location_id, status);
            CREATE TABLE IF NOT EXISTS seen_files(
                location_id INTEGER NOT NULL REFERENCES locations(id) ON DELETE CASCADE, path TEXT NOT NULL,
                size INTEGER NOT NULL, mtime REAL NOT NULL, sha256 TEXT, PRIMARY KEY(location_id, path));
            CREATE TABLE IF NOT EXISTS jobs(
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, state TEXT NOT NULL,
                sha256 TEXT, source_path TEXT, source_location_id INTEGER, target_location_id INTEGER, copy_id INTEGER,
                priority INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0, error TEXT,
                bytes_total INTEGER NOT NULL DEFAULT 0, bytes_done INTEGER NOT NULL DEFAULT 0, resume_json TEXT,
                created REAL NOT NULL, updated REAL NOT NULL, started REAL, finished REAL);
            CREATE INDEX IF NOT EXISTS jobs_state ON jobs(state, kind, priority DESC, id);
            CREATE INDEX IF NOT EXISTS jobs_sha ON jobs(sha256, kind, state);
            CREATE INDEX IF NOT EXISTS jobs_target ON jobs(target_location_id, kind, state);
            CREATE TABLE IF NOT EXISTS events(
                id INTEGER PRIMARY KEY AUTOINCREMENT, time REAL NOT NULL, level TEXT NOT NULL, message TEXT NOT NULL,
                sha256 TEXT, job_id INTEGER);
            CREATE INDEX IF NOT EXISTS events_time ON events(time DESC);
            PRAGMA user_version = 1;
            """)
        }
        if v < 2 {
            // Roles and per-folder targets (the backup control-centre model).
            try conn.execute("""
            ALTER TABLE locations ADD COLUMN role TEXT NOT NULL DEFAULT 'tracked';
            ALTER TABLE locations ADD COLUMN targets TEXT NOT NULL DEFAULT '[]';
            ALTER TABLE locations ADD COLUMN last_scanned REAL;
            UPDATE locations SET role='library' WHERE kind='local' AND is_primary=1;
            UPDATE locations SET role='archive' WHERE kind='s3';
            UPDATE locations SET role='source' WHERE kind='source';
            UPDATE locations SET role='adobe' WHERE kind='adobe';
            """)
            // Previously every S3 location with auto-upload received everything; keep that for the existing library only.
            let s3ids = try conn.query("SELECT id FROM locations WHERE kind='s3' AND enabled=1 AND auto_upload=1").compactMap { $0.int("id") }
            if !s3ids.isEmpty {
                try conn.run("UPDATE locations SET targets=? WHERE role='library'", [.text("[" + s3ids.map(String.init).joined(separator: ",") + "]")])
            }
            try conn.execute("PRAGMA user_version = 2")
        }
        if v < 3 {
            // Hourly snapshots of how much is protected, for the timeline.
            try conn.execute("""
            CREATE TABLE IF NOT EXISTS coverage_snapshots(time REAL PRIMARY KEY, tracked_bytes INTEGER NOT NULL, protected_bytes INTEGER NOT NULL,
                s3_bytes INTEGER NOT NULL, vulnerable_bytes INTEGER NOT NULL);
            PRAGMA user_version = 3;
            """)
        }
        if v < 4 {
            try conn.execute("""
            CREATE TABLE IF NOT EXISTS alerts(key TEXT PRIMARY KEY, severity TEXT NOT NULL, title TEXT NOT NULL, detail TEXT NOT NULL,
                location_id INTEGER, first_seen REAL NOT NULL, last_seen REAL NOT NULL, resolved_at REAL, acknowledged_at REAL);
            ALTER TABLE locations ADD COLUMN last_seen REAL;
            PRAGMA user_version = 4;
            """)
        }
        if v < 5 {
            try conn.execute("""
            CREATE INDEX IF NOT EXISTS jobs_source_path ON jobs(source_path, kind, state);
            CREATE INDEX IF NOT EXISTS jobs_src_target ON jobs(source_location_id, target_location_id, kind, state);
            PRAGMA user_version = 5;
            """)
        }
        if v < 6 {
            try conn.execute("ANALYZE; PRAGMA user_version = 6;")
        }
        if v < 8 {
            // Jobs that must wait (an S3 restore in progress) sleep until not_before.
            try conn.execute("ALTER TABLE jobs ADD COLUMN not_before REAL; PRAGMA user_version = 8;")
        }
        if v < 7 {
            // Per-folder S3 storage class, keyed by target id.
            try conn.execute("ALTER TABLE locations ADD COLUMN target_classes TEXT NOT NULL DEFAULT '{}'; PRAGMA user_version = 7;")
        }
        if v < 9 {
            // Change-journal cursor per folder (incremental scans) and indexes for the Activity screen.
            try conn.execute("""
            ALTER TABLE locations ADD COLUMN scan_cursor INTEGER;
            ALTER TABLE locations ADD COLUMN scan_device TEXT;
            CREATE INDEX IF NOT EXISTS jobs_state_updated ON jobs(state, updated DESC);
            CREATE INDEX IF NOT EXISTS events_level ON events(level, id DESC);
            PRAGMA user_version = 9;
            """)
        }
        if v < 10 {
            // Covering indexes so coverage sums never touch the copies rows themselves (seconds instead of minutes on a million copies).
            try conn.execute("""
            CREATE INDEX IF NOT EXISTS copies_sha_loc ON copies(sha256, location_id, status, size);
            CREATE INDEX IF NOT EXISTS copies_loc_status_sha ON copies(location_id, status, sha256, size);
            ANALYZE;
            PRAGMA user_version = 10;
            """)
        }
        if v < 11 {
            try conn.execute("""
            ALTER TABLE locations ADD COLUMN ignore_rules TEXT NOT NULL DEFAULT '[]';
            ALTER TABLE locations ADD COLUMN use_standard_ignores INTEGER NOT NULL DEFAULT 1;
            PRAGMA user_version = 11;
            """)
        }
        // Always make sure the virtual Adobe location exists.
        if try conn.scalarInt("SELECT count(*) FROM locations WHERE kind='adobe'") == 0 {
            try conn.run("INSERT INTO locations(kind,role,name,enabled,is_primary,auto_upload,created) VALUES('adobe','adobe','Adobe Lightroom cloud',1,0,0,?)", [.init(Date())])
        }
    }

    // MARK: Settings

    public func setting(_ key: String) -> String? {
        try? conn.scalarString("SELECT value FROM settings WHERE key=?", [.text(key)])
    }
    public func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try conn.run("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(value)])
        } else {
            try conn.run("DELETE FROM settings WHERE key=?", [.text(key)])
        }
    }

    // MARK: Content

    public func upsertContent(_ c: Content) throws {
        try conn.run("""
        INSERT INTO content(sha256,size,kind,content_type,display_name,capture_date,capture_day,width,height,first_seen,updated)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(sha256) DO UPDATE SET
            content_type=COALESCE(content.content_type, excluded.content_type),
            capture_date=COALESCE(content.capture_date, excluded.capture_date),
            capture_day=COALESCE(content.capture_day, excluded.capture_day),
            width=COALESCE(content.width, excluded.width), height=COALESCE(content.height, excluded.height),
            updated=excluded.updated
        """, [.text(c.sha256), .integer(c.size), .text(c.kind.rawValue), .init(c.contentType), .text(c.displayName),
              .init(c.captureDate), .init(c.captureDay), .init(c.width), .init(c.height), .init(c.firstSeen), .init(Date())])
    }

    public func content(sha256: String) throws -> Content? {
        try conn.query("SELECT * FROM content WHERE sha256=?", [.text(sha256)]).first.map(Self.content(from:))
    }

    private static func content(from r: SQLiteConnection.Row) -> Content {
        Content(sha256: r.string("sha256") ?? "", size: r.int("size") ?? 0,
                kind: ContentKind(rawValue: r.string("kind") ?? "other") ?? .other,
                contentType: r.string("content_type"), displayName: r.string("display_name") ?? "",
                captureDate: r.string("capture_date"), captureDay: r.string("capture_day"),
                width: r.int("width").map(Int.init), height: r.int("height").map(Int.init),
                firstSeen: r.date("first_seen") ?? Date())
    }

    /// Content rows for browsing: by day, newest first, paged.
    public func contentList(day: String? = nil, year: String? = nil, search: String? = nil, limit: Int = 500, offset: Int = 0) throws -> [Content] {
        var sql = "SELECT * FROM content WHERE 1=1"
        var params: [SQLiteConnection.Value] = []
        if let day { sql += " AND capture_day=?"; params.append(.text(day)) }
        if let year { sql += " AND capture_day LIKE ?"; params.append(.text(year + "-%")) }
        if let search, !search.isEmpty { sql += " AND (display_name LIKE ? OR sha256 LIKE ?)"; params.append(.text("%\(search)%")); params.append(.text(search + "%")) }
        sql += " ORDER BY capture_date DESC, display_name LIMIT ? OFFSET ?"
        params.append(.integer(Int64(limit))); params.append(.integer(Int64(offset)))
        return try conn.query(sql, params).map(Self.content(from:))
    }

    public struct DayBucket: Identifiable, Hashable, Sendable {
        public var id: String { day }
        public var day: String
        public var count: Int
        public var bytes: Int64
    }

    public func contentDays(year: String? = nil) throws -> [DayBucket] {
        var sql = "SELECT COALESCE(capture_day,'unknown') AS d, count(*) AS n, sum(size) AS b FROM content"
        var params: [SQLiteConnection.Value] = []
        if let year { sql += " WHERE capture_day LIKE ?"; params.append(.text(year + "-%")) }
        sql += " GROUP BY d ORDER BY d DESC"
        return try conn.query(sql, params).map { DayBucket(day: $0.string("d") ?? "unknown", count: Int($0.int("n") ?? 0), bytes: $0.int("b") ?? 0) }
    }

    public func contentYears() throws -> [DayBucket] {
        try conn.query("SELECT COALESCE(substr(capture_day,1,4),'unknown') AS d, count(*) AS n, sum(size) AS b FROM content GROUP BY d ORDER BY d DESC")
            .map { DayBucket(day: $0.string("d") ?? "unknown", count: Int($0.int("n") ?? 0), bytes: $0.int("b") ?? 0) }
    }

    // MARK: Cloud assets

    public func upsertCloudAssets(_ assets: [(CloudAsset, Data?)]) throws {
        let now = Date()
        try conn.transaction {
            for (a, meta) in assets {
                try conn.run("""
                INSERT INTO cloud_assets(asset_id,sha256,file_name,file_size,content_type,subtype,capture_date,will_not_upload_master,deleted,rating,user_created,user_updated,metadata_json,synced_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(asset_id) DO UPDATE SET sha256=excluded.sha256, file_name=excluded.file_name, file_size=excluded.file_size,
                    content_type=excluded.content_type, subtype=excluded.subtype, capture_date=excluded.capture_date,
                    will_not_upload_master=excluded.will_not_upload_master, deleted=excluded.deleted, rating=excluded.rating,
                    user_created=excluded.user_created, user_updated=excluded.user_updated,
                    metadata_json=COALESCE(excluded.metadata_json, cloud_assets.metadata_json), synced_at=excluded.synced_at
                """, [.text(a.assetId), .text(a.sha256), .text(a.fileName), .integer(a.fileSize), .init(a.contentType), .text(a.subtype),
                      .init(a.captureDate), .init(a.willNotUploadMaster), .init(a.deleted), .init(a.rating), .init(a.userCreated), .init(a.userUpdated),
                      .init(meta), .init(now)])
            }
        }
    }

    public func cloudAssets(sha256: String) throws -> [CloudAsset] {
        try conn.query("SELECT * FROM cloud_assets WHERE sha256=? ORDER BY deleted, file_name", [.text(sha256)]).map(Self.cloudAsset(from:))
    }

    public func cloudAsset(id: String) throws -> CloudAsset? {
        try conn.query("SELECT * FROM cloud_assets WHERE asset_id=?", [.text(id)]).first.map(Self.cloudAsset(from:))
    }

    public func cloudAssetMetadataJSON(id: String) throws -> Data? {
        try conn.query("SELECT metadata_json FROM cloud_assets WHERE asset_id=?", [.text(id)]).first?.blob("metadata_json")
    }

    private static func cloudAsset(from r: SQLiteConnection.Row) -> CloudAsset {
        CloudAsset(assetId: r.string("asset_id") ?? "", sha256: r.string("sha256") ?? "", fileName: r.string("file_name") ?? "",
                   fileSize: r.int("file_size") ?? 0, contentType: r.string("content_type"), subtype: r.string("subtype") ?? "",
                   captureDate: r.string("capture_date"), willNotUploadMaster: r.bool("will_not_upload_master"),
                   deleted: r.bool("deleted"), rating: r.int("rating").map(Int.init),
                   userCreated: r.string("user_created"), userUpdated: r.string("user_updated"))
    }

    /// Live (non-deleted) cloud assets that we do not yet hold in any protective location, paged.
    public func cloudAssetsMissingLocally(limit: Int = 500, offset: Int = 0, neverUploadedOnly: Bool = false) throws -> [CloudAsset] {
        var sql = """
        SELECT ca.* FROM cloud_assets ca WHERE ca.deleted=0
          AND NOT EXISTS (SELECT 1 FROM copies c WHERE c.sha256=ca.sha256 AND c.status='verified'
                          AND c.location_id IN (SELECT id FROM locations WHERE kind IN ('local','s3')))
        """
        if neverUploadedOnly { sql += " AND ca.will_not_upload_master=1" }
        sql += " ORDER BY ca.capture_date DESC LIMIT ? OFFSET ?"
        return try conn.query(sql, [.integer(Int64(limit)), .integer(Int64(offset))]).map(Self.cloudAsset(from:))
    }

    // MARK: Locations

    public func locations() throws -> [Location] {
        try conn.query("SELECT * FROM locations ORDER BY CASE kind WHEN 'local' THEN 0 WHEN 's3' THEN 1 WHEN 'adobe' THEN 2 ELSE 3 END, id").map(Self.location(from:))
    }

    public func location(id: Int64) throws -> Location? {
        try conn.query("SELECT * FROM locations WHERE id=?", [.integer(id)]).first.map(Self.location(from:))
    }

    public func adobeLocation() throws -> Location {
        try conn.query("SELECT * FROM locations WHERE kind='adobe' LIMIT 1").first.map(Self.location(from:))!
    }

    @discardableResult
    public func addLocation(kind: LocationKind, role: LocationRole? = nil, name: String, rootPath: String? = nil, volumeUUID: String? = nil,
                            s3Region: String? = nil, s3Bucket: String? = nil, s3Prefix: String? = nil,
                            s3StorageClass: String? = nil, s3Profile: String? = nil, isPrimary: Bool = false, autoUpload: Bool = true,
                            targets: [Int64] = []) throws -> Location {
        let role = role ?? Self.defaultRole(kind: kind, isPrimary: isPrimary)
        if isPrimary { try conn.run("UPDATE locations SET is_primary=0") }
        if role == .tracked || role == .library {
            // Two owners with the same name would collide inside mirrors and S3 prefixes.
            if try conn.scalarInt("SELECT count(*) FROM locations WHERE role IN ('tracked','library') AND lower(name)=lower(?)", [.text(name)]) > 0 {
                throw DatabaseError.duplicateName(name)
            }
        }
        try conn.run("""
        INSERT INTO locations(kind,role,name,root_path,volume_uuid,s3_region,s3_bucket,s3_prefix,s3_storage_class,s3_profile,enabled,is_primary,auto_upload,targets,created)
        VALUES(?,?,?,?,?,?,?,?,?,?,1,?,?,?,?)
        """, [.text(kind.rawValue), .text(role.rawValue), .text(name), .init(rootPath), .init(volumeUUID), .init(s3Region), .init(s3Bucket), .init(s3Prefix),
              .init(s3StorageClass), .init(s3Profile), .init(isPrimary), .init(autoUpload), .text(Self.encodeTargets(targets)), .init(Date())])
        return try location(id: conn.lastInsertRowID)!
    }

    static func defaultRole(kind: LocationKind, isPrimary: Bool) -> LocationRole {
        switch kind {
        case .local: return isPrimary ? .library : .tracked
        case .s3: return .archive
        case .source: return .source
        case .adobe: return .adobe
        }
    }

    static func encodeTargets(_ t: [Int64]) -> String { "[" + t.map(String.init).joined(separator: ",") + "]" }
    static func decodeTargets(_ s: String?) -> [Int64] {
        guard let s else { return [] }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func encodeClasses(_ c: [Int64: String]) -> String {
        let dict = Dictionary(uniqueKeysWithValues: c.map { (String($0.key), $0.value) })
        return (try? JSONSerialization.data(withJSONObject: dict)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    static func decodeClasses(_ s: String?) -> [Int64: String] {
        guard let s, let data = s.data(using: .utf8), let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return [:] }
        var out: [Int64: String] = [:]
        for (k, v) in dict { if let id = Int64(k) { out[id] = v } }
        return out
    }

    /// Chooses the S3 storage class uploads from this folder use for one target. nil goes back to the target's own class.
    public func setStorageClass(locationId: Int64, targetId: Int64, storageClass: String?) throws {
        guard var loc = try location(id: locationId) else { return }
        loc.storageClasses[targetId] = storageClass
        try conn.run("UPDATE locations SET target_classes=? WHERE id=?", [.text(Self.encodeClasses(loc.storageClasses)), .integer(locationId)])
    }

    public func updateLocation(_ l: Location) throws {
        if l.isPrimary { try conn.run("UPDATE locations SET is_primary=0 WHERE id<>?", [.integer(l.id)]) }
        try conn.run("""
        UPDATE locations SET name=?, role=?, root_path=?, volume_uuid=?, s3_region=?, s3_bucket=?, s3_prefix=?, s3_storage_class=?, s3_profile=?,
            enabled=?, is_primary=?, auto_upload=?, targets=?, target_classes=?, last_verified=?, ignore_rules=?, use_standard_ignores=? WHERE id=?
        """, [.text(l.name), .text(l.role.rawValue), .init(l.rootPath), .init(l.volumeUUID), .init(l.s3Region), .init(l.s3Bucket), .init(l.s3Prefix), .init(l.s3StorageClass),
              .init(l.s3Profile), .init(l.enabled), .init(l.isPrimary), .init(l.autoUpload), .text(Self.encodeTargets(l.targets)), .text(Self.encodeClasses(l.storageClasses)), .init(l.lastVerified),
              .text(Self.encodeStrings(l.ignoreRules)), .init(l.useStandardIgnores), .integer(l.id)])
    }

    /// Sets which mirror/archive locations a folder should also exist in. Validates that each target can receive copies.
    public func setTargets(locationId: Int64, targets: [Int64]) throws {
        // A place that has since been forgotten is simply dropped; only an existing non-target is an error.
        var kept: [Int64] = []
        for t in targets {
            guard let loc = try location(id: t) else { continue }
            guard loc.isTarget else { throw DatabaseError.invalidTarget(t) }
            kept.append(t)
        }
        let targets = kept
        let before = try location(id: locationId)?.targets ?? []
        try conn.run("UPDATE locations SET targets=? WHERE id=?", [.text(Self.encodeTargets(Array(Set(targets)).sorted())), .integer(locationId)])
        // Dropping a target cancels the copies still waiting for it. Copies already made are left alone.
        for gone in Set(before).subtracting(targets) {
            try conn.run("DELETE FROM jobs WHERE source_location_id=? AND target_location_id=? AND kind IN ('upload','backup') AND state IN ('pending','paused','failed')", [.integer(locationId), .integer(gone)])
        }
    }

    public func markScanned(locationId: Int64) throws {
        try conn.run("UPDATE locations SET last_scanned=? WHERE id=?", [.init(Date()), .integer(locationId)])
    }

    /// Owners (library + tracked folders) that list this target.
    public func owners(ofTarget targetId: Int64) throws -> [Location] {
        try locations().filter { $0.isOwner && $0.targets.contains(targetId) }
    }

    public func deleteLocation(id: Int64) throws {
        try conn.transaction {
            try conn.run("DELETE FROM jobs WHERE target_location_id=? OR source_location_id=?", [.integer(id), .integer(id)])
            // No folder may keep pointing at a place that no longer exists.
            for owner in try locations() where owner.targets.contains(id) || owner.storageClasses[id] != nil {
                var o = owner
                o.targets.removeAll { $0 == id }
                o.storageClasses[id] = nil
                try conn.run("UPDATE locations SET targets=?, target_classes=? WHERE id=?", [.text(Self.encodeTargets(o.targets)), .text(Self.encodeClasses(o.storageClasses)), .integer(owner.id)])
            }
            try conn.run("DELETE FROM locations WHERE id=? AND kind<>'adobe'", [.integer(id)])
        }
    }

    private static func location(from r: SQLiteConnection.Row) -> Location {
        let kind = LocationKind(rawValue: r.string("kind") ?? "local") ?? .local
        let isPrimary = r.bool("is_primary")
        return Location(id: r.int("id") ?? 0, kind: kind,
                 role: r.string("role").flatMap(LocationRole.init(rawValue:)) ?? defaultRole(kind: kind, isPrimary: isPrimary), name: r.string("name") ?? "",
                 rootPath: r.string("root_path"), volumeUUID: r.string("volume_uuid"), s3Region: r.string("s3_region"), s3Bucket: r.string("s3_bucket"),
                 s3Prefix: r.string("s3_prefix"), s3StorageClass: r.string("s3_storage_class"), s3Profile: r.string("s3_profile"),
                 enabled: r.bool("enabled"), isPrimary: isPrimary, autoUpload: r.bool("auto_upload"), targets: decodeTargets(r.string("targets")),
                 storageClasses: decodeClasses(r.string("target_classes")), created: r.date("created") ?? Date(), lastVerified: r.date("last_verified"),
                 scanCursor: r.int("scan_cursor"), scanDevice: r.string("scan_device"),
                 ignoreRules: decodeStrings(r.string("ignore_rules")), useStandardIgnores: r["use_standard_ignores"] == .null ? true : r.bool("use_standard_ignores"))
    }

    private static func decodeStrings(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8), let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }
    private static func encodeStrings(_ v: [String]) -> String {
        (try? JSONEncoder().encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    public func setIgnoreRules(locationId: Int64, rules: [String], useStandard: Bool) throws {
        try conn.run("UPDATE locations SET ignore_rules=?, use_standard_ignores=? WHERE id=?", [.text(Self.encodeStrings(rules)), .init(useStandard), .integer(locationId)])
    }

    /// What a look decides for each copy row the folder holds.
    public enum CopyFate { case present, gone, ignored }

    /// After a look: rows for files no longer there are marked missing (their copies elsewhere are untouched); rows
    /// for files the folder's ignore rules now cover are dropped from this folder's inventory (again, copies elsewhere
    /// stay). Returns (gone, forgotten).
    public func reconcileCopies(locationId: Int64, judge: (String) -> CopyFate) throws -> (gone: Int, forgotten: Int) {
        var gone: [Int64] = [], forget: [(Int64, String)] = []
        try conn.query("SELECT id, path, status FROM copies WHERE location_id=?", [.integer(locationId)]) { r in
            guard let p = r.string("path"), let id = r.int("id") else { return }
            switch judge(p) {
            case .present: break
            case .gone: if r.string("status") != "missing" { gone.append(id) }
            case .ignored: forget.append((id, p))
            }
        }
        guard !gone.isEmpty || !forget.isEmpty else { return (0, 0) }
        // Short transactions, so the screen (which also writes small things) never waits long for the lock.
        for chunk in stride(from: 0, to: gone.count, by: 5000).map({ Array(gone[$0..<min($0 + 5000, gone.count)]) }) {
            try conn.transaction { for id in chunk { try conn.run("UPDATE copies SET status='missing' WHERE id=?", [.integer(id)]) } }
        }
        for chunk in stride(from: 0, to: forget.count, by: 5000).map({ Array(forget[$0..<min($0 + 5000, forget.count)]) }) {
            try conn.transaction {
                for (id, path) in chunk {
                    try conn.run("DELETE FROM copies WHERE id=?", [.integer(id)])
                    try conn.run("DELETE FROM seen_files WHERE location_id=? AND path=?", [.integer(locationId), .text(path)])
                }
            }
        }
        try conn.run("DELETE FROM seen_files WHERE location_id=? AND path NOT IN (SELECT path FROM copies WHERE location_id=? AND status<>'missing')", [.integer(locationId), .integer(locationId)])
        return (gone.count, forget.count)
    }

    /// Drops fingerprinting still queued for these files (indexed by source path).
    public func deletePendingHashJobs(locationId: Int64, paths: [String]) throws -> Int {
        var n = 0
        for chunk in stride(from: 0, to: paths.count, by: 2000).map({ Array(paths[$0..<min($0 + 2000, paths.count)]) }) {
            try conn.transaction {
                for p in chunk { n += try conn.run("DELETE FROM jobs WHERE kind='hash' AND state IN ('pending','paused') AND source_location_id=? AND source_path=?", [.integer(locationId), .text(p)]) }
            }
        }
        return n
    }

    /// The copy row at a path inside a location, if any.
    public func copy(locationId: Int64, path: String) throws -> Copy? {
        try conn.query("SELECT * FROM copies WHERE location_id=? AND path=? LIMIT 1", [.integer(locationId), .text(path)]).first.map(Self.copy(from:))
    }

    public func deleteSeenFile(locationId: Int64, path: String) throws {
        try conn.run("DELETE FROM seen_files WHERE location_id=? AND path=?", [.integer(locationId), .text(path)])
    }

    /// Fingerprint jobs still outstanding for a folder, not counting the one asking.
    public func outstandingHashCount(locationId: Int64, excluding jobId: Int64) throws -> Int {
        Int(try conn.scalarInt("SELECT count(*) FROM jobs WHERE kind='hash' AND state IN ('pending','running','paused') AND source_location_id=? AND id<>?", [.integer(locationId), .integer(jobId)]))
    }

    /// Absolute paths of files in a location still waiting to be fingerprinted.
    public func outstandingHashPaths(locationId: Int64) throws -> Set<String> {
        var out = Set<String>()
        try conn.query("SELECT source_path FROM jobs WHERE kind='hash' AND state IN ('pending','running','paused') AND source_location_id=?", [.integer(locationId)]) { r in
            if let p = r.string("source_path") { out.insert(p) }
        }
        return out
    }

    /// Jobs that were told to wait (a disk unplugged, an S3 restore) may try again now.
    @discardableResult
    public func unparkJobs() throws -> Int {
        try conn.run("UPDATE jobs SET not_before=NULL WHERE state='pending' AND not_before IS NOT NULL")
    }

    /// One scan per folder at a time. A full scan asked for while a lighter one is waiting upgrades it; while one is
    /// running, a full request queues behind it.
    public func addScanJob(locationId: Int64, path: String?, full: Bool, priority: Int = 10) throws -> Int64? {
        let fullJSON = "{\"full\":true}"
        if let existing = try conn.query("SELECT id, state, resume_json FROM jobs WHERE kind='scan' AND source_location_id=? AND state IN ('pending','running','paused') ORDER BY id DESC LIMIT 1", [.integer(locationId)]).first {
            let isFull = existing.string("resume_json") == fullJSON
            if !full || isFull { return existing.int("id") }
            if existing.string("state") != "running" { try conn.run("UPDATE jobs SET resume_json=? WHERE id=?", [.text(fullJSON), .init(existing.int("id"))]); return existing.int("id") }
        }
        let now = Date()
        try conn.run("INSERT INTO jobs(kind,state,source_path,source_location_id,priority,resume_json,created,updated) VALUES('scan','pending',?,?,?,?,?,?)",
                     [.init(path), .integer(locationId), .integer(Int64(priority)), full ? .text(fullJSON) : .null, .init(now), .init(now)])
        return conn.lastInsertRowID
    }

    public func setScanCursor(locationId: Int64, cursor: Int64?, device: String?) throws {
        try conn.run("UPDATE locations SET scan_cursor=?, scan_device=? WHERE id=?", [.init(cursor), .init(device), .integer(locationId)])
    }

    /// Folders due for an automatic look: owners and sources last scanned more than `interval` ago (or never).
    public func locationsDueForScan(interval: TimeInterval) throws -> [Location] {
        let cutoff = Date().addingTimeInterval(-interval)
        let due = Set(try conn.query("SELECT id FROM locations WHERE enabled=1 AND (last_scanned IS NULL OR last_scanned < ?)", [.init(cutoff)]).compactMap { $0.int("id") })
        return try locations().filter { due.contains($0.id) && ($0.isOwner || $0.role == .source) && $0.isReachable }
    }

    public func lastScanned(locationId: Int64) throws -> Date? {
        try conn.query("SELECT last_scanned FROM locations WHERE id=?", [.integer(locationId)]).first?.date("last_scanned")
    }

    // MARK: Copies

    @discardableResult
    public func upsertCopy(sha256: String, locationId: Int64, path: String, size: Int64?, status: CopyStatus, etag: String? = nil, storageClass: String? = nil) throws -> Copy {
        let now = Date()
        try conn.run("""
        INSERT INTO copies(sha256,location_id,path,size,status,etag,storage_class,verified_at,created) VALUES(?,?,?,?,?,?,?,?,?)
        ON CONFLICT(location_id,path) DO UPDATE SET sha256=excluded.sha256, size=excluded.size, status=excluded.status,
            etag=COALESCE(excluded.etag, copies.etag), storage_class=COALESCE(excluded.storage_class, copies.storage_class),
            verified_at=CASE WHEN excluded.status='verified' THEN excluded.verified_at ELSE copies.verified_at END
        """, [.text(sha256), .integer(locationId), .text(path), .init(size), .text(status.rawValue), .init(etag), .init(storageClass),
              .init(status == .verified ? now : nil), .init(now)])
        return try conn.query("SELECT * FROM copies WHERE location_id=? AND path=?", [.integer(locationId), .text(path)]).first.map(Self.copy(from:))!
    }

    public func setCopyStatus(id: Int64, _ status: CopyStatus) throws {
        try conn.run("UPDATE copies SET status=?, verified_at=CASE WHEN ?='verified' THEN ? ELSE verified_at END WHERE id=?",
                     [.text(status.rawValue), .text(status.rawValue), .init(Date()), .integer(id)])
    }

    public func deleteCopy(id: Int64) throws { try conn.run("DELETE FROM copies WHERE id=?", [.integer(id)]) }

    public func updateCopyPath(id: Int64, path: String) throws {
        try conn.run("DELETE FROM copies WHERE path=? AND location_id=(SELECT location_id FROM copies WHERE id=?) AND id<>?", [.text(path), .integer(id), .integer(id)])
        try conn.run("UPDATE copies SET path=? WHERE id=?", [.text(path), .integer(id)])
    }

    public func copies(sha256: String) throws -> [Copy] {
        try conn.query("SELECT * FROM copies WHERE sha256=? ORDER BY location_id", [.text(sha256)]).map(Self.copy(from:))
    }

    public func copy(id: Int64) throws -> Copy? {
        try conn.query("SELECT * FROM copies WHERE id=?", [.integer(id)]).first.map(Self.copy(from:))
    }

    public func copies(locationId: Int64, status: CopyStatus? = nil, limit: Int = 1000, offset: Int = 0) throws -> [Copy] {
        var sql = "SELECT * FROM copies WHERE location_id=?"
        var p: [SQLiteConnection.Value] = [.integer(locationId)]
        if let status { sql += " AND status=?"; p.append(.text(status.rawValue)) }
        sql += " ORDER BY id LIMIT ? OFFSET ?"; p.append(.integer(Int64(limit))); p.append(.integer(Int64(offset)))
        return try conn.query(sql, p).map(Self.copy(from:))
    }

    /// Verified copies at an S3 target, belonging to this folder, that are not yet in the wanted storage class.
    public func copiesToReclass(ownerId: Int64, targetId: Int64, storageClass: String, limit: Int = 100_000) throws -> [Copy] {
        try conn.query("""
            SELECT c.* FROM copies c WHERE c.location_id=? AND c.status='verified' AND COALESCE(c.storage_class,'') <> ?
              AND EXISTS (SELECT 1 FROM copies o WHERE o.sha256=c.sha256 AND o.location_id=?)
            ORDER BY c.id LIMIT ?
            """, [.integer(targetId), .text(storageClass), .integer(ownerId), .integer(Int64(limit))]).map(Self.copy(from:))
    }

    public func copyPaths(locationId: Int64) throws -> Set<String> {
        var s = Set<String>()
        try conn.query("SELECT path FROM copies WHERE location_id=?", [.integer(locationId)]) { if let p = $0.string("path") { s.insert(p) } }
        return s
    }

    /// Whether a verified copy of this content exists at the location.
    public func hasVerifiedCopy(sha256: String, locationId: Int64) throws -> Bool {
        try conn.scalarInt("SELECT count(*) FROM copies WHERE sha256=? AND location_id=? AND status='verified'", [.text(sha256), .integer(locationId)]) > 0
    }

    /// The copy row for this content at a location (verified first), if any.
    public func copy(sha256: String, locationId: Int64) throws -> Copy? {
        try conn.query("SELECT * FROM copies WHERE sha256=? AND location_id=? ORDER BY status='verified' DESC, id LIMIT 1", [.text(sha256), .integer(locationId)]).first.map(Self.copy(from:))
    }

    /// After a full scan: copies at this location whose path was not seen are gone from the folder.
    /// Their rows stay (status missing) so the dashboard can say "removed from the folder, N copies remain".
    public func markCopiesMissing(locationId: Int64, exceptPaths seen: Set<String>) throws -> Int {
        var gone: [Int64] = []
        try conn.query("SELECT id, path FROM copies WHERE location_id=? AND status<>'missing'", [.integer(locationId)]) { r in
            if let p = r.string("path"), !seen.contains(p), let id = r.int("id") { gone.append(id) }
        }
        try conn.transaction {
            for id in gone { try conn.run("UPDATE copies SET status='missing' WHERE id=?", [.integer(id)]) }
            try conn.run("DELETE FROM seen_files WHERE location_id=? AND path NOT IN (SELECT path FROM copies WHERE location_id=? AND status<>'missing')", [.integer(locationId), .integer(locationId)])
        }
        return gone.count
    }

    /// Verified files at an owner location that lack a verified copy at `target`, paged. Used by Backup Now.
    /// Owner copies that the target does not hold under the matching name: `<keyPrefix><path>` or, for a file whose
    /// name was taken by a different version, the hashed variant of that name. Byte-identical files under several
    /// names each count separately, so a mirror or archive ends up with every name the folder has.
    public func uncoveredCopies(ownerId: Int64, targetId: Int64, keyPrefix: String) throws -> [Copy] {
        let owned = try copies(locationId: ownerId, status: .verified, limit: 10_000_000)
        var held: [String: Set<String>] = [:]
        try conn.query("SELECT sha256, path FROM copies WHERE location_id=? AND status='verified'", [.integer(targetId)]) { r in
            if let sha = r.string("sha256"), let path = r.string("path") { held[sha, default: []].insert(path) }
        }
        return owned.filter { c in
            guard let paths = held[c.sha256] else { return true }
            let key = keyPrefix + c.path
            return !(paths.contains(key) || paths.contains(FileLayout.disambiguated(key, sha256: c.sha256)))
        }
    }

    public func copiesNotCoveredAt(ownerId: Int64, targetId: Int64, limit: Int = 2000, offset: Int = 0) throws -> [Copy] {
        try conn.query("""
        SELECT c.* FROM copies c WHERE c.location_id=? AND c.status='verified'
          AND NOT EXISTS (SELECT 1 FROM copies t WHERE t.sha256=c.sha256 AND t.location_id=? AND t.status='verified')
        ORDER BY c.id LIMIT ? OFFSET ?
        """, [.integer(ownerId), .integer(targetId), .integer(Int64(limit)), .integer(Int64(offset))]).map(Self.copy(from:))
    }

    /// Best local file to read this content from: a verified copy on a reachable local or source location.
    public func localFileURLs(sha256: String) throws -> [(Location, URL)] {
        var out: [(Location, URL)] = []
        for r in try conn.query("""
            SELECT c.path AS path, l.* FROM copies c JOIN locations l ON l.id=c.location_id
            WHERE c.sha256=? AND c.status IN ('verified','unverified') AND l.kind IN ('local','source')
            ORDER BY CASE l.kind WHEN 'local' THEN 0 ELSE 1 END, c.status='verified' DESC
            """, [.text(sha256)]) {
            let loc = Self.location(from: r)
            if let root = loc.reachableRootURL, let p = r.string("path") {
                out.append((loc, root.appendingPathComponent(p)))
            }
        }
        return out
    }

    private static func copy(from r: SQLiteConnection.Row) -> Copy {
        Copy(id: r.int("id") ?? 0, sha256: r.string("sha256") ?? "", locationId: r.int("location_id") ?? 0, path: r.string("path") ?? "",
             size: r.int("size"), status: CopyStatus(rawValue: r.string("status") ?? "unverified") ?? .unverified, etag: r.string("etag"),
             storageClass: r.string("storage_class"), verifiedAt: r.date("verified_at"), created: r.date("created") ?? Date())
    }

    // MARK: Seen files (rescan acceleration)

    public func seenFile(locationId: Int64, path: String) throws -> (size: Int64, mtime: Double, sha256: String?)? {
        guard let r = try conn.query("SELECT size, mtime, sha256 FROM seen_files WHERE location_id=? AND path=?", [.integer(locationId), .text(path)]).first else { return nil }
        return (r.int("size") ?? 0, r.double("mtime") ?? 0, r.string("sha256"))
    }

    public struct SeenFile: Sendable { public var size: Int64; public var mtime: Double; public var sha256: String? }

    /// Everything the last scans learned about a folder, in one go: path → (size, mtime, sha). Lets a scan compare in memory.
    public func seenFiles(locationId: Int64) throws -> [String: SeenFile] {
        var out: [String: SeenFile] = [:]
        try conn.query("SELECT path, size, mtime, sha256 FROM seen_files WHERE location_id=?", [.integer(locationId)]) { r in
            if let p = r.string("path") { out[p] = SeenFile(size: r.int("size") ?? 0, mtime: r.double("mtime") ?? 0, sha256: r.string("sha256")) }
        }
        return out
    }

    /// Queues fingerprinting for many files in one transaction, skipping any already waiting or running. Returns how many were added.
    public func addHashJobs(_ files: [(path: String, size: Int64)], locationId: Int64) throws -> Int {
        guard !files.isEmpty else { return 0 }
        var outstanding = Set<String>()
        try conn.query("SELECT source_path FROM jobs WHERE kind='hash' AND state IN ('pending','running','paused') AND source_location_id=?", [.integer(locationId)]) { r in
            if let p = r.string("source_path") { outstanding.insert(p) }
        }
        let now = Date()
        return try conn.transaction {
            var n = 0
            for f in files where !outstanding.contains(f.path) {
                try conn.run("INSERT INTO jobs(kind,state,source_path,source_location_id,priority,bytes_total,created,updated) VALUES('hash','pending',?,?,0,?,?,?)",
                             [.text(f.path), .integer(locationId), .integer(f.size), .init(now), .init(now)])
                n += 1
            }
            return n
        }
    }

    /// Copies marked missing earlier whose file is back under the same name and unchanged: mark them present again.
    public func reviveCopies(locationId: Int64, paths: Set<String>) throws -> Int {
        var ids: [Int64] = []
        try conn.query("SELECT id, path FROM copies WHERE location_id=? AND status='missing'", [.integer(locationId)]) { r in
            if let p = r.string("path"), paths.contains(p), let id = r.int("id") { ids.append(id) }
        }
        try conn.transaction { for id in ids { try conn.run("UPDATE copies SET status='verified' WHERE id=?", [.integer(id)]) } }
        return ids.count
    }

    /// Like markCopiesMissing, but the caller decides per path (used after a partial, journal-driven scan).
    public func markCopiesMissing(locationId: Int64, where isGone: (String) -> Bool) throws -> Int {
        var gone: [Int64] = []
        try conn.query("SELECT id, path FROM copies WHERE location_id=? AND status<>'missing'", [.integer(locationId)]) { r in
            if let p = r.string("path"), isGone(p), let id = r.int("id") { gone.append(id) }
        }
        guard !gone.isEmpty else { return 0 }
        try conn.transaction {
            for id in gone { try conn.run("UPDATE copies SET status='missing' WHERE id=?", [.integer(id)]) }
            try conn.run("DELETE FROM seen_files WHERE location_id=? AND path NOT IN (SELECT path FROM copies WHERE location_id=? AND status<>'missing')", [.integer(locationId), .integer(locationId)])
        }
        return gone.count
    }

    /// One job per content the owner holds that `target` does not, skipping content with work already outstanding. Set-based: a
    /// single query instead of one per file. `sourceRoot` is the owner's reachable root (for jobs that carry a file path).
    public func queueMissingCopies(ownerId: Int64, targetId: Int64, kind: JobKind, sourceRoot: URL?, priority: Int = 0) throws -> Int {
        let rows = try conn.query("""
        SELECT c.sha256 AS sha, max(c.size) AS size, min(c.path) AS path FROM copies c
        WHERE c.location_id=? AND c.status='verified'
          AND NOT EXISTS (SELECT 1 FROM copies t WHERE t.sha256=c.sha256 AND t.location_id=? AND t.status='verified')
          AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.sha256=c.sha256 AND j.target_location_id=? AND j.state IN ('pending','running','paused'))
        GROUP BY c.sha256
        """, [.integer(ownerId), .integer(targetId), .integer(targetId)])
        guard !rows.isEmpty else { return 0 }
        let now = Date()
        return try conn.transaction {
            var n = 0
            for r in rows {
                guard let sha = r.string("sha") else { continue }
                let path = kind == .upload ? nil : r.string("path").flatMap { sourceRoot?.appendingPathComponent($0).path }
                try conn.run("INSERT INTO jobs(kind,state,sha256,source_path,source_location_id,target_location_id,priority,bytes_total,created,updated) VALUES(?,'pending',?,?,?,?,?,?,?,?)",
                             [.text(kind.rawValue), .text(sha), .init(path), .integer(ownerId), .integer(targetId), .integer(Int64(priority)), .integer(r.int("size") ?? 0), .init(now), .init(now)])
                n += 1
            }
            return n
        }
    }

    public func recordSeenFile(locationId: Int64, path: String, size: Int64, mtime: Double, sha256: String?) throws {
        try conn.run("INSERT INTO seen_files(location_id,path,size,mtime,sha256) VALUES(?,?,?,?,?) ON CONFLICT(location_id,path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, sha256=excluded.sha256",
                     [.integer(locationId), .text(path), .integer(size), .real(mtime), .init(sha256)])
    }

    // MARK: Jobs

    @discardableResult
    public func addJob(kind: JobKind, sha256: String? = nil, sourcePath: String? = nil, sourceLocationId: Int64? = nil, targetLocationId: Int64? = nil,
                       copyId: Int64? = nil, priority: Int = 0, bytesTotal: Int64 = 0, dedupe: Bool = true) throws -> Int64? {
        if dedupe {
            // Don't queue the same work twice while it is still outstanding.
            var sql = "SELECT id FROM jobs WHERE kind=? AND state IN ('pending','running','paused')"
            var p: [SQLiteConnection.Value] = [.text(kind.rawValue)]
            if let sha256 { sql += " AND sha256=?"; p.append(.text(sha256)) } else { sql += " AND sha256 IS NULL" }
            if let sourcePath { sql += " AND source_path=?"; p.append(.text(sourcePath)) }
            if let targetLocationId { sql += " AND target_location_id=?"; p.append(.integer(targetLocationId)) } else if kind != .hash && kind != .scan { sql += " AND target_location_id IS NULL" }
            if let copyId { sql += " AND copy_id=?"; p.append(.integer(copyId)) }
            if let existing = try conn.query(sql + " LIMIT 1", p).first { return existing.int("id") }
        }
        let now = Date()
        try conn.run("""
        INSERT INTO jobs(kind,state,sha256,source_path,source_location_id,target_location_id,copy_id,priority,bytes_total,created,updated)
        VALUES(?,'pending',?,?,?,?,?,?,?,?,?)
        """, [.text(kind.rawValue), .init(sha256), .init(sourcePath), .init(sourceLocationId), .init(targetLocationId), .init(copyId),
              .integer(Int64(priority)), .integer(bytesTotal), .init(now), .init(now)])
        return conn.lastInsertRowID
    }

    /// Round-robin state per job kind: where the rotation got to, and the list of waiting queues (refreshed every few
    /// seconds — grouping a queue of hundreds of thousands of jobs costs ~0.2 s, far too much to do on every claim).
    private struct ClaimQueue { var source: Int64?; var target: Int64?; var priority: Int64 }
    private var claimCursor: [String: Int] = [:]
    private var claimQueues: [String: (at: Date, queues: [ClaimQueue])] = [:]
    /// Drops the cached queue list so the next claim looks again (tests; also harmless to call after a big enqueue).
    public func forgetClaimCache() { claimQueues.removeAll() }

    /// Atomically claims up to `limit` pending jobs of a kind, marking them running. Work is shared fairly between
    /// queues (one queue per folder → place pair at the highest waiting priority), so a small folder's few new files
    /// are not stuck behind a bulk copy of a huge one.
    public func claimJobs(kind: JobKind, limit: Int) throws -> [Job] {
        try conn.transaction {
            let now = Date()
            let ready = "kind=? AND state='pending' AND (not_before IS NULL OR not_before <= ?)"
            var queues: [ClaimQueue]
            if let c = claimQueues[kind.rawValue], now.timeIntervalSince(c.at) < 5 {
                queues = c.queues
            } else {
                queues = try conn.query("SELECT source_location_id AS s, target_location_id AS t, max(priority) AS p FROM jobs WHERE \(ready) GROUP BY 1, 2", [.text(kind.rawValue), .init(now)])
                    .map { ClaimQueue(source: $0.int("s"), target: $0.int("t"), priority: $0.int("p") ?? 0) }
                claimQueues[kind.rawValue] = (now, queues)
            }
            var rows: [SQLiteConnection.Row] = []
            if queues.count <= 1 {
                rows = try conn.query("SELECT * FROM jobs WHERE \(ready) ORDER BY priority DESC, id LIMIT ?", [.text(kind.rawValue), .init(now), .integer(Int64(limit))])
            } else {
                let top = queues.map(\.priority).max() ?? 0
                var eligible = queues.filter { $0.priority == top }
                var cursor = claimCursor[kind.rawValue] ?? 0
                var taken: [Int64] = []
                // Each turn either claims a row (bounded by limit) or drops a drained queue, so this ends.
                while rows.count < limit, !eligible.isEmpty {
                    let i = cursor % eligible.count; let q = eligible[i]; cursor += 1
                    let exclude = taken.isEmpty ? "0" : taken.map(String.init).joined(separator: ",")
                    let r = try conn.query("SELECT * FROM jobs WHERE \(ready) AND priority=? AND source_location_id IS ? AND target_location_id IS ? AND id NOT IN (\(exclude)) ORDER BY id LIMIT 1",
                                           [.text(kind.rawValue), .init(now), .integer(top), .init(q.source), .init(q.target)])
                    if let row = r.first, let id = row.int("id") { rows.append(row); taken.append(id) }
                    else { eligible.remove(at: i); claimQueues[kind.rawValue] = nil }   // queue drained: forget the cached list
                }
                claimCursor[kind.rawValue] = cursor
            }
            var jobs: [Job] = []
            for r in rows {
                var j = Self.job(from: r)
                try conn.run("UPDATE jobs SET state='running', started=?, updated=?, attempts=attempts+1 WHERE id=?", [.init(now), .init(now), .integer(j.id)])
                j.state = .running; j.started = now; j.attempts += 1
                jobs.append(j)
            }
            return jobs
        }
    }

    public func job(id: Int64) throws -> Job? {
        try conn.query("SELECT * FROM jobs WHERE id=?", [.integer(id)]).first.map(Self.job(from:))
    }

    public func finishJob(id: Int64, state: JobState, error: String? = nil, resumeJSON: String?? = nil, notBefore: Date? = nil) throws {
        let now = Date()
        var sql = "UPDATE jobs SET state=?, error=?, updated=?, finished=CASE WHEN ? IN ('done','failed') THEN ? ELSE NULL END, not_before=?"
        var p: [SQLiteConnection.Value] = [.text(state.rawValue), .init(error), .init(now), .text(state.rawValue), .init(now), .init(notBefore)]
        if let resumeJSON { sql += ", resume_json=?"; p.append(.init(resumeJSON)) }
        sql += " WHERE id=?"; p.append(.integer(id))
        try conn.run(sql, p)
    }

    public func updateJobProgress(id: Int64, bytesDone: Int64, bytesTotal: Int64? = nil, resumeJSON: String? = nil) throws {
        var sql = "UPDATE jobs SET bytes_done=?, updated=?"
        var p: [SQLiteConnection.Value] = [.integer(bytesDone), .init(Date())]
        if let bytesTotal { sql += ", bytes_total=?"; p.append(.integer(bytesTotal)) }
        if let resumeJSON { sql += ", resume_json=?"; p.append(.text(resumeJSON)) }
        sql += " WHERE id=?"; p.append(.integer(id))
        try conn.run(sql, p)
    }

    /// Called at launch and on pause: anything left 'running' goes back to the queue.
    public func requeueRunningJobs() throws -> Int {
        try conn.run("UPDATE jobs SET state='pending', updated=? WHERE state='running'", [.init(Date())])
    }

    /// Jobs whose source or target location no longer exists (folder removed while work was queued).
    @discardableResult
    public func deleteOrphanJobs() throws -> Int {
        try conn.run("""
        DELETE FROM jobs WHERE state IN ('pending','failed','paused')
          AND ((source_location_id IS NOT NULL AND source_location_id NOT IN (SELECT id FROM locations))
            OR (target_location_id IS NOT NULL AND target_location_id NOT IN (SELECT id FROM locations)))
        """)
    }

    /// Failures from before the engine learned that a vanished source file is not an error: put them back in the queue so
    /// the current rules settle them (skipped if the file is really gone, parked if its disk is just unplugged).
    @discardableResult
    public func requeueVanishedFailures() throws -> Int {
        try conn.run("UPDATE jobs SET state='pending', error=NULL, updated=? WHERE state='failed' AND error LIKE 'Source file is missing:%'", [.init(Date())])
    }

    public func retryFailedJobs(kind: JobKind? = nil) throws -> Int {
        if let kind { return try conn.run("UPDATE jobs SET state='pending', error=NULL, updated=? WHERE state='failed' AND kind=?", [.init(Date()), .text(kind.rawValue)]) }
        return try conn.run("UPDATE jobs SET state='pending', error=NULL, updated=? WHERE state='failed'", [.init(Date())])
    }

    public func retryJob(id: Int64) throws {
        try conn.run("UPDATE jobs SET state='pending', error=NULL, updated=? WHERE id=? AND state IN ('failed','paused')", [.init(Date()), .integer(id)])
    }

    public func clearDoneJobs(olderThan: TimeInterval = 0) throws -> Int {
        try conn.run("DELETE FROM jobs WHERE state='done' AND finished < ?", [.init(Date().addingTimeInterval(-olderThan))])
    }

    public func deleteJob(id: Int64) throws { try conn.run("DELETE FROM jobs WHERE id=? AND state<>'running'", [.integer(id)]) }

    public func jobs(state: JobState? = nil, kind: JobKind? = nil, limit: Int = 200) throws -> [Job] {
        var sql = "SELECT * FROM jobs WHERE 1=1"
        var p: [SQLiteConnection.Value] = []
        if let kind { sql += " AND kind=?"; p.append(.text(kind.rawValue)) }
        // Running first, then failed, waiting, finished. Each state is fetched by its own index so a queue of half a
        // million waiting jobs is never sorted just to show the first page.
        let order: [JobState] = state.map { [$0] } ?? [.running, .failed, .paused, .pending, .done]
        var out: [Job] = []
        for st in order where out.count < limit {
            var q = sql + " AND state=?"; var qp = p; qp.append(.text(st.rawValue))
            q += st == .pending ? " ORDER BY priority DESC, id LIMIT ?" : " ORDER BY updated DESC LIMIT ?"
            qp.append(.integer(Int64(limit - out.count)))
            out += try conn.query(q, qp).map(Self.job(from:))
        }
        return out
    }

    public func jobCounts() throws -> [JobKind: [JobState: Int]] {
        var out: [JobKind: [JobState: Int]] = [:]
        for r in try conn.query("SELECT kind, state, count(*) AS n FROM jobs GROUP BY kind, state") {
            guard let k = JobKind(rawValue: r.string("kind") ?? ""), let s = JobState(rawValue: r.string("state") ?? "") else { continue }
            out[k, default: [:]][s] = Int(r.int("n") ?? 0)
        }
        return out
    }

    private static func job(from r: SQLiteConnection.Row) -> Job {
        Job(id: r.int("id") ?? 0, kind: JobKind(rawValue: r.string("kind") ?? "hash") ?? .hash, state: JobState(rawValue: r.string("state") ?? "pending") ?? .pending,
            sha256: r.string("sha256"), sourcePath: r.string("source_path"), sourceLocationId: r.int("source_location_id"), targetLocationId: r.int("target_location_id"),
            copyId: r.int("copy_id"), priority: Int(r.int("priority") ?? 0), attempts: Int(r.int("attempts") ?? 0), error: r.string("error"),
            bytesTotal: r.int("bytes_total") ?? 0, bytesDone: r.int("bytes_done") ?? 0, resumeJSON: r.string("resume_json"),
            created: r.date("created") ?? Date(), updated: r.date("updated") ?? Date(), started: r.date("started"), finished: r.date("finished"))
    }

    // MARK: Events

    public func log(_ level: String, _ message: String, sha256: String? = nil, jobId: Int64? = nil) {
        _ = try? conn.run("INSERT INTO events(time,level,message,sha256,job_id) VALUES(?,?,?,?,?)", [.init(Date()), .text(level), .text(message), .init(sha256), .init(jobId)])
    }

    public func events(limit: Int = 300, level: String? = nil) throws -> [Event] {
        var sql = "SELECT * FROM events"
        var p: [SQLiteConnection.Value] = []
        if let level { sql += " WHERE level=?"; p.append(.text(level)) }
        sql += " ORDER BY id DESC LIMIT ?"; p.append(.integer(Int64(limit)))
        return try conn.query(sql, p).map { Event(id: $0.int("id") ?? 0, time: $0.date("time") ?? Date(), level: $0.string("level") ?? "", message: $0.string("message") ?? "", sha256: $0.string("sha256"), jobId: $0.int("job_id")) }
    }

    // MARK: Duplicates

    public struct DuplicateGroup: Identifiable, Hashable, Sendable {
        public var id: String { sha256 }
        public var sha256: String
        public var size: Int64
        public var names: [String]
        public var cloudAssetIds: [String]
        public var captureDate: String?
    }

    /// Content that appears more than once in Lightroom (same bytes, different asset ids / file names).
    public func duplicateGroups(limit: Int = 2000) throws -> [DuplicateGroup] {
        let rows = try conn.query("""
        SELECT sha256, file_size, group_concat(file_name, '\u{1F}') AS names, group_concat(asset_id, '\u{1F}') AS ids, min(capture_date) AS cd
        FROM cloud_assets WHERE deleted=0 GROUP BY sha256 HAVING count(*) > 1 ORDER BY file_size DESC LIMIT ?
        """, [.integer(Int64(limit))])
        return rows.map { r in
            DuplicateGroup(sha256: r.string("sha256") ?? "", size: r.int("file_size") ?? 0,
                           names: (r.string("names") ?? "").components(separatedBy: "\u{1F}"),
                           cloudAssetIds: (r.string("ids") ?? "").components(separatedBy: "\u{1F}"), captureDate: r.string("cd"))
        }
    }

    // MARK: Stats

    /// The expensive half of the picture (coverage sums over every copy), kept from one call to the next while
    /// nothing in the catalogue has changed, and refreshed at most every `maxAge` seconds while the engine is busy
    /// writing. The cheap, live half (queue, running jobs, free space) is read fresh every time.
    private struct HeavyStats { var stamp: String; var at: Date; var stats: CatalogStats }
    private var heavyStats: HeavyStats?

    public func stats(maxAge: TimeInterval = 30) throws -> CatalogStats {
        let allLocations = try locations()
        let stamp = conn.changeStamp
        var s: CatalogStats
        if let h = heavyStats, Date().timeIntervalSince(h.at) < (h.stamp == stamp ? 120 : maxAge) {
            s = h.stats
        } else {
            let t0 = Date()
            s = try heavyStatsPass(locations: allLocations)
            heavyStats = HeavyStats(stamp: stamp, at: Date(), stats: s)
            let took = Date().timeIntervalSince(t0)
            if took > 1 { Log.db.info("coverage summary recomputed in \(took, format: .fixed(precision: 2))s") }
        }
        s.generatedAt = Date()
        try refreshLiveParts(&s.folders)
        s.vulnerableCount = s.folders.reduce(0) { $0 + $1.vulnerableCount }
        s.vulnerableBytes = s.folders.reduce(0) { $0 + $1.vulnerableBytes }
        try recordSnapshotIfDue(stats: s)
        s.history = try snapshots(limit: 400)
        try noteSeenLocations(allLocations)
        s.alerts = try evaluateAlertsIfDue(stats: s, locations: allLocations)
        let names = Dictionary(uniqueKeysWithValues: allLocations.map { ($0.id, $0.name) })
        s.running = try conn.query("SELECT id, kind, source_path, sha256, target_location_id, bytes_done, bytes_total FROM jobs WHERE state='running' ORDER BY started LIMIT 12").map { r in
            let name = r.string("source_path").map { ($0 as NSString).lastPathComponent } ?? (r.string("sha256").map { String($0.prefix(12)) } ?? "")
            return RunningJob(id: r.int("id") ?? 0, kind: r.string("kind") ?? "", name: name, targetName: r.int("target_location_id").flatMap { names[$0] },
                              bytesDone: r.int("bytes_done") ?? 0, bytesTotal: r.int("bytes_total") ?? 0)
        }
        s.queue = try conn.query("""
            SELECT kind, target_location_id AS t, count(*) AS n, COALESCE(sum(max(0, bytes_total-bytes_done)),0) AS b
            FROM jobs WHERE state IN ('pending','paused') GROUP BY kind, target_location_id ORDER BY kind
            """).map { r in QueueLine(kind: r.string("kind") ?? "", targetId: r.int("t"), targetName: r.int("t").flatMap { names[$0] }, count: Int(r.int("n") ?? 0), bytes: r.int("b") ?? 0) }
        s.jobsPending = 0; s.jobsRunning = 0; s.jobsFailed = 0; s.jobsDone = 0
        for r in try conn.query("SELECT state, count(*) AS n FROM jobs GROUP BY state") {
            let n = Int(r.int("n") ?? 0)
            switch r.string("state") {
            case "pending", "paused": s.jobsPending += n
            case "running": s.jobsRunning += n
            case "failed": s.jobsFailed += n
            case "done": s.jobsDone += n
            default: break
            }
        }
        s.recentWork = try conn.query("SELECT kind, count(*) AS n, COALESCE(sum(bytes_total),0) AS b FROM jobs WHERE state='done' AND updated > ? AND error IS NULL GROUP BY kind",
                                      [.init(Date().addingTimeInterval(-86400))]).map { CatalogStats.RecentWork(kind: $0.string("kind") ?? "", count: Int($0.int("n") ?? 0), bytes: $0.int("b") ?? 0) }
        s.recentEvents = try conn.query("SELECT id, time, level, message FROM events WHERE message NOT LIKE 'Engine %' ORDER BY id DESC LIMIT 6").map {
            CatalogStats.RecentEvent(id: $0.int("id") ?? 0, time: $0.date("time") ?? Date(), level: $0.string("level") ?? "", message: $0.string("message") ?? "") }
        s.bytesPendingUpload = try conn.scalarInt("SELECT COALESCE(sum(max(0, bytes_total-bytes_done)),0) FROM jobs WHERE kind='upload' AND state IN ('pending','running','paused')")
        s.bytesPendingImport = try conn.scalarInt("SELECT COALESCE(sum(max(0, bytes_total-bytes_done)),0) FROM jobs WHERE kind='import' AND state IN ('pending','running','paused')")
        s.bytesPendingBackup = try conn.scalarInt("SELECT COALESCE(sum(max(0, bytes_total-bytes_done)),0) FROM jobs WHERE kind='backup' AND state IN ('pending','running','paused')")
        for i in s.perLocation.indices {
            let l = allLocations.first { $0.id == s.perLocation[i].id }
            s.perLocation[i].pendingJobs = Int(try conn.scalarInt("SELECT count(*) FROM jobs WHERE target_location_id=? AND state IN ('pending','running','paused')", [.integer(s.perLocation[i].id)]))
            if let l, l.rootPath != nil {
                let root = l.reachableRootURL
                s.perLocation[i].reachable = root != nil
                if let root, let vals = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let free = vals.volumeAvailableCapacityForImportantUsage {
                    s.perLocation[i].freeBytes = free
                }
            }
        }
        for i in s.places.indices {
            guard let l = allLocations.first(where: { $0.id == s.places[i].locationId }) else { continue }
            s.places[i].reachable = l.isReachable
            if let root = l.reachableRootURL, let vals = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) { s.places[i].freeBytes = vals.volumeAvailableCapacityForImportantUsage }
        }
        return s
    }

    /// Everything that needs a pass over the copies table.
    private func heavyStatsPass(locations allLocations: [Location]) throws -> CatalogStats {
        var s = CatalogStats()
        if let r = try conn.query("SELECT count(*) AS n, COALESCE(sum(size),0) AS b FROM content").first { s.contentCount = Int(r.int("n") ?? 0); s.contentBytes = r.int("b") ?? 0 }
        if let r = try conn.query("SELECT count(*) AS n, COALESCE(sum(file_size),0) AS b FROM cloud_assets WHERE deleted=0").first { s.cloudAssetCount = Int(r.int("n") ?? 0); s.cloudAssetBytes = r.int("b") ?? 0 }
        if let n = setting("lightroom.deletedCount").flatMap(Int.init) { s.cloudDeletedCount = n } else { s.cloudDeletedCount = Int(try conn.scalarInt("SELECT count(*) FROM cloud_assets WHERE deleted=1")) }
        if let r = try conn.query("SELECT count(*) AS n, COALESCE(sum(file_size),0) AS b FROM cloud_assets WHERE deleted=0 AND will_not_upload_master=1").first { s.cloudNeverUploadedCount = Int(r.int("n") ?? 0); s.cloudNeverUploadedBytes = r.int("b") ?? 0 }
        if let r = try conn.query("""
            SELECT count(*) AS n, COALESCE(sum(ca.file_size),0) AS b FROM cloud_assets ca WHERE ca.deleted=0 AND EXISTS
              (SELECT 1 FROM copies c WHERE c.sha256=ca.sha256 AND c.status='verified' AND c.location_id IN (SELECT id FROM locations WHERE kind IN ('local','s3')))
            """).first { s.cloudMatchedLocallyCount = Int(r.int("n") ?? 0); s.cloudMatchedLocallyBytes = r.int("b") ?? 0 }
        s.cloudOnlyCount = s.cloudAssetCount - s.cloudMatchedLocallyCount
        s.cloudOnlyBytes = s.cloudAssetBytes - s.cloudMatchedLocallyBytes

        // Content on exactly one local disk and nowhere else (Adobe counts as a place for live, uploaded assets).
        // Grouped over the covering index on copies, so the content rows are never read.
        s.singlePlaceLocalOnlyCount = Int(try conn.scalarInt("""
            SELECT count(*) FROM (
              SELECT c.sha256,
                     count(DISTINCT CASE WHEN l.kind IN ('local','s3') THEN l.id END) AS places,
                     count(DISTINCT CASE WHEN l.kind = 'local' THEN l.id END) AS local_places
              FROM copies c JOIN locations l ON l.id = c.location_id AND l.enabled = 1
              WHERE c.status = 'verified' GROUP BY c.sha256) x
            WHERE local_places = 1 AND places = 1
              AND NOT EXISTS (SELECT 1 FROM cloud_assets ca INDEXED BY cloud_assets_sha WHERE ca.sha256 = x.sha256 AND ca.deleted = 0 AND ca.will_not_upload_master = 0)
            """))

        s.folders = try folderCoverageHeavy(locations: allLocations)
        for f in s.folders where f.targets.isEmpty {
            s.singleCopyByChoiceCount += f.fileCount; s.singleCopyByChoiceBytes += f.bytes
        }
        s.places = try placeSummaries(locations: allLocations)

        if let r = try conn.query("SELECT count(*) AS g, COALESCE(sum(n-1),0) AS extra FROM (SELECT count(*) AS n FROM cloud_assets WHERE deleted=0 GROUP BY sha256 HAVING count(*)>1)").first {
            s.duplicateGroups = Int(r.int("g") ?? 0); s.duplicateExtraCount = Int(r.int("extra") ?? 0)
        }
        for l in allLocations where l.kind != .adobe {
            var ls = LocationStats(id: l.id, name: l.name, kind: l.kind.rawValue, role: l.role.rawValue, place: l.placeKind.rawValue, verifiedCount: 0, verifiedBytes: 0, unverifiedCount: 0, missingCount: 0, corruptCount: 0, pendingJobs: 0, freeBytes: nil, reachable: true)
            for r in try conn.query("SELECT status, count(*) AS n, COALESCE(sum(size),0) AS b FROM copies WHERE location_id=? GROUP BY status", [.integer(l.id)]) {
                let n = Int(r.int("n") ?? 0)
                switch r.string("status") {
                case "verified": ls.verifiedCount = n; ls.verifiedBytes = r.int("b") ?? 0
                case "unverified": ls.unverifiedCount = n
                case "missing": ls.missingCount = n
                case "corrupt": ls.corruptCount = n
                default: break
                }
            }
            s.perLocation.append(ls)
        }
        return s
    }

    // MARK: Coverage (the control-centre view)

    public func folderCoverage(locations: [Location]? = nil) throws -> [FolderCoverage] {
        var out = try folderCoverageHeavy(locations: locations)
        try refreshLiveParts(&out)
        return out
    }

    /// Per folder: how much it holds and how much of that each of its targets already has. Sums run over the
    /// covering indexes, never the copies rows. The live bits (what is queued or running) are added by refreshLiveParts.
    private func folderCoverageHeavy(locations: [Location]? = nil) throws -> [FolderCoverage] {
        let locs: [Location] = try locations ?? (try self.locations())
        let byId = Dictionary(uniqueKeysWithValues: locs.map { ($0.id, $0) })
        var out: [FolderCoverage] = []
        for owner in locs where owner.isOwner && owner.enabled {
            let targets = owner.targets.compactMap { byId[$0] }.filter { $0.isTarget && $0.enabled }
            var fc = FolderCoverage(id: owner.id, name: owner.name, role: owner.role.rawValue, place: owner.placeKind.rawValue, rootPath: owner.rootPath ?? "",
                                    reachable: owner.isReachable, fileCount: 0, bytes: 0, missingCount: 0, targets: [], vulnerableCount: 0, vulnerableBytes: 0,
                                    lastScanned: try lastScanned(locationId: owner.id))
            if let r = try conn.query("SELECT count(*) AS n, COALESCE(sum(size),0) AS b FROM copies WHERE location_id=? AND status='verified'", [.integer(owner.id)]).first {
                fc.fileCount = Int(r.int("n") ?? 0); fc.bytes = r.int("b") ?? 0
            }
            fc.missingCount = Int(try conn.scalarInt("SELECT count(*) FROM copies WHERE location_id=? AND status='missing'", [.integer(owner.id)]))
            for t in targets {
                var tc = FolderCoverage.TargetCoverage(id: t.id, name: t.name, place: t.placeKind.rawValue, coveredCount: 0, coveredBytes: 0, pendingCount: 0, pendingBytes: 0, reachable: t.isReachable)
                if let r = try conn.query("""
                    SELECT count(*) AS n, COALESCE(sum(size),0) AS b FROM copies c WHERE c.location_id=? AND c.status='verified'
                      AND EXISTS (SELECT 1 FROM copies t WHERE t.sha256=c.sha256 AND t.location_id=? AND t.status='verified')
                    """, [.integer(owner.id), .integer(t.id)]).first { tc.coveredCount = Int(r.int("n") ?? 0); tc.coveredBytes = r.int("b") ?? 0 }
                // Files not yet at the target but with a copy on the way. Counted by content, whichever folder queued the
                // job: a file inside two tracked folders (one nested in the other) is delivered by a single job.
                if let r = try conn.query("""
                    SELECT count(*) AS n, COALESCE(sum(size),0) AS b FROM copies c WHERE c.location_id=? AND c.status='verified'
                      AND NOT EXISTS (SELECT 1 FROM copies t WHERE t.sha256=c.sha256 AND t.location_id=? AND t.status='verified')
                      AND EXISTS (SELECT 1 FROM jobs j WHERE j.sha256=c.sha256 AND j.target_location_id=? AND j.kind IN ('backup','upload','import') AND j.state IN ('pending','running','paused'))
                    """, [.integer(owner.id), .integer(t.id), .integer(t.id)]).first { tc.pendingCount = Int(r.int("n") ?? 0); tc.pendingBytes = r.int("b") ?? 0 }
                fc.targets.append(tc)
            }
            if targets.count == 1, let only = fc.targets.first {
                fc.vulnerableCount = fc.fileCount - only.coveredCount; fc.vulnerableBytes = fc.bytes - only.coveredBytes
            } else if targets.count > 1 {
                let ids = targets.map { String($0.id) }.joined(separator: ",")
                // Files present at every target; vulnerable = the rest.
                if let r = try conn.query("""
                    SELECT count(*) AS n, COALESCE(sum(size),0) AS b FROM copies c WHERE c.location_id=? AND c.status='verified'
                      AND (SELECT count(DISTINCT t.location_id) FROM copies t WHERE t.sha256=c.sha256 AND t.status='verified' AND t.location_id IN (\(ids))) = ?
                    """, [.integer(owner.id), .integer(Int64(targets.count))]).first {
                    fc.vulnerableCount = fc.fileCount - Int(r.int("n") ?? 0); fc.vulnerableBytes = fc.bytes - (r.int("b") ?? 0)
                }
            }
            out.append(fc)
        }
        return out
    }

    /// The parts of a folder's picture that change second by second: what is queued or running, and whether places are reachable.
    private func refreshLiveParts(_ folders: inout [FolderCoverage]) throws {
        let locs = try locations()
        for i in folders.indices {
            let ownerId = folders[i].id
            if let owner = locs.first(where: { $0.id == ownerId }) { folders[i].reachable = owner.isReachable; folders[i].lastScanned = try lastScanned(locationId: ownerId) }
            for j in folders[i].targets.indices {
                let tid = folders[i].targets[j].id
                if let t = locs.first(where: { $0.id == tid }) { folders[i].targets[j].reachable = t.isReachable }
            }
            folders[i].activity = []
            for r in try conn.query("""
                SELECT kind, count(*) AS n, COALESCE(sum(bytes_total),0) AS t, COALESCE(sum(bytes_done),0) AS d, sum(state='running') AS running
                FROM jobs WHERE source_location_id=? AND state IN ('pending','running','paused') GROUP BY kind
                """, [.integer(ownerId)]) {
                guard let k = r.string("kind") else { continue }
                folders[i].activity.append(FolderCoverage.Activity(kind: k, count: Int(r.int("n") ?? 0), bytesTotal: r.int("t") ?? 0, bytesDone: r.int("d") ?? 0, running: Int(r.int("running") ?? 0)))
            }
        }
    }

    /// Verified bytes per physical place, for the "where is my data" picture.
    public func placeSummaries(locations: [Location]? = nil) throws -> [PlaceSummary] {
        let locs: [Location] = try locations ?? (try self.locations())
        var out: [PlaceSummary] = []
        for l in locs where l.kind != .adobe && l.kind != .source && l.enabled {
            let r = try conn.query("SELECT count(*) AS n, COALESCE(sum(size),0) AS b FROM copies WHERE location_id=? AND status='verified'", [.integer(l.id)]).first
            var free: Int64? = nil
            if let root = l.reachableRootURL, let vals = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) { free = vals.volumeAvailableCapacityForImportantUsage }
            var ps = PlaceSummary(place: l.placeKind.rawValue, locationId: l.id, name: l.name, role: l.role.rawValue,
                                  verifiedCount: Int(r?.int("n") ?? 0), verifiedBytes: r?.int("b") ?? 0, reachable: l.isReachable, freeBytes: free)
            if l.kind == .s3 {
                for row in try conn.query("SELECT COALESCE(NULLIF(storage_class,''), ?) AS cls, count(*) AS n, COALESCE(sum(size),0) AS b FROM copies WHERE location_id=? AND status='verified' GROUP BY cls",
                                          [.text(l.s3StorageClass ?? S3StorageClass.standard.rawValue), .integer(l.id)]) {
                    if let cls = row.string("cls") { ps.byClass[cls] = .init(count: Int(row.int("n") ?? 0), bytes: row.int("b") ?? 0) }
                }
            }
            out.append(ps)
        }
        return out
    }

    // MARK: Alerts (the rules pass)

    /// Settings the rules need; the engine/app pass them in via `alertSettings`.
    public struct AlertThresholds: Sendable {
        public var vulnerableBytes: Int64 = 100_000_000
        public var diskUnseenDays = 14
        public var freeSpacePercent = 10
        public var staleLocalDays = 90
        public var staleS3Days = 30
        /// Lightroom rules only run when the Lightroom integration is switched on.
        public var lightroomEnabled = false
        public init() {}
    }
    public var alertThresholds = AlertThresholds()
    public func setAlertThresholds(_ t: AlertThresholds) { alertThresholds = t }
    private var lastAlertPass: Date = .distantPast

    private var lastSeenWrite: Date = .distantPast
    private func noteSeenLocations(_ locs: [Location]) throws {
        let now = Date()
        guard now.timeIntervalSince(lastSeenWrite) > 60 else { return }
        lastSeenWrite = now
        for l in locs where l.kind == .local || l.kind == .source {
            if l.isReachable { try conn.run("UPDATE locations SET last_seen=? WHERE id=?", [.init(now), .integer(l.id)]) }
        }
    }

    public func lastSeen(locationId: Int64) throws -> Date? {
        try conn.query("SELECT last_seen FROM locations WHERE id=?", [.integer(locationId)]).first?.date("last_seen")
    }

    private func evaluateAlertsIfDue(stats s: CatalogStats, locations locs: [Location]) throws -> [Alert] {
        if Date().timeIntervalSince(lastAlertPass) < 30 { return try activeAlerts() }
        lastAlertPass = Date()
        return try runAlertRules(stats: s, locations: locs)
    }

    /// Computes the current set of alerts from the catalogue, upserts them, resolves the ones that cleared.
    @discardableResult
    public func runAlertRules(stats s: CatalogStats? = nil, locations locs: [Location]? = nil) throws -> [Alert] {
        let locs = try locs ?? locations()
        let t = alertThresholds
        var current: [Alert] = []
        let byId = Dictionary(uniqueKeysWithValues: locs.map { ($0.id, $0) })

        // 1. Corrupt copies: the most important one. A disk is going bad, or a file was tampered with.
        for r in try conn.query("SELECT location_id, count(*) AS n FROM copies WHERE status='corrupt' GROUP BY location_id") {
            guard let lid = r.int("location_id"), let l = byId[lid] else { continue }
            let n = Int(r.int("n") ?? 0)
            current.append(Alert(key: "corrupt:\(lid)", severity: .critical, title: "\(n) corrupt cop\(n == 1 ? "y" : "ies") on \(l.name)",
                                 detail: "A re-check found bytes that no longer match their checksum. Check the disk; the other copies of these files are what you now rely on. Backup HQ re-copies them from the folder if it still has them.", locationId: lid))
        }
        // 2. Copies missing at a target (a backup that vanished).
        for r in try conn.query("""
            SELECT c.location_id, count(*) AS n FROM copies c JOIN locations l ON l.id=c.location_id
            WHERE c.status='missing' AND l.role IN ('mirror','archive') GROUP BY c.location_id
            """) {
            guard let lid = r.int("location_id"), let l = byId[lid] else { continue }
            let n = Int(r.int("n") ?? 0)
            current.append(Alert(key: "missing:\(lid)", severity: .warning, title: "\(n) backup cop\(n == 1 ? "y" : "ies") missing from \(l.name)",
                                 detail: "Files that were backed up there are gone. They are re-copied automatically if the folder still has them.", locationId: lid))
        }
        // 3. Below policy beyond the threshold.
        let folders = try s?.folders ?? folderCoverage(locations: locs)
        for f in folders {
            let gap = f.targets.reduce(Int64(0)) { $0 + max(0, f.bytes - $1.coveredBytes - $1.pendingBytes) }
            if gap >= t.vulnerableBytes {
                current.append(Alert(key: "policy:\(f.id)", severity: .warning, title: "\(f.name): \(Format.bytes(gap)) not yet where you asked",
                                     detail: "This folder wants copies in \(f.targets.map(\.name).joined(separator: " and ")) and \(Format.bytes(gap)) has none queued. Back up now, or check that the target is reachable.", locationId: f.id))
            }
        }
        // 4. Disks not seen for a while.
        for l in locs where (l.kind == .local) && l.enabled && !l.isReachable {
            let seen = try lastSeen(locationId: l.id) ?? l.created
            let days = Int(Date().timeIntervalSince(seen) / 86400)
            if days >= t.diskUnseenDays {
                current.append(Alert(key: "unseen:\(l.id)", severity: .warning, title: "\(l.name) not seen for \(days) days",
                                     detail: "Plug it in so its copies can be checked and new copies made. Last seen \(seen.formatted(date: .abbreviated, time: .omitted)).", locationId: l.id))
            }
        }
        // 5. Low free space on library / mirror disks.
        for l in locs where (l.role == .library || l.role == .mirror) && l.enabled {
            guard let root = l.reachableRootURL else { continue }
            if let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
               let free = v.volumeAvailableCapacityForImportantUsage, let total = v.volumeTotalCapacity, total > 0 {
                let pct = Double(free) / Double(total) * 100
                if pct < Double(t.freeSpacePercent) {
                    current.append(Alert(key: "space:\(l.id)", severity: pct < 3 ? .critical : .warning, title: "\(l.name) is \(Int(100 - pct))% full",
                                         detail: "\(Format.bytes(free)) free. Copies will start failing when it fills.", locationId: l.id))
                }
            }
        }
        // 6. Stale verification: copies at a place not checked within the cadence (only reported once a place is reachable).
        for l in locs where l.isProtective && l.kind != .adobe && l.enabled && l.isReachable {
            let days = l.kind == .s3 ? t.staleS3Days : t.staleLocalDays
            let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
            let n = Int(try conn.scalarInt("SELECT count(*) FROM copies WHERE location_id=? AND status='verified' AND (verified_at IS NULL OR verified_at < ?)", [.integer(l.id), .init(cutoff)]))
            if n > 0 {
                current.append(Alert(key: "stale:\(l.id)", severity: .info, title: "\(Format.count(n)) copies on \(l.name) not checked in \(days) days",
                                     detail: "Background verification re-checks them while the engine is idle. Start the engine to let it.", locationId: l.id))
            }
        }
        // 7. Lightroom masters that never reached Adobe and are still not held locally.
        if alertThresholds.lightroomEnabled, let s, s.cloudNeverUploadedCount > 0 {
            let held = Int(try conn.scalarInt("""
                SELECT count(*) FROM cloud_assets ca WHERE ca.deleted=0 AND ca.will_not_upload_master=1 AND EXISTS
                  (SELECT 1 FROM copies c WHERE c.sha256=ca.sha256 AND c.status='verified' AND c.location_id IN (SELECT id FROM locations WHERE kind IN ('local','s3')))
                """))
            let n = s.cloudNeverUploadedCount - held
            if n > 0 {
                current.append(Alert(key: "never-uploaded", severity: .info, title: "\(n) Lightroom photos exist only as smart previews",
                                     detail: "Their originals never reached Adobe, so Lightroom cannot download them. They must come from wherever they were imported (an old drive or card)."))
            }
        }
        // 8. Failed jobs that are not being retried.
        let failed = Int(try conn.scalarInt("SELECT count(*) FROM jobs WHERE state='failed'"))
        if failed > 0 {
            current.append(Alert(key: "failed-jobs", severity: .warning, title: "\(failed) job\(failed == 1 ? "" : "s") failed",
                                 detail: "See Activity for the reason. Retry failed re-queues them."))
        }

        // Upsert / resolve.
        let now = Date()
        try conn.transaction {
            let keys = Set(current.map(\.key))
            for a in current {
                try conn.run("""
                INSERT INTO alerts(key,severity,title,detail,location_id,first_seen,last_seen,resolved_at,acknowledged_at) VALUES(?,?,?,?,?,?,?,NULL,NULL)
                ON CONFLICT(key) DO UPDATE SET severity=excluded.severity, title=excluded.title, detail=excluded.detail, last_seen=excluded.last_seen,
                    first_seen=CASE WHEN alerts.resolved_at IS NULL THEN alerts.first_seen ELSE excluded.first_seen END,
                    acknowledged_at=CASE WHEN alerts.resolved_at IS NULL THEN alerts.acknowledged_at ELSE NULL END,
                    resolved_at=NULL
                """, [.text(a.key), .text(a.severity.rawValue), .text(a.title), .text(a.detail), .init(a.locationId), .init(now), .init(now)])
            }
            let open = try conn.query("SELECT key FROM alerts WHERE resolved_at IS NULL").compactMap { $0.string("key") }
            for k in open where !keys.contains(k) { try conn.run("UPDATE alerts SET resolved_at=? WHERE key=?", [.init(now), .text(k)]) }
        }
        return try activeAlerts()
    }

    public func activeAlerts() throws -> [Alert] {
        try conn.query("SELECT * FROM alerts WHERE resolved_at IS NULL ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, first_seen DESC").map {
            Alert(key: $0.string("key") ?? "", severity: Alert.Severity(rawValue: $0.string("severity") ?? "info") ?? .info, title: $0.string("title") ?? "",
                  detail: $0.string("detail") ?? "", locationId: $0.int("location_id"), firstSeen: $0.date("first_seen") ?? Date(), lastSeen: $0.date("last_seen") ?? Date(),
                  acknowledgedAt: $0.date("acknowledged_at"))
        }
    }

    public func acknowledgeAlert(key: String) throws {
        try conn.run("UPDATE alerts SET acknowledged_at=? WHERE key=?", [.init(Date()), .text(key)])
    }

    // MARK: Background care

    /// Verified copies at a reachable location whose last check is older than `olderThan`, oldest first.
    public func staleCopies(locationId: Int64, olderThan: Date, limit: Int) throws -> [Copy] {
        try conn.query("SELECT * FROM copies WHERE location_id=? AND status='verified' AND (verified_at IS NULL OR verified_at < ?) ORDER BY verified_at LIMIT ?",
                       [.integer(locationId), .init(olderThan), .integer(Int64(limit))]).map(Self.copy(from:))
    }

    /// Copies at mirror/archive targets that a check found corrupt or missing, with the owner that should re-supply them.
    public func brokenTargetCopies(limit: Int = 500) throws -> [(copy: Copy, targetId: Int64, ownerId: Int64)] {
        var out: [(Copy, Int64, Int64)] = []
        for r in try conn.query("""
            SELECT c.*, (SELECT o.location_id FROM copies o JOIN locations ol ON ol.id=o.location_id
                         WHERE o.sha256=c.sha256 AND o.status='verified' AND ol.role IN ('library','tracked') AND ol.enabled=1 LIMIT 1) AS owner_id
            FROM copies c JOIN locations l ON l.id=c.location_id
            WHERE c.status IN ('corrupt','missing') AND l.role IN ('mirror','archive') AND l.enabled=1 LIMIT ?
            """, [.integer(Int64(limit))]) {
            guard let owner = r.int("owner_id") else { continue }
            out.append((Self.copy(from: r), r.int("location_id") ?? 0, owner))
        }
        return out
    }

    // MARK: Timeline snapshots

    private func recordSnapshotIfDue(stats s: CatalogStats) throws {
        let last = try conn.query("SELECT max(time) AS t FROM coverage_snapshots").first?.double("t") ?? 0
        let now = Date().timeIntervalSince1970
        let tracked = s.folders.reduce(0) { $0 + $1.bytes }
        let protected = s.folders.reduce(0) { $0 + ($1.targets.isEmpty ? 0 : $1.bytes - $1.vulnerableBytes) }
        let s3 = s.places.filter { $0.place == "s3" }.reduce(0) { $0 + $1.verifiedBytes }
        // Record hourly, or immediately when the picture changed noticeably.
        let prev = try conn.query("SELECT * FROM coverage_snapshots ORDER BY time DESC LIMIT 1").first
        let changed = prev.map { abs(($0.int("protected_bytes") ?? 0) - protected) > max(50_000_000, protected / 200) } ?? true
        guard now - last > 3600 || (changed && now - last > 60) else { return }
        try conn.run("INSERT OR REPLACE INTO coverage_snapshots(time,tracked_bytes,protected_bytes,s3_bytes,vulnerable_bytes) VALUES(?,?,?,?,?)",
                     [.real(now), .integer(tracked), .integer(protected), .integer(s3), .integer(s.vulnerableBytes)])
    }

    public func snapshots(limit: Int = 400) throws -> [CoverageSnapshot] {
        try conn.query("SELECT * FROM coverage_snapshots ORDER BY time DESC LIMIT ?", [.integer(Int64(limit))]).reversed().map {
            CoverageSnapshot(time: $0.date("time") ?? Date(), trackedBytes: $0.int("tracked_bytes") ?? 0, protectedBytes: $0.int("protected_bytes") ?? 0,
                             s3Bytes: $0.int("s3_bytes") ?? 0, vulnerableBytes: $0.int("vulnerable_bytes") ?? 0)
        }
    }

    // MARK: Maintenance

    public func vacuumIfLarge() throws { try conn.execute("PRAGMA optimize; PRAGMA wal_checkpoint(TRUNCATE)") }
}

public enum DatabaseError: Error, LocalizedError {
    case duplicateName(String)
    case invalidTarget(Int64)
    public var errorDescription: String? {
        switch self {
        case .duplicateName(let n): return "A tracked folder or library named \"\(n)\" already exists; names must be unique because they become folder names in backups."
        case .invalidTarget(let id): return "Location \(id) cannot receive backups (only backup-disk roots and S3 archives can)."
        }
    }
}
