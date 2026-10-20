import Foundation

public struct EngineSettings: Codable, Sendable, Equatable {
    public var hashWorkers = 2
    public var importWorkers = 2
    public var uploadWorkers = 3
    public var verifyWorkers = 1
    /// Move files out of the source when source and library are on the same volume (instant rename, no double space).
    public var moveWhenSameVolume = false
    /// Queue copies to a folder's targets as soon as it is scanned (Backup Now works regardless).
    public var autoUploadAfterImport = true
    /// Publish a status JSON to S3 for the phone app.
    public var publishStatusToS3 = true
    public var statusPublishIntervalSeconds = 30
    public var statusLocationId: Int64? = nil

    // MARK: Phase 3 — alerts and background care

    /// Re-hash local copies that have not been checked for this many days, while the engine is idle.
    public var verifyLocalEveryDays = 90
    /// HEAD-check S3 copies that have not been checked for this many days.
    public var verifyS3EveryDays = 30
    /// How many stale copies to queue per idle pass (keeps background checks gentle).
    public var verifyBatchSize = 200
    /// Queue background verification and self-healing at all.
    public var backgroundMaintenance = true
    /// Re-copy a target's copy automatically when a check finds it corrupt or missing and the owner still has the file.
    public var selfHeal = true
    /// Alert when a folder's uncovered bytes exceed this (so one new photo does not shout).
    public var alertVulnerableThresholdBytes: Int64 = 100_000_000
    /// Alert when a tracked disk has not been seen for this many days.
    public var alertDiskUnseenDays = 14
    /// Alert when a library/backup disk has less than this percent free.
    public var alertFreeSpacePercent = 10
    /// Show macOS notifications for new alerts.
    public var notifications = true
    /// Start the engine when the app launches.
    public var startEngineAtLaunch = false

    // MARK: Noticing changes

    /// Look through every tracked folder when the app opens.
    public var scanAtLaunch = true
    /// Look through tracked folders again this often while the app is open (0 = only when asked).
    public var scanEveryMinutes = 60
    /// Watch tracked folders live and look through a folder a few seconds after something changes in it.
    public var watchFolders = true
    /// Look through the folders on a disk as soon as it is plugged in.
    public var scanOnMount = true
    /// After the live watch sees activity, wait this long for the folder to go quiet before looking (a burst of
    /// saves becomes one copy instead of many). A folder that never goes quiet is still looked at every 15 minutes.
    public var settleSeconds = 120
    /// Names and paths every look leaves alone (see IgnoreRules). A folder can add its own or opt out of this list.
    public var ignoreRules: [String] = IgnoreRules.standard
    /// Read Adobe Lightroom's local catalogue and show the Lightroom page. Off for a fresh install; settings saved
    /// before this switch existed decode as on, so an upgrade keeps what it had.
    public var lightroomEnabled = false

    public init() {}

    static let key = "engine.settings"

    public static func load(from db: Database) async -> EngineSettings {
        if let raw = await db.setting(key), let data = raw.data(using: .utf8), let s = try? JSONDecoder().decode(EngineSettings.self, from: data) { return s }
        var s = EngineSettings()
        // No settings were ever saved, but a Lightroom catalogue has been synced into this database: keep that page on.
        if await db.setting("lightroom.lastSync") != nil { s.lightroomEnabled = true }
        return s
    }

    public func save(to db: Database) async throws {
        let data = try JSONEncoder().encode(self)
        try await db.setSetting(Self.key, String(decoding: data, as: UTF8.self))
    }
}

// Older settings files lack the new keys; decode them with defaults.
extension EngineSettings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineSettings()
        hashWorkers = try c.decodeIfPresent(Int.self, forKey: .hashWorkers) ?? d.hashWorkers
        importWorkers = try c.decodeIfPresent(Int.self, forKey: .importWorkers) ?? d.importWorkers
        uploadWorkers = try c.decodeIfPresent(Int.self, forKey: .uploadWorkers) ?? d.uploadWorkers
        verifyWorkers = try c.decodeIfPresent(Int.self, forKey: .verifyWorkers) ?? d.verifyWorkers
        moveWhenSameVolume = try c.decodeIfPresent(Bool.self, forKey: .moveWhenSameVolume) ?? d.moveWhenSameVolume
        autoUploadAfterImport = try c.decodeIfPresent(Bool.self, forKey: .autoUploadAfterImport) ?? d.autoUploadAfterImport
        publishStatusToS3 = try c.decodeIfPresent(Bool.self, forKey: .publishStatusToS3) ?? d.publishStatusToS3
        statusPublishIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .statusPublishIntervalSeconds) ?? d.statusPublishIntervalSeconds
        statusLocationId = try c.decodeIfPresent(Int64.self, forKey: .statusLocationId)
        verifyLocalEveryDays = try c.decodeIfPresent(Int.self, forKey: .verifyLocalEveryDays) ?? d.verifyLocalEveryDays
        verifyS3EveryDays = try c.decodeIfPresent(Int.self, forKey: .verifyS3EveryDays) ?? d.verifyS3EveryDays
        verifyBatchSize = try c.decodeIfPresent(Int.self, forKey: .verifyBatchSize) ?? d.verifyBatchSize
        backgroundMaintenance = try c.decodeIfPresent(Bool.self, forKey: .backgroundMaintenance) ?? d.backgroundMaintenance
        selfHeal = try c.decodeIfPresent(Bool.self, forKey: .selfHeal) ?? d.selfHeal
        alertVulnerableThresholdBytes = try c.decodeIfPresent(Int64.self, forKey: .alertVulnerableThresholdBytes) ?? d.alertVulnerableThresholdBytes
        alertDiskUnseenDays = try c.decodeIfPresent(Int.self, forKey: .alertDiskUnseenDays) ?? d.alertDiskUnseenDays
        alertFreeSpacePercent = try c.decodeIfPresent(Int.self, forKey: .alertFreeSpacePercent) ?? d.alertFreeSpacePercent
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? d.notifications
        startEngineAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .startEngineAtLaunch) ?? d.startEngineAtLaunch
        scanAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .scanAtLaunch) ?? d.scanAtLaunch
        scanEveryMinutes = try c.decodeIfPresent(Int.self, forKey: .scanEveryMinutes) ?? d.scanEveryMinutes
        watchFolders = try c.decodeIfPresent(Bool.self, forKey: .watchFolders) ?? d.watchFolders
        scanOnMount = try c.decodeIfPresent(Bool.self, forKey: .scanOnMount) ?? d.scanOnMount
        settleSeconds = try c.decodeIfPresent(Int.self, forKey: .settleSeconds) ?? d.settleSeconds
        ignoreRules = try c.decodeIfPresent([String].self, forKey: .ignoreRules) ?? d.ignoreRules
        lightroomEnabled = try c.decodeIfPresent(Bool.self, forKey: .lightroomEnabled) ?? true
    }
}
