import Foundation
import BackupHQCore

// backuphq-cli: a thin command-line face on the same core the Mac app uses. Handy for testing and scripting.

func arg(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ args: [String], _ name: String) -> Bool { args.contains(name) }

func usage() {
    print("""
    backuphq-cli <command> [options]
      lightroom discover                      show the Lightroom catalog and originals-store paths
      lightroom sync [--db path]              import the Lightroom catalog manifest into the Backup HQ database
      lightroom missing [--never-uploaded]    list cloud assets not yet held in any local/S3 location
      stats [--db path]                       print catalogue statistics
      locations list
      locations add-local --path P --name N [--primary] [--source]
      locations add-mirror --path P --name N  a root on a backup disk that receives copies of tracked folders
      locations add-s3 --bucket B [--region R] [--prefix X] [--class GLACIER|DEEP_ARCHIVE|GLACIER_IR|STANDARD] [--profile default]
      folders add --path P [--name N] [--to ID,ID]   track a folder in place; --to lists the mirror/S3 locations it should also be in
      folders list                            coverage of every tracked folder and the library against its targets
      folders targets ID --to ID,ID           change where a folder should also exist (empty = single copy by choice)
      folders remove ID                       stop tracking (copies already made elsewhere are left alone)
      backup [--folder ID]                    Backup Now: queue every copy the targets are missing (all folders if no id)
      alerts [--ack KEY]                      run the rules and list what needs attention
      maintain                                run the idle pass now: self-heal broken copies, queue stale re-checks
      scan --location ID | --all              queue a scan of a folder / source / library (--all: every reachable one)
      uploads --location ID                   queue whatever this S3 location is missing from the folders that target it
      imports                                 queue imports into the primary library
      verify --location ID                    queue verification of every copy at a location
      run [--seconds N] [--until-idle]        run the engine (Ctrl-C to pause safely)
      jobs [--state pending|running|failed|done] [--kind hash|import|upload|verify|scan]
      retry                                   retry all failed jobs
      dups                                    list true duplicates (same bytes, different Lightroom assets)
      events [--limit N]
      s3 ...                                  low-level S3 commands (buckets, head, selftest)
    """)
}

func parseIds(_ s: String?) -> [Int64] {
    (s ?? "").split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
}

/// The coverage matrix as text: one row per folder, one column per target.
func printCoverage(_ rows: [FolderCoverage]) {
    for f in rows {
        let state = f.reachable ? "" : "  OFFLINE"
        let policy = f.targets.isEmpty ? "single copy by choice" : "wants \(f.wantedPlaces) places"
        print("  [\(f.id)] \(f.name) (\(f.place)/\(f.role)): \(Format.count(f.fileCount)) files, \(Format.bytes(f.bytes)) — \(policy)\(state)" + (f.missingCount > 0 ? "  (\(f.missingCount) removed from folder)" : ""))
        for t in f.targets {
            let gapCount = f.fileCount - t.coveredCount
            let gap = gapCount == 0 ? "complete" : "\(Format.count(gapCount)) files / \(Format.bytes(f.bytes - t.coveredBytes)) missing" + (t.pendingCount > 0 ? " (\(t.pendingCount) queued)" : "")
            print("      → \(t.name) (\(t.place)): \(Format.count(t.coveredCount)) covered, \(gap)\(t.reachable ? "" : "  OFFLINE")")
        }
        if f.vulnerableCount > 0 { print("      ⚠ vulnerable: \(Format.count(f.vulnerableCount)) files, \(Format.bytes(f.vulnerableBytes))") }
    }
}

func openDB(_ args: [String]) throws -> Database {
    let path = arg(args, "--db").map { URL(fileURLWithPath: $0) } ?? Database.defaultURL()
    return try Database(url: path)
}

func main() async {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let cmd = args.first else { usage(); return }
    do {
        switch cmd {
        case "s3":
            try await runS3Command(Array(args.dropFirst()))
        case "lightroom":
            let sub = args.dropFirst().first ?? "discover"
            let d = LightroomCatalog.discover()
            if sub == "discover" {
                print("catalog:        \(d.catalogURL?.path ?? "not found")")
                print("catalog id:     \(d.catalogId ?? "-")")
                print("originals store:\(d.originalsStoreURL?.path ?? "unknown")")
                print("keep all originals: \(d.keepAllOriginals.map { $0 ? "ON" : "OFF" } ?? "unknown")")
                print("target cache:   \(d.targetCacheSizeBytes.map(Format.bytes) ?? "-")")
                print("lightroom running: \(d.lightroomRunning)")
            } else if sub == "sync" {
                guard let url = d.catalogURL else { print("No Lightroom catalog found"); return }
                let db = try openDB(args)
                let t0 = Date()
                let s = try await LightroomCatalog(url: url).sync(into: db) { n in if n % 10000 == 0 { print("  \(n) assets…") } }
                print("live assets: \(Format.count(s.liveAssets)) (\(Format.bytes(s.liveBytes)))  videos: \(s.videos)  deleted: \(Format.count(s.deletedAssets))  never uploaded to Adobe: \(s.neverUploaded)")
                print("took \(Format.duration(Date().timeIntervalSince(t0)))")
            } else if sub == "missing" {
                let db = try openDB(args)
                let list = try await db.cloudAssetsMissingLocally(limit: Int(arg(args, "--limit") ?? "50") ?? 50, neverUploadedOnly: flag(args, "--never-uploaded"))
                for a in list { print("\(a.captureDate ?? "----------") \(a.fileName.padding(toLength: 32, withPad: " ", startingAt: 0)) \(Format.bytes(a.fileSize))\(a.willNotUploadMaster ? "  [never uploaded]" : "")") }
            }
        case "stats":
            let db = try openDB(args)
            let s = try await db.stats()
            print("content (unique files):   \(Format.count(s.contentCount))  \(Format.bytes(s.contentBytes))")
            print("cloud assets (live):      \(Format.count(s.cloudAssetCount))  \(Format.bytes(s.cloudAssetBytes))   deleted in Lightroom: \(Format.count(s.cloudDeletedCount))")
            print("  held locally/S3:        \(Format.count(s.cloudMatchedLocallyCount))  \(Format.bytes(s.cloudMatchedLocallyBytes))")
            print("  only in Adobe:          \(Format.count(s.cloudOnlyCount))  \(Format.bytes(s.cloudOnlyBytes))")
            print("  never uploaded to Adobe:\(Format.count(s.cloudNeverUploadedCount))  \(Format.bytes(s.cloudNeverUploadedBytes))")
            print("vulnerable (below policy):\(Format.count(s.vulnerableCount))  \(Format.bytes(s.vulnerableBytes))   single copy by choice: \(Format.count(s.singleCopyByChoiceCount))  \(Format.bytes(s.singleCopyByChoiceBytes))")
            print("true duplicates:          \(s.duplicateGroups) groups, \(s.duplicateExtraCount) extra copies")
            print("jobs: pending \(s.jobsPending)  running \(s.jobsRunning)  failed \(s.jobsFailed)  done \(s.jobsDone)   to import \(Format.bytes(s.bytesPendingImport))  to back up \(Format.bytes(s.bytesPendingBackup))  to upload \(Format.bytes(s.bytesPendingUpload))")
            for l in s.perLocation {
                print("  [\(l.id)] \(l.place)/\(l.role) \(l.name): verified \(Format.count(l.verifiedCount)) (\(Format.bytes(l.verifiedBytes))) unverified \(l.unverifiedCount) missing \(l.missingCount) corrupt \(l.corruptCount) pending jobs \(l.pendingJobs) free \(l.freeBytes.map(Format.bytes) ?? "-") \(l.reachable ? "" : "OFFLINE")")
            }
            if !s.folders.isEmpty { print("coverage:"); printCoverage(s.folders) }
        case "folders":
            let db = try openDB(args)
            let sub = args.dropFirst().first ?? "list"
            switch sub {
            case "add":
                guard let p = arg(args, "--path") else { usage(); return }
                let url = URL(fileURLWithPath: p).standardizedFileURL
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { print("not a folder: \(url.path)"); return }
                let targets = parseIds(arg(args, "--to"))
                for t in targets { guard let l = try await db.location(id: t), l.isTarget else { print("location \(t) is not a backup-disk root or S3 archive"); return } }
                let l = try await db.addLocation(kind: .local, role: .tracked, name: arg(args, "--name") ?? url.lastPathComponent, rootPath: url.path,
                                                 volumeUUID: LightroomCatalog.volumeUUID(of: url), targets: targets)
                print("tracking [\(l.id)] \(l.name) (\(l.placeKind.rawValue)) \(l.rootPath ?? "")  targets: \(targets.isEmpty ? "none (single copy by choice)" : targets.map(String.init).joined(separator: ","))")
                print("next: backuphq-cli scan --location \(l.id)")
            case "targets":
                guard let id = args.dropFirst(2).first.flatMap(Int64.init) else { usage(); return }
                try await db.setTargets(locationId: id, targets: parseIds(arg(args, "--to")))
                print("targets updated; run `backup --folder \(id)` to queue the missing copies")
            case "class":
                // folders class <folderId> --target <s3Id> --class DEEP_ARCHIVE|GLACIER|GLACIER_IR|STANDARD_IA|STANDARD [--move-existing]
                guard let id = args.dropFirst(2).first.flatMap(Int64.init), let tid = arg(args, "--target").flatMap(Int64.init),
                      let cls = arg(args, "--class").flatMap({ S3StorageClass(rawValue: $0.uppercased()) }) else { usage(); return }
                try await db.setStorageClass(locationId: id, targetId: tid, storageClass: cls.rawValue)
                print("new uploads from folder \(id) to \(tid) use \(cls.displayName)")
                if args.contains("--move-existing") {
                    let engine = JobEngine(db: db, settings: await EngineSettings.load(from: db))
                    let n = try await engine.enqueueReclass(ownerId: id, targetId: tid)
                    print("queued \(n) existing copies to move (archived ones are restored first; the app's engine carries them out)")
                }
            case "remove":
                guard let id = args.dropFirst(2).first.flatMap(Int64.init), let l = try await db.location(id: id), l.role == .tracked else { print("not a tracked folder"); return }
                try await db.deleteLocation(id: id)
                print("stopped tracking \(l.name); nothing on disk or in S3 was touched")
            default:
                printCoverage(try await db.folderCoverage())
            }
        case "alerts":
            let db = try openDB(args)
            if let key = arg(args, "--ack") { try await db.acknowledgeAlert(key: key); print("acknowledged \(key)") }
            let engine = JobEngine(db: db, settings: await EngineSettings.load(from: db))
            _ = engine
            let alerts = try await db.runAlertRules()
            if alerts.isEmpty { print("no alerts — everything is as you asked") }
            for a in alerts {
                let mark = a.severity == .critical ? "‼" : (a.severity == .warning ? "⚠" : "ℹ")
                print("\(mark) [\(a.key)] \(a.title)\(a.acknowledgedAt != nil ? " (acknowledged)" : "")  since \(a.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                print("     \(a.detail)")
            }
        case "maintain":
            let db = try openDB(args)
            let engine = JobEngine(db: db, settings: await EngineSettings.load(from: db))
            await engine.maintainNow()
            let s = try await db.stats()
            print("queued: pending \(s.jobsPending) · alerts \(s.alerts.count)")
            for e in try await db.events(limit: 3) { print("  \(e.level): \(e.message)") }
        case "backup":
            let db = try openDB(args)
            let engine = JobEngine(db: db, settings: await EngineSettings.load(from: db))
            if let id = arg(args, "--folder").flatMap(Int64.init) { print("queued \(try await engine.enqueueBackups(ownerId: id)) copies") }
            else { print("queued \(try await engine.enqueueAllBackups()) copies") }
        case "locations":
            let db = try openDB(args)
            let sub = args.dropFirst().first ?? "list"
            switch sub {
            case "add-local":
                guard let p = arg(args, "--path") else { usage(); return }
                let url = URL(fileURLWithPath: p)
                let l = try await db.addLocation(kind: flag(args, "--source") ? .source : .local, name: arg(args, "--name") ?? url.lastPathComponent, rootPath: url.standardizedFileURL.path,
                                                 volumeUUID: LightroomCatalog.volumeUUID(of: url), isPrimary: flag(args, "--primary"))
                print("added location \(l.id): \(l.name) \(l.summaryLine)")
            case "add-mirror":
                guard let p = arg(args, "--path") else { usage(); return }
                let url = URL(fileURLWithPath: p).standardizedFileURL
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let l = try await db.addLocation(kind: .local, role: .mirror, name: arg(args, "--name") ?? url.lastPathComponent, rootPath: url.path,
                                                 volumeUUID: LightroomCatalog.volumeUUID(of: url))
                print("added backup-disk root \(l.id): \(l.name) \(l.summaryLine)")
            case "add-s3":
                guard let b = arg(args, "--bucket") else { usage(); return }
                let l = try await db.addLocation(kind: .s3, name: arg(args, "--name") ?? "S3 \(b)", s3Region: arg(args, "--region") ?? "eu-west-1", s3Bucket: b,
                                                 s3Prefix: arg(args, "--prefix") ?? "", s3StorageClass: arg(args, "--class") ?? "GLACIER", s3Profile: arg(args, "--profile") ?? "default")
                print("added location \(l.id): \(l.name) \(l.summaryLine)")
            default:
                for l in try await db.locations() {
                    let targets = l.targets.isEmpty ? "" : "  → \(l.targets.map(String.init).joined(separator: ","))"
                    print("[\(l.id)] \(l.placeKind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))\(l.role.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(l.isPrimary ? "★ " : "  ")\(l.name)  \(l.summaryLine)\(targets)  \(l.enabled ? "" : "(disabled)")\(l.isReachable ? "" : "  OFFLINE")")
                }
            }
        case "scan", "uploads", "imports", "verify":
            let db = try openDB(args)
            let engine = JobEngine(db: db, settings: await EngineSettings.load(from: db))
            let id = Int64(arg(args, "--location") ?? "") ?? 0
            switch cmd {
            case "scan":
                if flag(args, "--all") {
                    var n = 0
                    for l in try await db.locations() where (l.isOwner || l.role == .source) && l.enabled && l.isReachable { try await engine.enqueueScan(locationId: l.id); n += 1 }
                    print("\(n) scans queued")
                } else { try await engine.enqueueScan(locationId: id); print("scan queued") }
            case "uploads": print("queued \(try await engine.enqueueUploads(toLocationId: id)) uploads")
            case "imports": print("queued \(try await engine.enqueueImportsToPrimary()) imports")
            default: print("queued \(try await engine.enqueueVerify(locationId: id)) verifications")
            }
        case "run":
            let db = try openDB(args)
            let engine = JobEngine(db: db, settings: await EngineSettings.load(from: db))
            await engine.start()
            let deadline = arg(args, "--seconds").flatMap(Double.init).map { Date().addingTimeInterval($0) }
            let untilIdle = flag(args, "--until-idle")
            signal(SIGINT) { _ in
                print("\npausing…"); exit(0)
            }
            var lastLine = ""
            while true {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let s = await engine.currentStats()
                let line = "pending \(s.jobsPending) running \(s.jobsRunning) failed \(s.jobsFailed) done \(s.jobsDone)  \(Format.bytes(Int64(s.throughputBytesPerSecond)))/s  import left \(Format.bytes(s.bytesPendingImport)) upload left \(Format.bytes(s.bytesPendingUpload))"
                if line != lastLine { print(line); lastLine = line }
                if let deadline, Date() > deadline { break }
                if untilIdle && s.jobsPending == 0 && s.jobsRunning == 0 { break }
            }
            await engine.pause()
        case "jobs":
            let db = try openDB(args)
            let state = arg(args, "--state").flatMap(JobState.init(rawValue:))
            let kind = arg(args, "--kind").flatMap(JobKind.init(rawValue:))
            for j in try await db.jobs(state: state, kind: kind, limit: Int(arg(args, "--limit") ?? "100") ?? 100) {
                print("#\(j.id) \(j.kind.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(j.state.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(j.displayName)  \(Format.bytes(j.bytesDone))/\(Format.bytes(j.bytesTotal)) \(j.error ?? "")")
            }
        case "retry":
            let db = try openDB(args)
            print("retried \(try await db.retryFailedJobs()) jobs")
        case "dups":
            let db = try openDB(args)
            for g in try await db.duplicateGroups() { print("\(g.captureDate ?? "") \(Format.bytes(g.size))  \(g.names.joined(separator: " = "))") }
        case "events":
            let db = try openDB(args)
            for e in try await db.events(limit: Int(arg(args, "--limit") ?? "50") ?? 50).reversed() { print("\(e.time.formatted(date: .numeric, time: .standard)) [\(e.level)] \(e.message)") }
        default:
            usage()
        }
    } catch {
        FileHandle.standardError.write(Data("error: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))\n".utf8))
        exit(1)
    }
}

await main()
