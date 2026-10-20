import Foundation

/// Runs the persistent job queue. Every step is idempotent and leaves its state in the database, so the
/// engine can be paused, the app quit, or the machine rebooted at any moment without losing track.
public actor JobEngine {
    public let db: Database
    public private(set) var settings: EngineSettings
    public private(set) var isRunning = false

    private var active: [Int64: Task<Void, Never>] = [:]
    private var activeKinds: [Int64: JobKind] = [:]
    private var schedulerTask: Task<Void, Never>?
    private var publisherTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var byteSamples: [(Date, Int64)] = []
    private var lastPublish: Date = .distantPast
    private var s3Clients: [Int64: S3Client] = [:]
    #if os(macOS)
    private var watcher: FolderWatcher?
    private var watchedRoots = Set<String>()
    #endif
    /// Folders the live watch saw activity in: when the activity began and when it was last seen (looked at once things settle).
    private var dirty: [Int64: (first: Date, last: Date)] = [:]
    private var lastScheduleCheck: Date = .distantPast

    /// Bytes moved in the last 30 seconds, per second.
    public var throughput: Double {
        let cutoff = Date().addingTimeInterval(-30)
        let recent = byteSamples.filter { $0.0 > cutoff }
        guard let first = recent.first else { return 0 }
        let span = max(1, Date().timeIntervalSince(first.0))
        return Double(recent.reduce(0) { $0 + $1.1 }) / span
    }

    public init(db: Database, settings: EngineSettings) {
        self.db = db
        self.settings = settings
        let t = Self.thresholds(from: settings)
        Task { await db.setAlertThresholds(t) }
    }

    public func update(settings: EngineSettings) async {
        self.settings = settings
        try? await settings.save(to: db)
        await db.setAlertThresholds(alertThresholds)
        await refreshWatcher()
    }

    // MARK: Lifecycle

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        _ = try? await db.requeueRunningJobs()
        _ = try? await db.deleteOrphanJobs()
        _ = try? await db.requeueVanishedFailures()
        await db.log("info", "Engine started")
        schedulerTask = Task { [weak self] in await self?.schedulerLoop() }
        publisherTask = Task { [weak self] in await self?.publisherLoop() }
        noticeTask = Task { [weak self] in await self?.noticeLoop() }
    }

    public func pause() async {
        guard isRunning else { return }
        isRunning = false
        schedulerTask?.cancel(); schedulerTask = nil
        publisherTask?.cancel(); publisherTask = nil
        noticeTask?.cancel(); noticeTask = nil
        let tasks = Array(active.values)
        for t in tasks { t.cancel() }
        for t in tasks { await t.value }
        active.removeAll(); activeKinds.removeAll()
        _ = try? await db.requeueRunningJobs()
        await refreshWatcher()
        await db.log("info", "Engine paused")
        await publishStatus(force: true)
    }

    private func schedulerLoop() async {
        while isRunning && !Task.isCancelled {
            var claimed = 0
            for kind in JobKind.allCases {
                let limit = workerLimit(kind) - activeKinds.values.filter { $0 == kind }.count
                guard limit > 0 else { continue }
                guard let jobs = try? await db.claimJobs(kind: kind, limit: limit) else { continue }
                for job in jobs {
                    claimed += 1
                    Log.engine.info("claimed \(kind.rawValue, privacy: .public) job \(job.id) \(job.displayName, privacy: .public)")
                    let t: Task<Void, Never> = Task { [weak self] in guard let self else { return }; await self.run(job) }
                    active[job.id] = t
                    activeKinds[job.id] = kind
                }
            }
            if claimed == 0 {
                if active.isEmpty { await idleMaintenance() }
                // Busy: a finishing job refills its own slot (see jobFinished), so this only needs to catch stragglers.
                try? await Task.sleep(nanoseconds: active.isEmpty ? 1_000_000_000 : 250_000_000)
            }
        }
    }

    /// Start one more job of this kind right away if a slot is free. Keeps small files flowing without waiting for the loop.
    private func refill(_ kind: JobKind) async {
        guard isRunning else { return }
        let limit = workerLimit(kind) - activeKinds.values.filter { $0 == kind }.count
        guard limit > 0, let jobs = try? await db.claimJobs(kind: kind, limit: limit) else { return }
        for job in jobs {
            let t: Task<Void, Never> = Task { [weak self] in guard let self else { return }; await self.run(job) }
            active[job.id] = t
            activeKinds[job.id] = kind
        }
    }

    // MARK: Idle maintenance (background verification + self-healing)

    private var lastMaintenance: Date = .distantPast

    /// Runs when the queue is empty, at most every 10 minutes: re-checks the oldest-verified copies and
    /// re-copies anything a check found corrupt or missing at a target. Gentle by design.
    private func idleMaintenance() async {
        guard settings.backgroundMaintenance, Date().timeIntervalSince(lastMaintenance) > 600 else { return }
        lastMaintenance = Date()
        await db.setAlertThresholds(alertThresholds)
        do {
            var queued = 0
            if settings.selfHeal {
                for (copy, targetId, ownerId) in try await db.brokenTargetCopies() {
                    guard let target = try await db.location(id: targetId), let owner = try await db.location(id: ownerId), owner.isReachable else { continue }
                    let kind: JobKind = target.role == .archive ? .upload : .backup
                    if try await db.addJob(kind: kind, sha256: copy.sha256, sourceLocationId: ownerId, targetLocationId: targetId, priority: 5, bytesTotal: copy.size ?? 0) != nil { queued += 1 }
                }
                if queued > 0 { await db.log("warning", "Self-heal: re-copying \(queued) corrupt or missing backup copies from their folders") }
            }
            var stale = 0
            var budget = settings.verifyBatchSize
            for l in try await db.locations() where l.isProtective && l.kind != .adobe && l.enabled && l.isReachable && budget > 0 {
                let days = l.kind == .s3 ? settings.verifyS3EveryDays : settings.verifyLocalEveryDays
                let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
                for c in try await db.staleCopies(locationId: l.id, olderThan: cutoff, limit: budget) {
                    if try await db.addJob(kind: .verify, sha256: c.sha256, targetLocationId: l.id, copyId: c.id, priority: -5, bytesTotal: c.size ?? 0) != nil { stale += 1; budget -= 1 }
                }
            }
            if stale > 0 { await db.log("info", "Background check: re-verifying \(stale) copies not checked recently") }
            _ = try await db.runAlertRules()
        } catch {
            Log.engine.error("maintenance failed: \(String(describing: error))")
        }
    }

    private var alertThresholds: Database.AlertThresholds { Self.thresholds(from: settings) }
    private static func thresholds(from settings: EngineSettings) -> Database.AlertThresholds {
        var t = Database.AlertThresholds()
        t.vulnerableBytes = settings.alertVulnerableThresholdBytes
        t.diskUnseenDays = settings.alertDiskUnseenDays
        t.freeSpacePercent = settings.alertFreeSpacePercent
        t.staleLocalDays = settings.verifyLocalEveryDays
        t.staleS3Days = settings.verifyS3EveryDays
        t.lightroomEnabled = settings.lightroomEnabled
        return t
    }

    /// Run the maintenance pass now regardless of the timer (CLI `maintain`, or a user action).
    public func maintainNow() async {
        lastMaintenance = .distantPast
        await idleMaintenance()
    }

    private func workerLimit(_ kind: JobKind) -> Int {
        switch kind {
        case .scan: return 1
        case .hash: return settings.hashWorkers
        case .import, .backup: return settings.importWorkers
        case .upload: return settings.uploadWorkers
        case .verify: return settings.verifyWorkers
        case .reclass: return settings.uploadWorkers
        }
    }

    private func jobFinished(_ id: Int64) {
        let kind = activeKinds[id]
        active[id] = nil
        activeKinds[id] = nil
        if let kind, isRunning { Task { [weak self] in await self?.refill(kind) } }
    }

    private func recordBytes(_ n: Int64) {
        byteSamples.append((Date(), n))
        if byteSamples.count > 4000 { byteSamples.removeFirst(2000) }
    }

    // MARK: Running a job

    private func run(_ job: Job) async {
        defer { jobFinished(job.id) }
        do {
            switch job.kind {
            case .scan: try await runScan(job)
            case .hash: try await runHash(job)
            case .import: try await runImport(job)
            case .backup: try await runBackup(job)
            case .upload: try await runUpload(job)
            case .verify: try await runVerify(job)
            case .reclass: try await runReclass(job)
            }
            try await db.finishJob(id: job.id, state: .done)
            if job.kind == .hash { await sweepCheck(job) }
        } catch is CancellationError {
            try? await db.finishJob(id: job.id, state: .pending)
        } catch let e as EngineError where { if case .cancelled = e { return true } else { return false } }() {
            try? await db.finishJob(id: job.id, state: .pending)
        } catch let e as EngineError where { if case .parked = e { return true } else { return false } }() {
            if case .parked(let secs, let reason) = e {
                try? await db.finishJob(id: job.id, state: .pending, error: reason, notBefore: Date().addingTimeInterval(secs))
            }
        } catch let e as EngineError where { if case .sourceChanged = e { return true } else { return false } }() {
            // Not a failure: the file was edited after its scan; a fresh hash job has been queued and will make its own copies.
            try? await db.finishJob(id: job.id, state: .done, error: e.errorDescription)
        } catch let e as EngineError where { if case .sourceMissing = e { return true } else { return false } }() {
            await settleVanishedSource(job)
        } catch let e as EngineError where { if case .noLocalCopy = e { return true } else { return false } }() {
            // The catalogue no longer lists this content in the folder: the file was edited or removed after the copy was
            // queued. The current version has its own fingerprint and copy jobs, so there is nothing left to do here —
            // unless the folder's disk is simply unplugged, in which case wait for it.
            if let sid = job.sourceLocationId, let loc = try? await db.location(id: sid), loc.kind != .s3, loc.kind != .adobe, !loc.isReachable {
                try? await db.finishJob(id: job.id, state: .pending, error: "Waiting for \(loc.name) to be plugged in", notBefore: Date().addingTimeInterval(600))
            } else {
                try? await db.finishJob(id: job.id, state: .done, error: "Skipped — the file changed before it could be copied; the current version is copied separately")
            }
        } catch let e as EngineError where { if case .notReachable = e { return true } else { return false } }() {
            // A disk that is not plugged in is not a failure: wait for it (a mount tries everything waiting again at once).
            try? await db.finishJob(id: job.id, state: .pending, error: e.errorDescription, notBefore: Date().addingTimeInterval(600))
        } catch let e as S3Error where Self.isContentRace(e) {
            // The file was rewritten while it was being sent, so the body no longer matched the checksum in the header.
            // Not a failure: wait for the folder to settle, then the next attempt re-checks the file and re-fingerprints it.
            await db.log("notice", "\(job.displayName) changed while it was being uploaded; will try again once the folder settles", sha256: job.sha256, jobId: job.id)
            try? await db.finishJob(id: job.id, state: .pending, error: "Changed while uploading; retrying", notBefore: Date().addingTimeInterval(Double(max(30, settings.settleSeconds))))
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            await db.log("error", "\(job.kind.rawValue) failed for \(job.displayName): \(msg)", sha256: job.sha256, jobId: job.id)
            // Transient-looking failures get retried automatically a few times; hard failures stay failed for the user to see.
            let state: JobState = (job.attempts < 4 && isTransient(error)) ? .pending : .failed
            try? await db.finishJob(id: job.id, state: state, error: msg)
            if state == .pending { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
    }

    /// S3 rejected the body because it no longer matched the checksum we computed: the source changed under us.
    private static func isContentRace(_ e: S3Error) -> Bool {
        let m = (e.message ?? "") + (e.code ?? "")
        return m.contains("XAmzContentSHA256Mismatch") || m.contains("BadDigest") || m.contains("InvalidDigest")
    }

    private func isTransient(_ error: Error) -> Bool {
        if error is URLError { return true }
        if let s3 = error as? S3Error { return s3.statusCode >= 500 || s3.statusCode == 429 || s3.statusCode == 0 }
        return false
    }

    // MARK: scan

    private struct FoundFile: Sendable { var rel: String; var size: Int64; var mtime: Double }
    private struct Listing: Sendable { var files: Set<String> = []; var dirs: Set<String> = [] }
    private struct Walk: Sendable { var files: [FoundFile] = []; var listed: [String: Listing] = [:]; var deep: [String] = [] }

    /// Looks through a folder. A full look walks everything; otherwise the volume's change journal says which
    /// directories were touched since the last look and only those are visited. No database work happens per file:
    /// what is already known is loaded once and compared in memory, and new work is queued in one transaction.
    private func runScan(_ job: Job) async throws {
        guard let locId = job.sourceLocationId, let loc = try await db.location(id: locId) else {
            throw EngineError.invalidLocation("scan job has no source location")
        }
        guard let root = loc.reachableRootURL?.standardizedFileURL else { throw EngineError.notReachable(loc.rootPath ?? loc.name) }
        let t0 = Date()
        let rootPath = root.path
        let realRoot = Self.realPath(rootPath)     // the journal reports kernel paths (/private/var/…, not /var/…)
        let wantFull = job.resumeJSON?.contains("\"full\":true") ?? false
        let ignore = ignoreRules(for: loc)
        let known = try await db.seenFiles(locationId: locId)
        Log.engine.info("scan \(loc.name, privacy: .public): \(known.count) known files loaded in \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")

        // What to visit. "" means the whole folder.
        var deepDirs: [String] = []
        var listDirs: [String] = []
        var cursor: Int64? = nil
        var device: String? = nil
        var journal = false
        var why = wantFull ? "asked for" : "first look"
        #if os(macOS)
        device = FSEventsJournal.deviceUUID(forPath: rootPath)
        var replay: FSEventsJournal.Replay? = nil
        if !wantFull, let since = loc.scanCursor, since != 0 {   // ids are unsigned 64-bit; stored as the same bits
            if device == nil { why = "no change journal on this disk" }
            else if device != loc.scanDevice { why = "the disk's change journal was reset" }
            else { replay = await FSEventsJournal.replay(root: realRoot, since: UInt64(bitPattern: since)); if replay == nil { why = "the change journal could not be replayed" } }
        }
        if let replay {
            journal = true
            cursor = Int64(bitPattern: replay.cursor)
            for ch in replay.changes {
                guard let rel = Self.relative(ch.path, roots: [rootPath, realRoot]) else { continue }
                if !rel.isEmpty, ignore.shouldSkip(relPath: rel) { continue }
                if ch.deep { deepDirs.append(rel) } else { listDirs.append(rel) }
            }
            deepDirs = Self.pruneNested(deepDirs)
            listDirs = Array(Set(listDirs)).filter { d in !deepDirs.contains { $0.isEmpty || d == $0 || d.hasPrefix($0 + "/") } }
        } else {
            cursor = Int64(bitPattern: FSEventsJournal.currentEventId())
        }
        #endif
        if !journal { deepDirs = [""]; listDirs = [] }

        // Directories we already know about, so a directory that appeared inside a changed one gets walked in full.
        var knownDirs = Set<String>()
        for path in known.keys {
            var d = Substring(path)
            while let i = d.lastIndex(of: "/") { d = d[..<i]; if !knownDirs.insert(String(d)).inserted { break } }
        }
        let plan = (deep: deepDirs, list: listDirs, knownDirs: knownDirs)
        Log.engine.info("scan \(loc.name, privacy: .public): \(journal ? "journal" : "full", privacy: .public) walk of \(plan.deep.count) deep + \(plan.list.count) listed dirs (\(why, privacy: .public))")
        let jobId = job.id, db = self.db
        let tWalk = Date()
        let walk: Walk = try await Task.detached(priority: .utility) {
            try Self.walk(root: root, deep: plan.deep, list: plan.list, knownDirs: plan.knownDirs, ignore: ignore) { n in
                Task { try? await db.updateJobProgress(id: jobId, bytesDone: Int64(n), bytesTotal: Int64(n)) }
            }
        }.value
        Log.engine.info("scan \(loc.name, privacy: .public): walked \(walk.files.count) files in \(Date().timeIntervalSince(tWalk), format: .fixed(precision: 2))s")

        // Compare in memory.
        var seenPaths = Set<String>()
        var unchanged = Set<String>()
        var toHash: [(path: String, size: Int64)] = []
        for f in walk.files {
            seenPaths.insert(f.rel)
            if let k = known[f.rel], k.size == f.size, abs(k.mtime - f.mtime) < 1, k.sha256 != nil { unchanged.insert(f.rel); continue }
            toHash.append((root.appendingPathComponent(f.rel).path, f.size))
        }
        let queued = try await db.addHashJobs(toHash, locationId: locId)
        let revived = try await db.reviveCopies(locationId: locId, paths: unchanged)
        Log.engine.info("scan \(loc.name, privacy: .public): \(queued) queued, \(revived) revived at \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")
        try await db.updateJobProgress(id: job.id, bytesDone: Int64(walk.files.count), bytesTotal: Int64(walk.files.count))

        // What is no longer there, and what the ignore rules now cover. Only for folders we inventory in place;
        // copies elsewhere are never touched.
        var gone = 0, forgotten = 0
        if loc.role == .tracked || loc.role == .library {
            let outstanding = try await db.outstandingHashPaths(locationId: locId)
            let pending = Set(outstanding.compactMap { Self.relative($0, roots: [rootPath, realRoot]) })
            if !ignore.isEmpty {
                let covered = outstanding.filter { p in Self.relative(p, roots: [rootPath, realRoot]).map { ignore.shouldSkip(relPath: $0) } ?? false }
                if !covered.isEmpty { _ = try await db.deletePendingHashJobs(locationId: locId, paths: Array(covered)) }
            }
            let deep = walk.deep, listed = walk.listed
            (gone, forgotten) = try await db.reconcileCopies(locationId: locId) { path in
                if !ignore.isEmpty, ignore.shouldSkip(relPath: path) { return .ignored }
                if seenPaths.contains(path) || pending.contains(path) { return .present }
                if deep.contains(where: { $0.isEmpty || path.hasPrefix($0 + "/") }) { return .gone }
                for (d, l) in listed where d.isEmpty || path.hasPrefix(d + "/") {
                    let rest = d.isEmpty ? Substring(path) : path.dropFirst(d.count + 1)
                    if let slash = rest.firstIndex(of: "/") { if !l.dirs.contains(String(rest[..<slash])) { return .gone } }
                    else if !l.files.contains(String(rest)) { return .gone }
                }
                return .present
            }
        }

        Log.engine.info("scan \(loc.name, privacy: .public): \(gone) gone at \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")
        // A full look also catches up on copies the folder's targets are missing, in one set-based pass. A quick look
        // does the same when nothing is left to fingerprint, as a safety net for anything a sweep missed.
        var followUps = 0
        let sweepClear = try await db.outstandingHashCount(locationId: loc.id, excluding: 0) == 0
        if !journal || sweepClear { followUps = try await queueFollowUpsForFolder(loc, root: root) }
        Log.engine.info("scan \(loc.name, privacy: .public): \(followUps) follow-ups at \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s")

        try await db.setScanCursor(locationId: locId, cursor: cursor, device: device)
        try await db.markScanned(locationId: locId)
        let took = Format.duration(Date().timeIntervalSince(t0))
        var msg = "Looked through \(loc.name) in \(took): \(Format.count(walk.files.count)) files seen, \(Format.count(queued)) new or changed to fingerprint"
        if gone > 0 { msg += ", \(Format.count(gone)) no longer present" }
        if forgotten > 0 { msg += ", \(Format.count(forgotten)) now covered by ignore rules" }
        if revived > 0 { msg += ", \(Format.count(revived)) back again" }
        if followUps > 0 { msg += ", \(Format.count(followUps)) copies queued" }
        if journal { let n = walk.deep.count + walk.listed.count; msg += n == 0 ? " (nothing changed since last time)" : " (only the \(n) folder\(n == 1 ? "" : "s") that changed)" }
        else { msg += " (whole folder: \(why))" }
        await db.log("info", msg, jobId: job.id)
    }

    /// Visits what the plan says, on a background thread, with no database access.
    /// The rules a folder's looks honour: the standard list (unless the folder opts out) plus its own.
    private func ignoreRules(for loc: Location) -> IgnoreRules {
        IgnoreRules((loc.useStandardIgnores ? settings.ignoreRules : []) + loc.ignoreRules)
    }

    private static func walk(root: URL, deep: [String], list: [String], knownDirs: Set<String>, ignore: IgnoreRules, progress: @escaping @Sendable (Int) -> Void) throws -> Walk {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        var out = Walk()
        func skip(_ name: String) -> Bool { name == ".DS_Store" || name.hasPrefix(".backuphq-tmp") || name.hasPrefix(".silasphotos-tmp") || name.hasSuffix(".bhq-partial") || name == "Thumbs.db" || name == ".localized" }
        // Paths are built from the enumerator's relative form, so "/var" versus "/private/var" spellings never matter.
        func join(_ dir: String, _ rel: String) -> String { dir.isEmpty ? rel : dir + "/" + rel }
        func walkDeep(_ dir: String) throws {
            let base = dir.isEmpty ? root : root.appendingPathComponent(dir)
            guard let en = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants, .producesRelativePathURLs]) else { return }
            while let url = en.nextObject() as? URL {
                if Task.isCancelled { throw CancellationError() }
                guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
                let name = url.lastPathComponent
                let rel = join(dir, url.relativePath)
                if v.isDirectory == true {
                    if !ignore.isEmpty, ignore.matches(name: name) || ignore.shouldSkip(relPath: rel) { en.skipDescendants() }
                    continue
                }
                guard v.isRegularFile == true else { continue }
                if skip(name) { continue }
                if !ignore.isEmpty, ignore.matches(name: name) || (!ignore.pathPatterns.isEmpty && ignore.shouldSkip(relPath: rel)) { continue }
                out.files.append(FoundFile(rel: rel, size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0))
                if out.files.count % 5000 == 0 { progress(out.files.count) }
            }
        }
        var deepDirs = deep
        var i = 0
        for dir in list {
            if Task.isCancelled { throw CancellationError() }
            let base = dir.isEmpty ? root : root.appendingPathComponent(dir)
            var listing = Listing()
            if let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                for url in entries {
                    guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
                    let name = url.lastPathComponent
                    let r = join(dir, name)
                    if !ignore.isEmpty, ignore.matches(name: name) || ignore.shouldSkip(relPath: r) { continue }
                    if v.isDirectory == true {
                        if v.isPackage == true { continue }
                        listing.dirs.insert(name)
                        if !knownDirs.contains(r) { deepDirs.append(r) }   // appeared (or was moved) here: walk it fully
                    } else if v.isRegularFile == true, !skip(name) {
                        listing.files.insert(name)
                        out.files.append(FoundFile(rel: r, size: Int64(v.fileSize ?? 0), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0))
                    }
                }
            }
            out.listed[dir] = listing
        }
        deepDirs = pruneNested(deepDirs)
        while i < deepDirs.count { try walkDeep(deepDirs[i]); i += 1 }
        out.deep = deepDirs
        // A file can be found twice when a listed directory is also inside a deep one; keep one.
        var seen = Set<String>()
        out.files = out.files.filter { seen.insert($0.rel).inserted }
        return out
    }

    /// The fully resolved spelling of a path, as the kernel (and the change journal) report it.
    private static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// Relative form of an absolute path under any of the given spellings of the root ("" for the root itself).
    private static func relative(_ path: String, roots: [String]) -> String? {
        for r in roots {
            if path == r { return "" }
            if path.hasPrefix(r + "/") { return String(path.dropFirst(r.count + 1)) }
        }
        return nil
    }

    /// Drops directories that sit inside another listed one; "" (the root) swallows everything.
    private static func pruneNested(_ dirs: [String]) -> [String] {
        if dirs.contains("") { return [""] }
        let sorted = Array(Set(dirs)).sorted { $0.count < $1.count }
        var kept: [String] = []
        for d in sorted where !kept.contains(where: { d.hasPrefix($0 + "/") }) { kept.append(d) }
        return kept
    }

    /// Set-based follow-ups for a whole folder: one query per target instead of one per file.
    private func queueFollowUpsForFolder(_ loc: Location, root: URL) async throws -> Int {
        guard settings.autoUploadAfterImport else { return 0 }
        let all = try await db.locations()
        var n = 0
        switch loc.role {
        case .source:
            if let primary = all.first(where: { $0.role == .library && $0.enabled }) {
                n += try await db.queueMissingCopies(ownerId: loc.id, targetId: primary.id, kind: .import, sourceRoot: root)
            }
        case .library, .tracked:
            for tid in loc.targets {
                guard let t = all.first(where: { $0.id == tid }), t.isTarget, t.enabled else { continue }
                n += try await db.queueMissingCopies(ownerId: loc.id, targetId: t.id, kind: t.role == .archive ? .upload : .backup, sourceRoot: root)
            }
        case .mirror, .archive, .adobe:
            break
        }
        return n
    }

    /// A job whose source file is not there any more. If the file's disk is simply unplugged, wait for it; otherwise
    /// the file was removed from the folder after being queued, which is not an error: note it and move on.
    private func settleVanishedSource(_ job: Job) async {
        if let sid = job.sourceLocationId, let loc = try? await db.location(id: sid), loc.kind != .s3, loc.kind != .adobe, !loc.isReachable {
            try? await db.finishJob(id: job.id, state: .pending, error: "Waiting for \(loc.name) to be plugged in", notBefore: Date().addingTimeInterval(600))
            return
        }
        if let sid = job.sourceLocationId, let path = job.sourcePath, let loc = try? await db.location(id: sid), let root = loc.reachableRootURL {
            let rel = relativePath(of: URL(fileURLWithPath: path), under: root)
            if let c = try? await db.copy(locationId: sid, path: rel), c.status != .missing { try? await db.setCopyStatus(id: c.id, .missing) }
            try? await db.deleteSeenFile(locationId: sid, path: rel)
        }
        let verb: String
        switch job.kind { case .hash: verb = "fingerprinted"; case .import: verb = "imported"; case .backup: verb = "copied"; case .upload: verb = "uploaded"; default: verb = "processed" }
        await db.log("notice", "\(job.displayName) was removed from its folder before it could be \(verb); skipped", sha256: job.sha256, jobId: job.id)
        try? await db.finishJob(id: job.id, state: .done, error: "Skipped — removed from the folder before it could be \(verb)")
    }

    // MARK: Noticing changes (live watch, schedule, disks plugged in)

    /// Lives beside the scheduler so a slow look at the disks never holds up the queue.
    private func noticeLoop() async {
        await refreshWatcher()
        while isRunning && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await noticeChanges()
        }
    }

    /// Cheap unless something is due.
    private func noticeChanges() async {
        let now = Date()
        let settle = Double(max(5, settings.settleSeconds))
        let atMost = max(settle, 900)
        for (id, when) in dirty where now.timeIntervalSince(when.last) > settle || now.timeIntervalSince(when.first) > atMost {
            dirty[id] = nil
            try? await enqueueScan(locationId: id, full: false)
        }
        guard now.timeIntervalSince(lastScheduleCheck) > 60 else { return }
        lastScheduleCheck = now
        if settings.scanEveryMinutes > 0, let due = try? await db.locationsDueForScan(interval: Double(settings.scanEveryMinutes) * 60) {
            for l in due { try? await enqueueScan(locationId: l.id, full: false) }
        }
        await refreshWatcher()
    }

    /// Keeps the live watch pointed at exactly the owner and source folders that are reachable right now.
    private func refreshWatcher() async {
        #if os(macOS)
        guard settings.watchFolders, isRunning else { watcher?.stop(); watcher = nil; watchedRoots = []; return }
        let locs = (try? await db.locations()) ?? []
        let roots: [FolderWatcher.Root] = locs.filter { ($0.isOwner || $0.role == .source) && $0.enabled }.compactMap { l in
            l.reachableRootURL.map { FolderWatcher.Root(id: l.id, path: $0.standardizedFileURL.path, ignore: ignoreRules(for: l)) }
        }
        let key = Set(roots.map { "\($0.id):\($0.path):\($0.ignore.namePatterns.count + $0.ignore.pathPatterns.count)" })
        if watcher != nil, key == watchedRoots { return }
        let t0 = Date()
        // Set up off the actor: talking to the file-events service can take a moment and nothing else should wait for it.
        let handler: FolderWatcher.Handler = { [weak self] ids in Task { await self?.noteChanged(ids) } }
        let fresh = await Task.detached(priority: .utility) { FolderWatcher(roots: roots, handler: handler) }.value
        watcher?.stop()
        watcher = fresh
        watchedRoots = key
        Log.engine.info("watching \(roots.count) folders live (took \(Date().timeIntervalSince(t0), format: .fixed(precision: 2))s)")
        #endif
    }

    private func noteChanged(_ ids: Set<Int64>) {
        let now = Date()
        for id in ids { dirty[id] = (dirty[id]?.first ?? now, now) }
    }

    /// Folders were added, removed or moved: re-point the live watch.
    public func locationsChanged() async { await refreshWatcher() }

    /// A disk was plugged in: look through the folders on it, let waiting jobs try again, and watch it live.
    public func diskMounted(at volume: URL) async {
        let v = volume.standardizedFileURL.path
        _ = try? await db.unparkJobs()
        lastMaintenance = .distantPast
        if settings.scanOnMount {
            for l in (try? await db.locations()) ?? [] where (l.isOwner || l.role == .source) && l.enabled {
                guard let r = l.reachableRootURL?.standardizedFileURL.path, r == v || r.hasPrefix(v + "/") else { continue }
                try? await enqueueScan(locationId: l.id, full: false)
            }
        }
        await refreshWatcher()
    }

    /// Queues a look at every reachable owner and source folder. Returns how many were queued.
    @discardableResult
    public func scanAllFolders(full: Bool) async throws -> Int {
        var n = 0
        for l in try await db.locations() where (l.isOwner || l.role == .source) && l.enabled && l.isReachable {
            try await enqueueScan(locationId: l.id, full: full); n += 1
        }
        return n
    }

    /// Records a file this engine just wrote into an owner folder, so the next look there knows it already.
    private func rememberSeen(locationId: Int64, root: URL, rel: String, sha: String) async {
        let url = root.appendingPathComponent(rel)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        try? await db.recordSeenFile(locationId: locationId, path: rel, size: size, mtime: mtime, sha256: sha)
    }

    private func relativePath(of url: URL, under root: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p.hasPrefix(r + "/") { return String(p.dropFirst(r.count + 1)) }
        return url.lastPathComponent
    }

    // MARK: hash

    private func runHash(_ job: Job) async throws {
        guard let path = job.sourcePath else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { throw EngineError.sourceMissing(path) }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let jobId = job.id
        let db = self.db
        let sha = try await Task.detached(priority: .utility) {
            var last: Int64 = 0
            return try Hashing.sha256Hex(of: url) { done in
                if done - last > 64 * 1024 * 1024 { last = done; Task { try? await db.updateJobProgress(id: jobId, bytesDone: done, bytesTotal: size) } }
            }
        }.value
        recordBytes(size)

        // Describe the content: prefer Lightroom's record (name, capture date), else the file itself.
        let cloud = try await db.cloudAssets(sha256: sha)
        let live = cloud.first { !$0.deleted } ?? cloud.first
        let ext = url.pathExtension
        let captureDate = live?.captureDate
        let day = CaptureDate.day(from: captureDate) ?? FileLayout.captureDay(for: url)
        let content = Content(sha256: sha, size: size, kind: FileLayout.kind(forExtension: ext, contentType: live?.contentType),
                              contentType: live?.contentType, displayName: live?.fileName ?? url.lastPathComponent,
                              captureDate: captureDate ?? day, captureDay: day, width: nil, height: nil, firstSeen: Date())
        try await db.upsertContent(content)

        if let locId = job.sourceLocationId, let loc = try await db.location(id: locId), let root = loc.reachableRootURL {
            let rel = relativePath(of: url, under: root)
            try await db.recordSeenFile(locationId: locId, path: rel, size: size, mtime: mtime, sha256: sha)
            try await db.upsertCopy(sha256: sha, locationId: locId, path: rel, size: size, status: .verified)
            if live == nil && cloud.isEmpty && (loc.role == .source || loc.role == .library) {
                await db.log("notice", "\(url.lastPathComponent) is not in the Lightroom catalog (kept anyway)", sha256: sha, jobId: job.id)
            }
        }
    }

    /// Copies wait until the folder's sweep is complete: the last fingerprint to finish queues them all in one set-based
    /// pass, so the queue (and the "to copy" figure) reflects the whole folder, not the part seen so far. Runs after the
    /// job is recorded as done: two fingerprints finishing together must not each see the other still running and both
    /// stand aside. If both see the folder clear, the second pass simply finds nothing left to queue.
    private func sweepCheck(_ job: Job) async {
        guard let locId = job.sourceLocationId, let loc = try? await db.location(id: locId), let root = loc.reachableRootURL else { return }
        guard (try? await db.outstandingHashCount(locationId: locId, excluding: 0)) == 0 else { return }
        if let n = try? await queueFollowUpsForFolder(loc, root: root), n > 0 {
            await db.log("info", "Sweep of \(loc.name) complete; queued \(Format.count(n)) copies", jobId: job.id)
        }
    }

    /// After content is known at `sourceLocation`: a staging source feeds the library; an owner (library or
    /// tracked folder) gets copies made at exactly the targets it lists. Mirrors and archives get nothing.
    private func queueFollowUps(sha256: String, size: Int64, sourceURL: URL, sourceLocation: Location) async throws {
        switch sourceLocation.role {
        case .source:
            guard let primary = try await db.locations().first(where: { $0.role == .library && $0.enabled }) else { return }
            if try await db.hasVerifiedCopy(sha256: sha256, locationId: primary.id) {
                try await queueTargets(owner: primary, sha256: sha256, size: size)
            } else {
                _ = try await db.addJob(kind: .import, sha256: sha256, sourcePath: sourceURL.path, sourceLocationId: sourceLocation.id, targetLocationId: primary.id, bytesTotal: size)
            }
        case .library, .tracked:
            try await queueTargets(owner: sourceLocation, sha256: sha256, size: size)
        case .mirror, .archive, .adobe:
            break
        }
    }

    /// Queues the copies an owner's targets are missing. Honours the "auto" setting; Backup Now bypasses it.
    private func queueTargets(owner: Location, sha256: String, size: Int64, force: Bool = false) async throws {
        guard force || settings.autoUploadAfterImport else { return }
        guard !owner.targets.isEmpty else { return }
        let all = try await db.locations()
        for tid in owner.targets {
            guard let t = all.first(where: { $0.id == tid }), t.isTarget, t.enabled else { continue }
            if try await db.hasVerifiedCopy(sha256: sha256, locationId: t.id) { continue }
            switch t.role {
            case .archive:
                _ = try await db.addJob(kind: .upload, sha256: sha256, sourceLocationId: owner.id, targetLocationId: t.id, bytesTotal: size)
            case .mirror:
                let srcPath = try await db.copy(sha256: sha256, locationId: owner.id).flatMap { c in owner.reachableRootURL?.appendingPathComponent(c.path).path }
                _ = try await db.addJob(kind: .backup, sha256: sha256, sourcePath: srcPath, sourceLocationId: owner.id, targetLocationId: t.id, bytesTotal: size)
            default:
                break
            }
        }
    }

    // MARK: import

    private func runImport(_ job: Job) async throws {
        guard let sha = job.sha256, let targetId = job.targetLocationId, let target = try await db.location(id: targetId) else { return }
        guard let root = target.reachableRootURL else { throw EngineError.notReachable(target.name) }
        if try await db.hasVerifiedCopy(sha256: sha, locationId: targetId) { try await queueTargets(owner: target, sha256: sha, size: job.bytesTotal); return }
        guard let content = try await db.content(sha256: sha) else { return }

        // Pick a source: the job's path if still there, else any other known local file for this content.
        var source: URL? = job.sourcePath.flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        if source == nil { source = try await db.localFileURLs(sha256: sha).first { FileManager.default.fileExists(atPath: $0.1.path) }?.1 }
        guard let src = source else { throw EngineError.sourceMissing(job.sourcePath ?? sha) }

        // Destination path, resolving collisions with different content.
        var rel = FileLayout.relativePath(day: content.captureDay, fileName: content.displayName)
        var dest = root.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: dest.path) {
            let existing = try Hashing.sha256Hex(of: dest)
            if existing == sha {
                try await db.upsertCopy(sha256: sha, locationId: targetId, path: rel, size: content.size, status: .verified); await rememberSeen(locationId: targetId, root: root, rel: rel, sha: sha)
                await db.log("info", "\(content.displayName) already present in \(target.name)", sha256: sha, jobId: job.id)
                try await queueTargets(owner: target, sha256: sha, size: content.size)
                return
            }
            rel = FileLayout.disambiguated(rel, sha256: sha)
            dest = root.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: dest.path), try Hashing.sha256Hex(of: dest) == sha {
                try await db.upsertCopy(sha256: sha, locationId: targetId, path: rel, size: content.size, status: .verified); await rememberSeen(locationId: targetId, root: root, rel: rel, sha: sha)
                try await queueTargets(owner: target, sha256: sha, size: content.size)
                return
            }
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".backuphq-tmp-\(sha.prefix(12))-\(job.id)")
        try? FileManager.default.removeItem(at: tmp)

        let sameVolume = LightroomCatalog.volumeUUID(of: src) == LightroomCatalog.volumeUUID(of: root)
        let move = settings.moveWhenSameVolume && sameVolume
        let jobId = job.id; let db = self.db; let total = content.size
        if move {
            try FileManager.default.moveItem(at: src, to: tmp)
        } else if sameVolume {
            try FileManager.default.copyItem(at: src, to: tmp)   // APFS clone: instant, no extra space until modified
        } else {
            try await Task.detached(priority: .utility) {
                try FileCopier.copy(from: src, to: tmp) { done in
                    Task { try? await db.updateJobProgress(id: jobId, bytesDone: done, bytesTotal: total) }
                }
            }.value
        }
        // Verify what landed on disk before we trust it.
        let actual = try await Task.detached(priority: .utility) { try Hashing.sha256Hex(of: tmp) }.value
        guard actual == sha else {
            if move { try? FileManager.default.moveItem(at: tmp, to: src) } else { try? FileManager.default.removeItem(at: tmp) }
            throw EngineError.hashMismatch(expected: sha, actual: actual, path: dest.path)
        }
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        recordBytes(content.size)
        try await db.upsertCopy(sha256: sha, locationId: targetId, path: rel, size: content.size, status: .verified); await rememberSeen(locationId: targetId, root: root, rel: rel, sha: sha)
        if move, let srcLoc = job.sourceLocationId, let sl = try await db.location(id: srcLoc), let sroot = sl.rootURL {
            // The source file is gone now; forget its copy row.
            let srel = relativePath(of: src, under: sroot)
            for c in try await db.copies(sha256: sha) where c.locationId == srcLoc && c.path == srel { try await db.deleteCopy(id: c.id) }
        }
        try await db.updateJobProgress(id: job.id, bytesDone: content.size, bytesTotal: content.size)
        try await queueTargets(owner: target, sha256: sha, size: content.size)
    }

    // MARK: backup (tracked folder → mirror root on a backup disk, same relative path)

    private func runBackup(_ job: Job) async throws {
        guard let sha = job.sha256, let targetId = job.targetLocationId, let target = try await db.location(id: targetId),
              let ownerId = job.sourceLocationId, let owner = try await db.location(id: ownerId) else { return }
        guard let mirrorRoot = target.reachableRootURL else { throw EngineError.notReachable(target.name) }
        guard let content = try await db.content(sha256: sha) else { return }

        // The folder may hold the same bytes under several names (byte-identical files). A mirror must show every
        // name, so one job walks all of the owner's paths for this content and copies each that is not there yet.
        let all = try await db.copies(sha256: sha)
        let ownerCopies = all.filter { $0.locationId == ownerId && $0.status == .verified }
        guard !ownerCopies.isEmpty else { throw EngineError.noLocalCopy(sha) }
        let already = Set(all.filter { $0.locationId == targetId && $0.status == .verified }.map(\.path))
        for ownerCopy in ownerCopies where !already.contains(owner.mirrorName + "/" + ownerCopy.path) {
            try await mirrorOnePath(ownerCopy: ownerCopy, sha: sha, content: content, owner: owner, target: target, mirrorRoot: mirrorRoot, job: job)
        }
    }

    private func mirrorOnePath(ownerCopy: Copy, sha: String, content: Content, owner: Location, target: Location, mirrorRoot: URL, job: Job) async throws {
        let targetId = target.id
        var src: URL? = owner.reachableRootURL?.appendingPathComponent(ownerCopy.path)
        if let s = src, !FileManager.default.fileExists(atPath: s.path) { src = nil }
        if src == nil { src = try await db.localFileURLs(sha256: sha).first { FileManager.default.fileExists(atPath: $0.1.path) }?.1 }
        guard let src else { throw EngineError.sourceMissing(ownerCopy.path) }
        try await ensureUnchanged(src, expectedSize: content.size, owner: owner, job: job)

        let rel = owner.mirrorName + "/" + ownerCopy.path
        let dest = mirrorRoot.appendingPathComponent(rel)
        if FileManager.default.fileExists(atPath: dest.path) {
            let existing = try await Task.detached(priority: .utility) { try Hashing.sha256Hex(of: dest) }.value
            if existing == sha {
                try await db.upsertCopy(sha256: sha, locationId: targetId, path: rel, size: content.size, status: .verified)
                return
            }
            // A copy a check found corrupt is garbage: overwrite it, do not keep it as a "previous version".
            var badCopy = try await db.copy(sha256: existing, locationId: targetId)
            if badCopy == nil { badCopy = try await db.copies(locationId: targetId, status: .corrupt).first { $0.path == rel } }
            if let bad = badCopy, bad.status == .corrupt {
                try FileManager.default.removeItem(at: dest)
                try await db.deleteCopy(id: bad.id)
                await db.log("warning", "Replacing corrupt copy \(rel) in \(target.name) from \(owner.name)", sha256: sha, jobId: job.id)
            } else {
            // Same path, different bytes: the file changed in the owner folder. The mirror should show the current
            // version under the real name, so the previous version moves aside under a hashed name and is kept.
            let asideRel = FileLayout.disambiguated(rel, sha256: existing)
            let aside = mirrorRoot.appendingPathComponent(asideRel)
            if FileManager.default.fileExists(atPath: aside.path) {
                if try Hashing.sha256Hex(of: aside) == existing { try FileManager.default.removeItem(at: dest) }   // already kept once
                else { throw EngineError.hashMismatch(expected: existing, actual: "different file already at \(asideRel)", path: aside.path) }
            } else {
                try FileManager.default.moveItem(at: dest, to: aside)
            }
            if let old = try await db.copy(sha256: existing, locationId: targetId), old.path == rel {
                try await db.updateCopyPath(id: old.id, path: asideRel)
            } else {
                try await db.upsertCopy(sha256: existing, locationId: targetId, path: asideRel, size: nil, status: .verified)
            }
            await db.log("info", "\(ownerCopy.path) changed in \(owner.name); previous version kept as \(asideRel) in \(target.name)", sha256: sha, jobId: job.id)
            }
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".backuphq-tmp-\(sha.prefix(12))-\(job.id)")
        try? FileManager.default.removeItem(at: tmp)
        let jobId = job.id; let db = self.db; let total = content.size
        let sameVolume = LightroomCatalog.volumeUUID(of: src) == LightroomCatalog.volumeUUID(of: mirrorRoot)
        if sameVolume {
            try FileManager.default.copyItem(at: src, to: tmp)
        } else {
            try await Task.detached(priority: .utility) {
                try FileCopier.copy(from: src, to: tmp) { done in Task { try? await db.updateJobProgress(id: jobId, bytesDone: done, bytesTotal: total) } }
            }.value
        }
        let actual = try await Task.detached(priority: .utility) { try Hashing.sha256Hex(of: tmp) }.value
        guard actual == sha else {
            try? FileManager.default.removeItem(at: tmp)
            throw EngineError.hashMismatch(expected: sha, actual: actual, path: dest.path)
        }
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        recordBytes(content.size)
        try await db.upsertCopy(sha256: sha, locationId: targetId, path: rel, size: content.size, status: .verified)
        try await db.updateJobProgress(id: job.id, bytesDone: content.size, bytesTotal: content.size)
    }

    /// A file edited between its scan and its copy would be sent under the old checksum. Catch that cheaply by
    /// size, queue a fresh hash of the file (which records the new content and its own copies), and fail this job
    /// so it is not retried against stale bytes.
    private func ensureUnchanged(_ url: URL, expectedSize: Int64, owner: Location, job: Job) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size != expectedSize else { return }
        _ = try await db.addJob(kind: .hash, sourcePath: url.path, sourceLocationId: owner.id, priority: 1, bytesTotal: max(0, size))
        await db.log("notice", "\(url.lastPathComponent) changed in \(owner.name) since it was scanned; re-hashing it", sha256: job.sha256, jobId: job.id)
        throw EngineError.sourceChanged(url.lastPathComponent)
    }

    // MARK: upload

    private func s3Client(for location: Location) throws -> S3Client {
        if let c = s3Clients[location.id] { return c }
        let c = try CredentialStore.client(for: location)
        s3Clients[location.id] = c
        return c
    }

    public func invalidateS3Clients() { s3Clients.removeAll() }

    private func runUpload(_ job: Job) async throws {
        guard let sha = job.sha256, let targetId = job.targetLocationId, let target = try await db.location(id: targetId) else { return }
        guard let content = try await db.content(sha256: sha) else { return }
        // The key mirrors the owner folder: <prefix>/<folder name>/<path inside the folder>, one object per name the
        // owner holds these bytes under. Prefer the owner the job was queued for; fall back to any local copy.
        let all = try await db.copies(sha256: sha)
        var pairs: [(Location, String, URL)] = []   // owner, path inside owner, file
        if let oid = job.sourceLocationId, let o = try await db.location(id: oid), let root = o.reachableRootURL {
            for c in all where c.locationId == oid && c.status == .verified {
                let u = root.appendingPathComponent(c.path)
                if FileManager.default.fileExists(atPath: u.path) { pairs.append((o, c.path, u)) }
            }
        }
        if pairs.isEmpty {
            let files = try await db.localFileURLs(sha256: sha).filter { FileManager.default.fileExists(atPath: $0.1.path) }
            if let (loc, u) = files.first, let root = loc.reachableRootURL { pairs.append((loc, relativePath(of: u, under: root), u)) }
        }
        guard !pairs.isEmpty else { throw EngineError.noLocalCopy(sha) }
        let client = try s3Client(for: target)
        let prefix = (target.s3Prefix ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let already = Set(all.filter { $0.locationId == targetId && $0.status == .verified }.map(\.path))
        for (owner, relPath, fileURL) in pairs {
            var key = owner.mirrorName + "/" + relPath
            if !prefix.isEmpty { key = prefix + "/" + key }
            if already.contains(key) { continue }
            try await ensureUnchanged(fileURL, expectedSize: content.size, owner: owner, job: job)
            try await uploadOne(key: key, fileURL: fileURL, sha: sha, content: content, owner: owner, target: target, client: client, job: job)
        }
    }

    private func uploadOne(key keyIn: String, fileURL: URL, sha: String, content: Content, owner: Location, target: Location, client: S3Client, job: Job) async throws {
        let targetId = target.id
        var key = keyIn
        let storage = owner.storageClass(for: target)

        // Already there (e.g. from a previous run we lost track of)? Trust it only if the recorded checksum matches.
        if let head = try await client.headObject(key: key) {
            if head.metadata["sha256"] == sha && head.size == content.size {
                try await db.upsertCopy(sha256: sha, locationId: targetId, path: key, size: head.size, status: .verified, etag: head.etag, storageClass: head.storageClass?.rawValue)
                return
            }
            if head.metadata["sha256"] != sha { key = FileLayout.disambiguated(key, sha256: sha) }
        }
        let assets = try await db.cloudAssets(sha256: sha)
        var metadata: [String: String] = ["sha256": sha, "filename": content.displayName]
        if let cd = content.captureDate { metadata["capture-date"] = cd }
        if !assets.isEmpty { metadata["lightroom-asset-ids"] = assets.map(\.assetId).joined(separator: ",") }

        let resume = job.resumeJSON.flatMap { try? JSONDecoder().decode(S3UploadResumeState.self, from: Data($0.utf8)) }
        let jobId = job.id; let db = self.db; let total = content.size
        let result = try await S3Uploader.upload(client: client, key: key, fileURL: fileURL, fileSize: content.size, sha256Hex: sha,
                                                 contentType: content.contentType, storageClass: storage, metadata: metadata, resume: resume,
                                                 onStateChange: { state in
                                                     if let data = try? JSONEncoder().encode(state) {
                                                         try? await db.updateJobProgress(id: jobId, bytesDone: state.completedParts.reduce(0) { $0 + $1.size }, bytesTotal: total, resumeJSON: String(decoding: data, as: UTF8.self))
                                                     }
                                                 },
                                                 progress: { done in Task { try? await db.updateJobProgress(id: jobId, bytesDone: done, bytesTotal: total) } })
        recordBytes(content.size)
        try await db.upsertCopy(sha256: sha, locationId: targetId, path: key, size: result.info.size, status: .verified, etag: result.info.etag, storageClass: result.info.storageClass?.rawValue ?? storage.rawValue)
        try await db.finishJob(id: job.id, state: .running, resumeJSON: .some(nil))
    }

    // MARK: verify

    private func runVerify(_ job: Job) async throws {
        guard let copyId = job.copyId, let copy = try await db.copy(id: copyId), let loc = try await db.location(id: copy.locationId) else { return }
        switch loc.kind {
        case .local, .source:
            guard let root = loc.reachableRootURL else { throw EngineError.notReachable(loc.name) }
            let url = root.appendingPathComponent(copy.path)
            guard FileManager.default.fileExists(atPath: url.path) else { try await db.setCopyStatus(id: copyId, .missing); await db.log("warning", "Missing: \(copy.path) in \(loc.name)", sha256: copy.sha256, jobId: job.id); return }
            let actual = try await Task.detached(priority: .utility) { try Hashing.sha256Hex(of: url) }.value
            recordBytes(copy.size ?? 0)
            if actual == copy.sha256 { try await db.setCopyStatus(id: copyId, .verified) }
            else { try await db.setCopyStatus(id: copyId, .corrupt); await db.log("error", "CORRUPT: \(copy.path) in \(loc.name) no longer matches its checksum", sha256: copy.sha256, jobId: job.id) }
        case .s3:
            let client = try s3Client(for: loc)
            guard let head = try await client.headObject(key: copy.path) else { try await db.setCopyStatus(id: copyId, .missing); await db.log("warning", "Missing in S3: \(copy.path)", sha256: copy.sha256, jobId: job.id); return }
            let sizeOK = head.size == (copy.size ?? head.size)
            let shaOK = head.metadata["sha256"] == nil || head.metadata["sha256"] == copy.sha256
            try await db.setCopyStatus(id: copyId, (sizeOK && shaOK) ? .verified : .corrupt)
        case .adobe:
            break
        }
    }

    // MARK: Bulk enqueue helpers (called from the UI)

    /// `full` walks the whole folder; otherwise only what the volume's change journal says was touched since the last look.
    public func enqueueScan(locationId: Int64, full: Bool = true) async throws {
        guard let loc = try await db.location(id: locationId) else { return }
        _ = try await db.addScanJob(locationId: locationId, path: loc.rootPath, full: full)
    }

    /// Backup Now for one owner: queue every copy its targets are missing. Returns the number of jobs queued.
    public func enqueueBackups(ownerId: Int64) async throws -> Int {
        guard let owner = try await db.location(id: ownerId), owner.isOwner else { return 0 }
        var n = 0
        let all = try await db.locations()
        for tid in owner.targets {
            guard let t = all.first(where: { $0.id == tid }), t.isTarget, t.enabled else { continue }
            var keyPrefix = owner.mirrorName + "/"
            if t.kind == .s3 {
                let prefix = (t.s3Prefix ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !prefix.isEmpty { keyPrefix = prefix + "/" + keyPrefix }
            }
            // One job per content; the job itself copies every name the folder holds those bytes under.
            var seen = Set<String>()
            for c in try await db.uncoveredCopies(ownerId: owner.id, targetId: t.id, keyPrefix: keyPrefix) where seen.insert(c.sha256).inserted {
                let added: Int64?
                switch t.role {
                case .archive: added = try await db.addJob(kind: .upload, sha256: c.sha256, sourceLocationId: owner.id, targetLocationId: t.id, bytesTotal: c.size ?? 0)
                case .mirror: added = try await db.addJob(kind: .backup, sha256: c.sha256, sourcePath: owner.reachableRootURL?.appendingPathComponent(c.path).path, sourceLocationId: owner.id, targetLocationId: t.id, bytesTotal: c.size ?? 0)
                default: added = nil
                }
                if added != nil { n += 1 }
            }
        }
        return n
    }

    /// Backup Now for everything: every owner, every target.
    public func enqueueAllBackups() async throws -> Int {
        var n = 0
        for o in try await db.locations() where o.isOwner && o.enabled { n += try await enqueueBackups(ownerId: o.id) }
        return n
    }

    /// Queue whatever is missing at one target, from every owner that lists it.
    /// Queue a storage-class move for every copy of this folder at the target that is not yet in the folder's chosen class.
    public func enqueueReclass(ownerId: Int64, targetId: Int64) async throws -> Int {
        guard let owner = try await db.location(id: ownerId), let target = try await db.location(id: targetId), target.kind == .s3 else { return 0 }
        let want = owner.storageClass(for: target).rawValue
        var n = 0
        for c in try await db.copiesToReclass(ownerId: ownerId, targetId: targetId, storageClass: want) {
            if try await db.addJob(kind: .reclass, sha256: c.sha256, sourceLocationId: ownerId, targetLocationId: targetId, copyId: c.id, bytesTotal: c.size ?? 0) != nil { n += 1 }
        }
        if n > 0 { await db.log("info", "Moving \(n) copies of \(owner.name) in \(target.name) to \(want)") }
        return n
    }

    /// Move one S3 copy to the folder's chosen storage class. Archived objects are restored first; the job then
    /// parks itself and checks back every half hour until S3 says the restore is complete.
    private func runReclass(_ job: Job) async throws {
        guard let copyId = job.copyId, let copy = try await db.copy(id: copyId),
              let ownerId = job.sourceLocationId, let owner = try await db.location(id: ownerId),
              let targetId = job.targetLocationId, let target = try await db.location(id: targetId), target.kind == .s3 else { return }
        let want = owner.storageClass(for: target)
        let client = try s3Client(for: target)
        guard let head = try await client.headObject(key: copy.path) else {
            try await db.setCopyStatus(id: copyId, .missing)
            throw EngineError.sourceMissing(copy.path)
        }
        if head.storageClass == want {
            _ = try await db.upsertCopy(sha256: copy.sha256, locationId: targetId, path: copy.path, size: head.size, status: .verified, etag: head.etag, storageClass: want.rawValue)
            return
        }
        if head.size > 5_000_000_000 {
            throw EngineError.invalidLocation("\(copy.path) is over 5 GB; moving it between storage classes needs a multipart copy, which is not supported yet")
        }
        if head.storageClass?.isArchived == true {
            let status = head.restoreStatus ?? ""
            if status.contains("ongoing-request=\"true\"") {
                throw EngineError.parked(seconds: 1800, reason: "Waiting for S3 to restore it from \(head.storageClass?.displayName ?? "archive")")
            }
            if !status.contains("ongoing-request=\"false\"") {
                try await client.restoreObject(key: copy.path, days: 2, tier: "Standard")
                let eta = head.storageClass == .deepArchive ? "about 12 hours" : "a few hours"
                throw EngineError.parked(seconds: 1800, reason: "Asked S3 to restore it from \(head.storageClass?.displayName ?? "archive"); that takes \(eta)")
            }
        }
        let info = try await client.changeStorageClass(key: copy.path, to: want)
        _ = try await db.upsertCopy(sha256: copy.sha256, locationId: targetId, path: copy.path, size: head.size, status: .verified, etag: info.etag ?? head.etag, storageClass: want.rawValue)
        recordBytes(head.size)
    }

    public func enqueueUploads(toLocationId targetId: Int64) async throws -> Int {
        var n = 0
        for o in try await db.owners(ofTarget: targetId) { n += try await enqueueBackups(ownerId: o.id) }
        return n
    }

    /// Queue imports for everything known at any source location but missing from the library.
    public func enqueueImportsToPrimary() async throws -> Int {
        guard let primary = try await db.locations().first(where: { $0.role == .library && $0.enabled }) else { return 0 }
        var n = 0
        for l in try await db.locations() where l.role == .source && l.enabled {
            guard let root = l.reachableRootURL else { continue }
            var offset = 0
            while true {
                let batch = try await db.copies(locationId: l.id, status: .verified, limit: 2000, offset: offset)
                if batch.isEmpty { break }
                for c in batch {
                    if try await db.hasVerifiedCopy(sha256: c.sha256, locationId: primary.id) { continue }
                    if try await db.addJob(kind: .import, sha256: c.sha256, sourcePath: root.appendingPathComponent(c.path).path, sourceLocationId: l.id, targetLocationId: primary.id, bytesTotal: c.size ?? 0) != nil { n += 1 }
                }
                offset += batch.count
            }
        }
        return n
    }

    public func enqueueVerify(locationId: Int64) async throws -> Int {
        var n = 0, offset = 0
        while true {
            let batch = try await db.copies(locationId: locationId, limit: 2000, offset: offset)
            if batch.isEmpty { break }
            for c in batch { if try await db.addJob(kind: .verify, sha256: c.sha256, targetLocationId: locationId, copyId: c.id, bytesTotal: c.size ?? 0) != nil { n += 1 } }
            offset += batch.count
        }
        return n
    }

    // MARK: Status publishing (for the phone)

    private func publisherLoop() async {
        while isRunning && !Task.isCancelled {
            await publishStatus(force: false)
            try? await Task.sleep(nanoseconds: UInt64(max(10, settings.statusPublishIntervalSeconds)) * 1_000_000_000)
        }
    }

    public func currentStats() async -> CatalogStats {
        var s = (try? await db.stats()) ?? CatalogStats()
        s.engineRunning = isRunning
        s.throughputBytesPerSecond = throughput
        return s
    }

    public func publishStatus(force: Bool) async {
        guard settings.publishStatusToS3 else { return }
        guard force || Date().timeIntervalSince(lastPublish) >= Double(settings.statusPublishIntervalSeconds) else { return }
        guard let locs = try? await db.locations() else { return }
        guard let target = locs.first(where: { $0.id == settings.statusLocationId }) ?? locs.first(where: { $0.kind == .s3 && $0.enabled }) else { return }
        lastPublish = Date()
        let stats = await currentStats()
        guard let client = try? s3Client(for: target) else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stats) else { return }
        let prefix = (target.s3Prefix ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = (prefix.isEmpty ? "" : prefix + "/") + "_backuphq/status.json"
        do { _ = try await client.putObject(key: key, data: data, contentType: "application/json", storageClass: .standard, metadata: [:]) }
        catch { Log.s3.error("status publish failed: \(String(describing: error))") }
    }
}

/// Chunked copy with progress, fsync at the end. Used across volumes (same-volume copies use APFS clones).
public enum FileCopier {
    /// Synchronous recursive listing of regular files (hidden files and package contents skipped).
    public static func enumerate(root: URL, keys: [URLResourceKey]) throws -> [URL] {
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        while let next = en.nextObject() as? URL {
            if Task.isCancelled { throw CancellationError() }
            out.append(next)
        }
        return out
    }

    public static func copy(from src: URL, to dst: URL, progress: (Int64) -> Void) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }
        var total: Int64 = 0
        let chunk = 8 * 1024 * 1024
        while true {
            if Task.isCancelled { try? FileManager.default.removeItem(at: dst); throw CancellationError() }
            let data = try input.read(upToCount: chunk) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            total += Int64(data.count)
            progress(total)
        }
        try output.synchronize()
    }
}
