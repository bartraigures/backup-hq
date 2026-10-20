import Foundation

public enum ContentKind: String, Codable, Sendable { case image, video, other }

/// A unique piece of content, identified by its SHA-256. Two Lightroom assets (or two files)
/// with identical bytes are the same `Content` — that is what "true duplicate" means here.
public struct Content: Identifiable, Hashable, Sendable {
    public var id: String { sha256 }
    public var sha256: String
    public var size: Int64
    public var kind: ContentKind
    public var contentType: String?
    public var displayName: String
    public var captureDate: String?     // ISO-ish, as Lightroom records it (local time, no zone)
    public var captureDay: String?      // yyyy-MM-dd used for folder layout
    public var width: Int?
    public var height: Int?
    public var firstSeen: Date
}

public struct CloudAsset: Identifiable, Hashable, Sendable {
    public var id: String { assetId }
    public var assetId: String
    public var sha256: String
    public var fileName: String
    public var fileSize: Int64
    public var contentType: String?
    public var subtype: String
    public var captureDate: String?
    public var willNotUploadMaster: Bool
    public var deleted: Bool
    public var rating: Int?
    public var userCreated: String?
    public var userUpdated: String?
}

public enum LocationKind: String, Codable, Sendable, CaseIterable {
    case local      // a folder on a disk that is a protected archive copy
    case s3         // an S3 bucket/prefix
    case adobe      // Adobe Lightroom cloud (virtual; copies derived from the catalog)
    case source     // a folder we ingest from but do not count as a safe copy (e.g. Lightroom's cache)
}

/// What a location is *for*. `kind` says what it physically is; `role` says how the app treats it.
public enum LocationRole: String, Codable, Sendable, CaseIterable {
    case library   // the app-owned photo library: files are laid out by capture date (the primary)
    case tracked   // a folder you chose, anywhere; inventoried in place, never rearranged
    case mirror    // a root on a backup disk that receives copies of tracked folders (<mirror>/<folder name>/<path>)
    case archive   // an S3 bucket/prefix that receives copies (<prefix>/<folder name>/<path>)
    case source    // staging only (Lightroom's originals store); ingested into the library, not a safe place
    case adobe     // Lightroom cloud, virtual
}

/// Where a location physically lives, for the "Mac / external disk / S3" picture.
public enum PlaceKind: String, Codable, Sendable { case mac, external, s3, adobe }

public struct Location: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var kind: LocationKind
    public var role: LocationRole
    public var name: String
    public var rootPath: String?
    public var volumeUUID: String?
    public var s3Region: String?
    public var s3Bucket: String?
    public var s3Prefix: String?
    public var s3StorageClass: String?
    public var s3Profile: String?
    public var enabled: Bool
    public var isPrimary: Bool
    public var autoUpload: Bool
    /// For library/tracked locations: ids of the mirror and/or archive locations this folder should also exist in.
    /// Empty means "single copy by choice". Nothing is ever sent anywhere that is not listed here.
    public var targets: [Int64]
    /// Per-target S3 storage class chosen for this folder (target id → class raw value). Missing means the target's own class.
    public var storageClasses: [Int64: String] = [:]
    public var created: Date
    public var lastVerified: Date?
    /// Where the last scan left off in the volume's change journal (FSEvents), and which journal that was.
    public var scanCursor: Int64? = nil
    public var scanDevice: String? = nil
    /// Extra ignore rules for this folder, and whether the standard list from Settings applies too.
    public var ignoreRules: [String] = []
    public var useStandardIgnores: Bool = true

    /// The class uploads from this folder to `target` use.
    public func storageClass(for target: Location) -> S3StorageClass {
        S3StorageClass(rawValue: storageClasses[target.id] ?? target.s3StorageClass ?? "") ?? .glacier
    }

    /// Counts as a safe place for a copy to live (local disks and S3; not sources).
    public var isProtective: Bool { kind == .local || kind == .s3 || kind == .adobe }
    /// A folder whose contents are "owned" here and may want copies elsewhere.
    public var isOwner: Bool { role == .library || role == .tracked }
    /// Can be the target of a backup.
    public var isTarget: Bool { role == .mirror || role == .archive }

    public var rootURL: URL? { rootPath.map { URL(fileURLWithPath: $0) } }

    /// The root as it is reachable right now: the stored path if it exists, else the same path on the
    /// volume with the stored UUID if that disk is mounted under a different name. nil when offline.
    public var reachableRootURL: URL? {
        guard let rootPath else { return nil }
        if FileManager.default.fileExists(atPath: rootPath) { return URL(fileURLWithPath: rootPath) }
        guard let uuid = volumeUUID, let vol = LightroomCatalog.volumeURL(forUUID: uuid) else { return nil }
        let comps = rootPath.split(separator: "/", omittingEmptySubsequences: true)
        guard comps.count >= 2, comps[0] == "Volumes" else { return nil }
        let candidate = vol.appendingPathComponent(comps.dropFirst(2).joined(separator: "/"))
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    public var isReachable: Bool {
        switch kind {
        case .s3, .adobe: return true
        case .local, .source: return reachableRootURL != nil
        }
    }

    public var placeKind: PlaceKind {
        switch kind {
        case .s3: return .s3
        case .adobe: return .adobe
        case .local, .source:
            if let uuid = volumeUUID, let boot = LightroomCatalog.volumeUUID(of: URL(fileURLWithPath: "/")), uuid.caseInsensitiveCompare(boot) == .orderedSame { return .mac }
            if let p = rootPath, !p.hasPrefix("/Volumes/") { return .mac }
            return .external
        }
    }

    /// Folder name used for this location's copies inside a mirror root or an S3 prefix.
    public var mirrorName: String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "folder-\(id)" : cleaned
    }

    public var summaryLine: String {
        switch kind {
        case .local, .source: return rootPath ?? ""
        case .s3: return "s3://\(s3Bucket ?? "?")/\(s3Prefix ?? "") · \(s3Region ?? "") · \(s3StorageClass ?? "")"
        case .adobe: return "Lightroom cloud catalog"
        }
    }
}

public enum CopyStatus: String, Codable, Sendable {
    case verified      // bytes confirmed (local re-hash, or S3 checksum-accepted + HEAD size match)
    case unverified    // seen but not checked yet
    case missing       // was there, now gone
    case corrupt       // hash mismatch
}

public struct Copy: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var sha256: String
    public var locationId: Int64
    public var path: String        // relative path for local, object key for S3
    public var size: Int64?
    public var status: CopyStatus
    public var etag: String?
    public var storageClass: String?
    public var verifiedAt: Date?
    public var created: Date
}

public enum JobKind: String, Codable, Sendable, CaseIterable {
    case scan      // enumerate a source folder, creating hash jobs
    case hash      // hash a discovered file, register content + source copy, queue import
    case `import`  // copy/move into a local library location, verify
    case backup    // copy a tracked/library file into a mirror root, keeping its path, verify
    case upload    // upload to an S3 location, verify
    case verify    // re-check an existing copy
    case reclass   // move an S3 copy to another storage class (restoring it first if it is archived)
}

public enum JobState: String, Codable, Sendable, CaseIterable {
    case pending, running, done, failed, paused
}

public struct Job: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var kind: JobKind
    public var state: JobState
    public var sha256: String?
    public var sourcePath: String?
    public var sourceLocationId: Int64?
    public var targetLocationId: Int64?
    public var copyId: Int64?
    public var priority: Int
    public var attempts: Int
    public var error: String?
    public var bytesTotal: Int64
    public var bytesDone: Int64
    public var resumeJSON: String?
    public var created: Date
    public var updated: Date
    public var started: Date?
    public var finished: Date?

    public var displayName: String {
        if let p = sourcePath { return (p as NSString).lastPathComponent }
        return sha256.map { String($0.prefix(12)) } ?? "#\(id)"
    }
}

public struct Event: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var time: Date
    public var level: String
    public var message: String
    public var sha256: String?
    public var jobId: Int64?
}

/// Everything the dashboard (and the phone) needs, in one struct.
public struct CatalogStats: Codable, Sendable, Equatable {
    public var generatedAt: Date = Date()
    public var contentCount: Int = 0
    public var contentBytes: Int64 = 0
    public var cloudAssetCount: Int = 0
    public var cloudAssetBytes: Int64 = 0
    public var cloudDeletedCount: Int = 0
    public var cloudNeverUploadedCount: Int = 0
    public var cloudNeverUploadedBytes: Int64 = 0
    public var cloudMatchedLocallyCount: Int = 0      // cloud assets whose content we have in some protective location
    public var cloudMatchedLocallyBytes: Int64 = 0
    public var cloudOnlyCount: Int = 0                 // cloud assets we have nowhere else yet
    public var cloudOnlyBytes: Int64 = 0
    public var vulnerableCount: Int = 0                // files below their folder's wanted copies
    public var vulnerableBytes: Int64 = 0
    public var singlePlaceLocalOnlyCount: Int = 0      // content on exactly one local disk and nowhere else
    public var singleCopyByChoiceCount: Int = 0        // files in folders with no targets, present in one place only
    public var singleCopyByChoiceBytes: Int64 = 0
    public var bytesPendingBackup: Int64 = 0
    public var folders: [FolderCoverage] = []
    public var places: [PlaceSummary] = []
    public var history: [CoverageSnapshot] = []
    public var alerts: [Alert] = []
    /// What is happening right now: the running jobs and the queue by kind.
    public var running: [RunningJob] = []
    public var queue: [QueueLine] = []
    /// What finished in the last 24 hours, per kind of job.
    public struct RecentWork: Codable, Sendable, Equatable, Identifiable {
        public var id: String { kind }
        public var kind: String
        public var count: Int
        public var bytes: Int64
        public init(kind: String, count: Int, bytes: Int64) { self.kind = kind; self.count = count; self.bytes = bytes }
    }
    public var recentWork: [RecentWork] = []
    /// The last few log lines, for the Home page to show while nothing is running.
    public struct RecentEvent: Codable, Sendable, Equatable, Identifiable {
        public var id: Int64
        public var time: Date
        public var level: String
        public var message: String
        public init(id: Int64, time: Date, level: String, message: String) { self.id = id; self.time = time; self.level = level; self.message = message }
    }
    public var recentEvents: [RecentEvent] = []
    public var duplicateGroups: Int = 0
    public var duplicateExtraCount: Int = 0
    public var jobsPending: Int = 0
    public var jobsRunning: Int = 0
    public var jobsFailed: Int = 0
    public var jobsDone: Int = 0
    public var bytesPendingUpload: Int64 = 0
    public var bytesPendingImport: Int64 = 0
    public var perLocation: [LocationStats] = []
    public var engineRunning: Bool = false
    public var throughputBytesPerSecond: Double = 0

    public init() {}
}

/// One tracked folder (or the library) against each of its targets: the coverage-matrix row.
public struct FolderCoverage: Codable, Sendable, Equatable, Identifiable {
    public struct TargetCoverage: Codable, Sendable, Equatable, Identifiable {
        public var id: Int64            // target location id
        public var name: String
        public var place: String        // PlaceKind raw value
        public var coveredCount: Int
        public var coveredBytes: Int64
        public var pendingCount: Int
        public var pendingBytes: Int64
        public var reachable: Bool
        public init(id: Int64, name: String, place: String, coveredCount: Int, coveredBytes: Int64, pendingCount: Int, pendingBytes: Int64, reachable: Bool) {
            self.id = id; self.name = name; self.place = place; self.coveredCount = coveredCount; self.coveredBytes = coveredBytes
            self.pendingCount = pendingCount; self.pendingBytes = pendingBytes; self.reachable = reachable
        }
    }
    public var id: Int64                // owning location id
    public var name: String
    public var role: String             // library | tracked
    public var place: String            // mac | external
    public var rootPath: String
    public var reachable: Bool
    public var fileCount: Int           // verified files present in the folder itself
    public var bytes: Int64
    public var missingCount: Int        // files the folder used to have (copies elsewhere may remain)
    public var targets: [TargetCoverage]
    /// Outstanding work for this folder by job kind (scan, hash, backup, upload, verify).
    public struct Activity: Codable, Sendable, Equatable, Identifiable {
        public var id: String { kind }
        public var kind: String
        public var count: Int
        public var bytesTotal: Int64
        public var bytesDone: Int64
        public var running: Int
        public init(kind: String, count: Int, bytesTotal: Int64, bytesDone: Int64, running: Int) { self.kind = kind; self.count = count; self.bytesTotal = bytesTotal; self.bytesDone = bytesDone; self.running = running }
    }
    public var activity: [Activity] = []
    public var vulnerableCount: Int     // files lacking a verified copy at one or more targets
    public var vulnerableBytes: Int64
    public var lastScanned: Date?
    public var wantedPlaces: Int { 1 + targets.count }
    public var satisfied: Bool { vulnerableCount == 0 }
    public init(id: Int64, name: String, role: String, place: String, rootPath: String, reachable: Bool, fileCount: Int, bytes: Int64, missingCount: Int,
                targets: [TargetCoverage], vulnerableCount: Int, vulnerableBytes: Int64, lastScanned: Date?) {
        self.id = id; self.name = name; self.role = role; self.place = place; self.rootPath = rootPath; self.reachable = reachable
        self.fileCount = fileCount; self.bytes = bytes; self.missingCount = missingCount; self.targets = targets
        self.vulnerableCount = vulnerableCount; self.vulnerableBytes = vulnerableBytes; self.lastScanned = lastScanned
    }
}

/// Something that needs your attention. Produced by the rules pass, kept until the condition clears.
public struct Alert: Codable, Sendable, Equatable, Identifiable {
    public enum Severity: String, Codable, Sendable { case info, warning, critical }
    public var id: String { key }
    public var key: String            // stable: "corrupt:<locationId>", "unseen:<locationId>", "policy:<folderId>", ...
    public var severity: Severity
    public var title: String
    public var detail: String
    public var locationId: Int64?
    public var firstSeen: Date
    public var lastSeen: Date
    public var acknowledgedAt: Date?
    public init(key: String, severity: Severity, title: String, detail: String, locationId: Int64? = nil, firstSeen: Date = Date(), lastSeen: Date = Date(), acknowledgedAt: Date? = nil) {
        self.key = key; self.severity = severity; self.title = title; self.detail = detail; self.locationId = locationId
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.acknowledgedAt = acknowledgedAt
    }
}

/// A job in flight, for the "right now" panel.
public struct RunningJob: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var kind: String
    public var name: String
    public var targetName: String?
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public init(id: Int64, kind: String, name: String, targetName: String?, bytesDone: Int64, bytesTotal: Int64) {
        self.id = id; self.kind = kind; self.name = name; self.targetName = targetName; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
    }
}

/// Outstanding work of one kind towards one target ("copying 210 files to Crucial backups").
public struct QueueLine: Codable, Sendable, Equatable, Identifiable {
    public var id: String { kind + ":" + String(targetId ?? 0) }
    public var kind: String
    public var targetId: Int64?
    public var targetName: String?
    public var count: Int
    public var bytes: Int64
    public init(kind: String, targetId: Int64?, targetName: String?, count: Int, bytes: Int64) {
        self.kind = kind; self.targetId = targetId; self.targetName = targetName; self.count = count; self.bytes = bytes
    }
}

/// One point on the "protected over time" curve.
public struct CoverageSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { time }
    public var time: Date
    public var trackedBytes: Int64
    public var protectedBytes: Int64
    public var s3Bytes: Int64
    public var vulnerableBytes: Int64
    public init(time: Date, trackedBytes: Int64, protectedBytes: Int64, s3Bytes: Int64, vulnerableBytes: Int64) {
        self.time = time; self.trackedBytes = trackedBytes; self.protectedBytes = protectedBytes; self.s3Bytes = s3Bytes; self.vulnerableBytes = vulnerableBytes
    }
}

/// Bytes held per physical place (Mac / external disks / S3), for the big picture.
public struct PlaceSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String { place + ":" + String(locationId) }
    public var place: String
    public var locationId: Int64
    public var name: String
    public var role: String
    public var verifiedCount: Int
    public var verifiedBytes: Int64
    public var reachable: Bool
    public var freeBytes: Int64?
    /// S3 only: what is held in each storage class (raw class name → count and bytes). Objects whose class was not
    /// recorded are listed under the location's default class.
    public struct ClassUsage: Codable, Sendable, Equatable { public var count: Int; public var bytes: Int64; public init(count: Int, bytes: Int64) { self.count = count; self.bytes = bytes } }
    public var byClass: [String: ClassUsage] = [:]
    /// Estimated monthly storage bill for an S3 place, from the per-class usage.
    public var monthlyUSD: Double {
        byClass.reduce(0) { sum, kv in sum + (S3StorageClass(rawValue: kv.key) ?? .standard).monthlyUSD(count: kv.value.count, bytes: kv.value.bytes) }
    }
    public init(place: String, locationId: Int64, name: String, role: String, verifiedCount: Int, verifiedBytes: Int64, reachable: Bool, freeBytes: Int64?) {
        self.place = place; self.locationId = locationId; self.name = name; self.role = role
        self.verifiedCount = verifiedCount; self.verifiedBytes = verifiedBytes; self.reachable = reachable; self.freeBytes = freeBytes
    }
}

public struct LocationStats: Codable, Sendable, Equatable, Identifiable {
    public var id: Int64
    public var name: String
    public var kind: String
    public var role: String = "tracked"
    public var place: String = "external"
    public var verifiedCount: Int
    public var verifiedBytes: Int64
    public var unverifiedCount: Int
    public var missingCount: Int
    public var corruptCount: Int
    public var pendingJobs: Int
    public var freeBytes: Int64?
    public var reachable: Bool
}
