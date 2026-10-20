import Foundation

/// Reads Adobe Lightroom (cloud) desktop's local "Managed Catalog.mcat" — a SQLite document store
/// holding MessagePack-encoded copies of every cloud asset record. This is our manifest of what the
/// Adobe cloud holds: id, original file name, size, SHA-256 and capture date for every asset.
public struct LightroomCatalog: Sendable {
    public struct Discovery: Sendable, Equatable {
        public var catalogURL: URL?                 // .../Managed Catalog.mcat
        public var catalogId: String?               // the 32-hex folder name
        public var originalsStoreURL: URL?          // where Lightroom puts downloaded originals (<store>/<catalogId>/originals)
        public var keepAllOriginals: Bool?          // Lightroom's "Store a copy of all originals" preference
        public var targetCacheSizeBytes: Int64?
        public var lightroomRunning: Bool

        public init(catalogURL: URL? = nil, catalogId: String? = nil, originalsStoreURL: URL? = nil, keepAllOriginals: Bool? = nil, targetCacheSizeBytes: Int64? = nil, lightroomRunning: Bool = false) {
            self.catalogURL = catalogURL; self.catalogId = catalogId; self.originalsStoreURL = originalsStoreURL
            self.keepAllOriginals = keepAllOriginals; self.targetCacheSizeBytes = targetCacheSizeBytes; self.lightroomRunning = lightroomRunning
        }
    }

    public let url: URL

    public init(url: URL) { self.url = url }

    // MARK: Discovery

    public static func discover() -> Discovery {
        let fm = FileManager.default
        var d = Discovery(lightroomRunning: false)
        #if os(macOS)
        let home = fm.homeDirectoryForCurrentUser
        #else
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
        if home.path.isEmpty == false { return d }   // Lightroom lives on the Mac; the phone only reads what the Mac publishes.
        #endif

        // 1. The library bundle. Default location is ~/Pictures/Lightroom Library.lrlibrary.
        let candidates = [home.appendingPathComponent("Pictures/Lightroom Library.lrlibrary")]
        for bundle in candidates where fm.fileExists(atPath: bundle.path) {
            if let items = try? fm.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil) {
                for item in items where item.lastPathComponent.count == 32 {
                    let mcat = item.appendingPathComponent("Managed Catalog.mcat")
                    if fm.fileExists(atPath: mcat.path) { d.catalogURL = mcat; d.catalogId = item.lastPathComponent }
                }
            }
        }

        // 2. Preferences: where Lightroom stores originals, and whether it keeps them all.
        if let prefs = UserDefaults(suiteName: "com.adobe.lightroomCC") {
            let dict = prefs.dictionaryRepresentation()
            if let keep = dict["NmbFileManagementSettings_KeepAllOriginals"] {
                d.keepAllOriginals = (keep as? Bool) ?? ((keep as? NSNumber)?.boolValue) ?? ((keep as? String).map { $0 == "1" || $0.lowercased() == "true" })
            }
            if let size = dict["NmbFileManagementSettings_targetCacheSize"] as? NSNumber { d.targetCacheSizeBytes = size.int64Value }
            let rel = dict["NmbFileManagementSettings_relativeOriginalStorageLocation"] as? String
            let volGUID = dict["NmbFileManagementSettings_originalStorageVolumeGuid"] as? String
            if let rel {
                var root: URL? = nil
                if let volGUID, let vol = volumeURL(forUUID: volGUID) { root = vol }
                if root == nil { root = URL(fileURLWithPath: "/") }
                if let root {
                    let store = root.appendingPathComponent(rel)
                    if let cid = d.catalogId {
                        // Lightroom writes <store>/<catalogId>/originals, or since 2025 <store>/Lightroom CC/<catalogId>/originals.
                        let candidates = [store.appendingPathComponent(cid).appendingPathComponent("originals"),
                                          store.appendingPathComponent("Lightroom CC").appendingPathComponent(cid).appendingPathComponent("originals")]
                        d.originalsStoreURL = candidates.first { fm.fileExists(atPath: $0.path) } ?? store
                    } else {
                        d.originalsStoreURL = store
                    }
                }
            }
        }

        // 3. Is Lightroom running? (Only matters as advice: reading the catalog is safe either way.)
        let running = ProcessInfo.processInfo.environment["BACKUPHQ_NO_PS"] == nil ? Self.isLightroomRunning() : false
        d.lightroomRunning = running
        return d
    }

    private static func isLightroomRunning() -> Bool {
        #if !os(macOS)
        return false
        #else
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "Adobe Lightroom"]
        task.standardOutput = Pipe(); task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 } catch { return false }
        #endif
    }

    /// Resolves a volume UUID (as macOS reports it) to its mount point.
    public static func volumeURL(forUUID uuid: String) -> URL? {
        let keys: [URLResourceKey] = [.volumeUUIDStringKey]
        guard let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return nil }
        for v in vols {
            if let vals = try? v.resourceValues(forKeys: Set(keys)), let u = vals.volumeUUIDString, u.caseInsensitiveCompare(uuid) == .orderedSame {
                return v
            }
        }
        return nil
    }

    public static func volumeUUID(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    // MARK: Reading

    public struct AssetRecord: Sendable {
        public var asset: CloudAsset
        public var metadataJSON: Data?
        public var width: Int?
        public var height: Int?
    }

    public struct Summary: Sendable, Equatable {
        public var liveAssets = 0
        public var liveBytes: Int64 = 0
        public var deletedAssets = 0
        public var neverUploaded = 0
        public var videos = 0
    }

    /// Opens the catalog read-only (WAL readers coexist with Lightroom) and streams every asset record.
    /// `includeDeleted` also yields assets the user deleted in Lightroom (useful for history, not for backup).
    public func readAssets(includeDeleted: Bool = false, batch: Int = 500, handler: ([AssetRecord]) throws -> Void) throws -> Summary {
        let conn = try SQLiteConnection(path: url.path, readOnly: true, create: false)
        var summary = Summary()
        var buffer: [AssetRecord] = []
        let sql = """
        SELECT d.fullDocId AS id, d.deleted AS deleted, d.subtype AS subtype, CAST(r.content AS BLOB) AS content
        FROM docs d JOIN revs r ON r.sequence = d.winningRevSequence
        WHERE d.type = 'asset' AND d.subtype IN ('image','video','deleted_image','deleted_video')
        """ + (includeDeleted ? "" : " AND d.deleted = 0")
        try conn.query(sql) { row in
            guard let id = row.string("id"), let blob = row.blob("content") else { return }
            let deleted = row.bool("deleted") || (row.string("subtype")?.hasPrefix("deleted") ?? false)
            guard var doc = (try? MessagePack.decode(blob)) as? [String: Any] else { return }
            let develop = doc.removeValue(forKey: "develop")  // large, edit-only; not needed for backup
            _ = develop
            guard let source = doc["importSource"] as? [String: Any],
                  let sha = source["sha256"] as? String,
                  let name = source["fileName"] as? String else { return }
            let size = (source["fileSize"] as? Int64) ?? Int64((source["fileSize"] as? Double) ?? 0)
            let subtype = (doc["subtype"] as? String) ?? (row.string("subtype") ?? "image")
            let willNot = (source["willNotUploadMaster"] as? Bool) ?? false
            var rating: Int? = nil
            if let ratings = doc["ratings"] as? [String: Any] {
                for (_, v) in ratings { if let r = (v as? [String: Any])?["rating"] as? Int64 { rating = max(rating ?? 0, Int(r)) } }
            }
            let asset = CloudAsset(assetId: id, sha256: sha, fileName: name, fileSize: size,
                                   contentType: source["contentType"] as? String, subtype: subtype.replacingOccurrences(of: "deleted_", with: ""),
                                   captureDate: doc["captureDate"] as? String, willNotUploadMaster: willNot, deleted: deleted, rating: rating,
                                   userCreated: doc["userCreated"] as? String, userUpdated: doc["userUpdated"] as? String)
            let json = try? JSONSerialization.data(withJSONObject: MessagePack.jsonify(doc), options: [.sortedKeys])
            let rec = AssetRecord(asset: asset, metadataJSON: json,
                                  width: (source["originalWidth"] as? Int64).map(Int.init), height: (source["originalHeight"] as? Int64).map(Int.init))
            if deleted { summary.deletedAssets += 1 } else {
                summary.liveAssets += 1; summary.liveBytes += size
                if willNot { summary.neverUploaded += 1 }
                if asset.subtype == "video" { summary.videos += 1 }
            }
            buffer.append(rec)
            if buffer.count >= batch { try handler(buffer); buffer.removeAll(keepingCapacity: true) }
        }
        if !buffer.isEmpty { try handler(buffer) }
        // Deleted assets keep only a tombstone revision, so count them directly.
        summary.deletedAssets = Int(try conn.scalarInt("SELECT count(*) FROM docs WHERE type='asset' AND (deleted=1 OR subtype LIKE 'deleted_%')"))
        return summary
    }

    /// Imports the whole catalog into our database. Returns the summary.
    public func sync(into db: Database, includeDeleted: Bool = true, progress: (@Sendable (Int) -> Void)? = nil) async throws -> Summary {
        var total = 0
        // readAssets is synchronous and the handler is synchronous; we collect batches and hand them to the actor.
        var batches: [[AssetRecord]] = []
        let summary = try readAssets(includeDeleted: includeDeleted) { batch in batches.append(batch) }
        for batch in batches {
            try await db.upsertCloudAssets(batch.map { ($0.asset, $0.metadataJSON) })
            total += batch.count
            progress?(total)
        }
        // Tombstones are not stored as rows, so remember the count for the stats page.
        try? await db.setSetting("lightroom.deletedCount", String(summary.deletedAssets))
        try? await db.setSetting("lightroom.lastSync", ISO8601DateFormatter().string(from: Date()))
        await db.log("info", "Lightroom catalog synced: \(summary.liveAssets) live assets, \(summary.deletedAssets) deleted, \(summary.neverUploaded) never uploaded")
        return summary
    }
}

/// Derives the yyyy-MM-dd folder day from a Lightroom capture date string (e.g. "2018-01-28T13:45:45").
public enum CaptureDate {
    public static func day(from capture: String?) -> String? {
        guard let capture, capture.count >= 10 else { return nil }
        let d = String(capture.prefix(10))
        // sanity: yyyy-MM-dd
        let parts = d.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, Int(parts[0]) != nil else { return nil }
        return d
    }
    public static func year(from day: String?) -> String? { day.map { String($0.prefix(4)) } }
}
