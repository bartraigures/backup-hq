import SwiftUI
import AppKit
import BackupHQCore

enum NavItem: String, CaseIterable, Identifiable {
    case home = "Home"
    case folders = "Folders"
    case lightroom = "Lightroom"
    case activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "checkmark.shield"
        case .folders: return "folder"
        case .lightroom: return "photo.on.rectangle.angled"
        case .activity: return "list.bullet.rectangle"
        }
    }
}

/// The one object the UI talks to. Owns the database and the engine; refreshes stats on a timer.
@MainActor
@Observable
final class AppModel {
    var db: Database?
    /// A second connection just for the UI's numbers, so refreshing the screen never queues behind the engine's work.
    var statsDB: Database?
    var engine: JobEngine?
    var settings = EngineSettings()

    var stats = CatalogStats()
    var locations: [Location] = []
    var lightroom = LightroomCatalog.Discovery(lightroomRunning: false)
    var lightroomSummary: LightroomCatalog.Summary?
    var lightroomStoreFileCount: Int?
    var lightroomStoreBytes: Int64?
    var syncing = false
    var syncProgress = 0
    var selection: NavItem? = .home
    var coverageSelection: Int64?
    /// Short-lived progress text shown while an action the user just took is being carried out.
    var busy: String?
    var lastStatsSeconds: Double = 0
    var badgeJobs = 0
    var badgeDuplicates = 0
    var badgeVulnerable = 0
    var errorMessage: String?
    var infoMessage: String?
    var ready = false

    private var refreshTask: Task<Void, Never>?

    func bootstrap() async {
        guard db == nil else { return }
        do {
            let tBoot = Date()
            func mark(_ what: String) { Log.engine.info("bootstrap: \(what, privacy: .public) at \(Date().timeIntervalSince(tBoot), format: .fixed(precision: 2))s") }
            let db = try Database(url: Database.defaultURL())
            self.db = db
            mark("database open")
            settings = await EngineSettings.load(from: db)
            // Nothing else is running the queue: whatever a previous process left 'running' is really waiting.
            _ = try? await db.requeueRunningJobs()
            _ = try? await db.deleteOrphanJobs()
            engine = JobEngine(db: db, settings: settings)
            mark("engine made")
            statsDB = try Database(url: Database.defaultURL())
            if settings.lightroomEnabled { lightroom = LightroomCatalog.discover() }
            mark(settings.lightroomEnabled ? "lightroom discovered" : "lightroom off")
            notifier.requestAuthorisation()
            // Look through every folder as the app opens (only what changed since last time, so it is quick).
            if settings.scanAtLaunch, let engine { _ = try? await engine.scanAllFolders(full: false) }
            mark("launch scans queued")
            await refresh()
            mark("first refresh")
            ready = true
            // Work that was queued should not sit idle after a relaunch: start if there is anything waiting, or if asked to always start.
            if (settings.startEngineAtLaunch || stats.jobsPending > 0), !CommandLine.arguments.contains("--page") { await engine?.start(); await refresh() }
            // `--page Folders` opens on that page (used for screenshots and quick checks).
            if let i = CommandLine.arguments.firstIndex(of: "--page"), i + 1 < CommandLine.arguments.count,
               let item = NavItem.allCases.first(where: { $0.rawValue.lowercased() == CommandLine.arguments[i + 1].lowercased() }) {
                selection = item
            }
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self?.refresh()
                }
            }
            if settings.lightroomEnabled { Task { await self.scanLightroomStore() } }
            observeDisks()
        } catch {
            errorMessage = "Could not open the catalogue database: \(error.localizedDescription)"
        }
    }

    /// A disk plugged in gets its folders looked through and lets jobs waiting for it carry on; one pulled out re-points the live watch.
    private func observeDisks() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor [weak self] in
                guard let self, let engine = self.engine else { return }
                await engine.diskMounted(at: url)
                await self.refresh()
                if !(await engine.isRunning), self.stats.jobsPending > 0 { await engine.start() }
                await self.refresh()
            }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let engine = self.engine else { return }
                await engine.locationsChanged()
                await self.refresh()
            }
        }
    }

    let notifier = Notifier()

    func refresh() async {
        guard let db, let engine else { return }
        let t0 = Date()
        var s: CatalogStats
        do { s = try await (statsDB ?? db).stats() }
        catch {
            // The engine may hold the write lock for a moment during a big look; the next refresh will get through.
            let text = String(describing: error)
            Log.engine.info("stats failed: \(text, privacy: .public)")
            if !text.contains("locked") && !text.contains("busy"), errorMessage == nil { errorMessage = "Could not read the catalogue: \(error.localizedDescription)" }
            return
        }
        s.engineRunning = await engine.isRunning
        s.throughputBytesPerSecond = await engine.throughput
        applyAcknowledgedOverlay(&s)
        stats = s
        lastStatsSeconds = Date().timeIntervalSince(t0)
        if lastStatsSeconds > 0.3 { Log.engine.info("stats took \(self.lastStatsSeconds, format: .fixed(precision: 2))s") }
        locations = (try? await (statsDB ?? db).locations()) ?? []
        // Badges are separate properties so the sidebar only re-renders when one of them actually changes.
        let j = stats.jobsPending + stats.jobsRunning; if badgeJobs != j { badgeJobs = j }
        if badgeDuplicates != stats.duplicateGroups { badgeDuplicates = stats.duplicateGroups }
        let v = stats.folders.filter { $0.vulnerableCount > 0 }.count; if badgeVulnerable != v { badgeVulnerable = v }
        notifier.notify(alerts: stats.alerts, enabled: settings.notifications)
        notifier.setBadge(stats.alerts.filter { $0.severity == .critical && $0.acknowledgedAt == nil }.count)
    }

    /// Cheap: just the location rows, so the UI reflects an add/toggle immediately without waiting for stats.
    func refreshLocations() async {
        guard let db else { return }
        locations = (try? await db.locations()) ?? []
    }

    var unacknowledgedAlerts: [BackupHQCore.Alert] { stats.alerts.filter { $0.acknowledgedAt == nil } }

    /// Keys acknowledged in this session. Overlaid on every refresh so the row never pops back while the write lands.
    private var acknowledgedKeys: Set<String> = []

    func acknowledge(_ a: BackupHQCore.Alert) async {
        guard let db else { return }
        // Update the screen at once; the write goes through the UI's own connection, not the engine's busy actor.
        let now = Date()
        acknowledgedKeys.insert(a.key)
        if let i = stats.alerts.firstIndex(where: { $0.key == a.key }) { stats.alerts[i].acknowledgedAt = now }
        notifier.setBadge(stats.alerts.filter { $0.severity == .critical && $0.acknowledgedAt == nil }.count)
        do { try await (statsDB ?? db).acknowledgeAlert(key: a.key) }
        catch { NSLog("BHQ acknowledge failed: %@", String(describing: error)) }
    }

    private func applyAcknowledgedOverlay(_ s: inout CatalogStats) {
        guard !acknowledgedKeys.isEmpty else { return }
        for i in s.alerts.indices where s.alerts[i].acknowledgedAt == nil && acknowledgedKeys.contains(s.alerts[i].key) {
            s.alerts[i].acknowledgedAt = Date()
        }
    }

    func runMaintenanceNow() async {
        guard let engine else { return }
        await engine.maintainNow()
        if !(await engine.isRunning), stats.jobsPending > 0 { await engine.start() }
        await refresh()
    }

    var launchAtLogin: Bool {
        get { notifier.launchesAtLogin }
        set { do { try notifier.setLaunchAtLogin(newValue) } catch { errorMessage = "Could not change launch at login: \(error.localizedDescription). This works once the app is in /Applications." } }
    }

    // MARK: Engine

    func toggleEngine() async {
        guard let engine else { return }
        if await engine.isRunning { await engine.pause() } else { await engine.start() }
        await refresh()
    }

    func saveSettings() async {
        guard let engine else { return }
        await engine.update(settings: settings)
        // Switching Lightroom on finds the catalogue now; switching it off leaves the page and the catalogue data alone.
        if settings.lightroomEnabled, lightroom.catalogURL == nil { rediscoverLightroom() }
        if !settings.lightroomEnabled, selection == .lightroom { selection = .home }
    }

    /// Pages in the sidebar: the Lightroom page only when that integration is on.
    var navItems: [NavItem] { NavItem.allCases.filter { $0 != .lightroom || settings.lightroomEnabled } }

    // MARK: Lightroom

    func syncLightroom() async {
        guard let db, let url = lightroom.catalogURL, !syncing else { return }
        syncing = true; syncProgress = 0
        defer { syncing = false }
        do {
            let catalog = LightroomCatalog(url: url)
            let summary = try await catalog.sync(into: db) { n in Task { @MainActor in self.syncProgress = n } }
            lightroomSummary = summary
            infoMessage = "Lightroom catalog synced: \(Format.count(summary.liveAssets)) assets, \(Format.bytes(summary.liveBytes))."
            await refresh()
        } catch {
            errorMessage = "Lightroom sync failed: \(error.localizedDescription)"
        }
    }

    func rediscoverLightroom() {
        lightroom = LightroomCatalog.discover()
        Task { await scanLightroomStore() }
    }

    /// Counts what Lightroom has downloaded so far into its originals store (cheap directory walk).
    func scanLightroomStore() async {
        guard let store = lightroom.originalsStoreURL else { lightroomStoreFileCount = nil; return }
        let result: (Int, Int64) = await Task.detached(priority: .utility) {
            var n = 0; var bytes: Int64 = 0
            if let urls = try? FileCopier.enumerate(root: store, keys: [.isRegularFileKey, .fileSizeKey]) {
                for u in urls {
                    if let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true, u.lastPathComponent != ".DS_Store" { n += 1; bytes += Int64(v.fileSize ?? 0) }
                }
            }
            return (n, bytes)
        }.value
        lightroomStoreFileCount = result.0
        lightroomStoreBytes = result.1
    }

    /// Registers Lightroom's originals store as a source location (if not already) and queues a scan.
    func ingestLightroomStore() async {
        guard let db, let engine, let store = lightroom.originalsStoreURL else { return }
        do {
            var loc = locations.first { $0.kind == .source && $0.rootPath == store.standardizedFileURL.path }
            if loc == nil {
                loc = try await db.addLocation(kind: .source, name: "Lightroom originals store", rootPath: store.standardizedFileURL.path, volumeUUID: LightroomCatalog.volumeUUID(of: store), autoUpload: false)
            }
            guard let loc else { return }
            try await engine.enqueueScan(locationId: loc.id)
            if !(await engine.isRunning) { await engine.start() }
            infoMessage = "Scanning Lightroom's originals store. New files are checked against the catalog and copied into your library."
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Locations

    func addLocalLocation(asPrimary: Bool, asSource: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = asSource ? "Use as Source" : "Use as Library"
        panel.message = asSource ? "Choose a folder to ingest photos from." : "Choose the folder where Backup HQ keeps your photos (an external drive is ideal)."
        guard panel.runModal() == .OK, let url = panel.url, let db else { return }
        Task {
            do {
                let vol = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
                let name = vol.map { "\($0) — \(url.lastPathComponent)" } ?? url.lastPathComponent
                _ = try await db.addLocation(kind: asSource ? .source : .local, name: name, rootPath: url.standardizedFileURL.path,
                                             volumeUUID: LightroomCatalog.volumeUUID(of: url), isPrimary: asPrimary && !asSource)
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func addS3Location(name: String, bucket: String, region: String, prefix: String, storageClass: S3StorageClass, profile: String, accessKey: String, secretKey: String, createBucket: Bool) async {
        guard let db else { return }
        do {
            let loc = try await db.addLocation(kind: .s3, name: name.isEmpty ? "S3 \(bucket)" : name, s3Region: region, s3Bucket: bucket, s3Prefix: prefix,
                                               s3StorageClass: storageClass.rawValue, s3Profile: profile.isEmpty ? nil : profile)
            if !accessKey.isEmpty && !secretKey.isEmpty {
                try CredentialStore.save(AWSCredentials(accessKeyId: accessKey, secretAccessKey: secretKey, sessionToken: nil), for: loc.id)
            }
            let client = try CredentialStore.client(for: loc)
            do { try await client.headBucket() }
            catch let e as S3Error where e.statusCode == 404 && createBucket { try await client.createBucket() }
            await engine?.invalidateS3Clients()
            infoMessage = "Connected to s3://\(bucket)."
            await refresh()
        } catch { errorMessage = "Could not add S3 location: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)" }
    }

    func update(_ loc: Location) async {
        guard let db else { return }
        do { try await db.updateLocation(loc); await engine?.invalidateS3Clients(); await refresh() } catch { errorMessage = error.localizedDescription }
    }

    func remove(_ loc: Location) async {
        guard let db else { return }
        do { try await db.deleteLocation(id: loc.id); CredentialStore.delete(for: loc.id); await engine?.locationsChanged(); await refresh() } catch { errorMessage = error.localizedDescription }
    }

    /// Saves a folder's ignore rules and looks through it so the inventory reflects them straight away.
    func setIgnoreRules(_ loc: Location, rules: [String], useStandard: Bool) async {
        guard let db, let engine else { return }
        do {
            try await db.setIgnoreRules(locationId: loc.id, rules: rules, useStandard: useStandard)
            await refreshLocations()
            await engine.locationsChanged()
            try await engine.enqueueScan(locationId: loc.id, full: false)
            if !(await engine.isRunning) { await engine.start() }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func scan(_ loc: Location) async {
        guard let engine else { return }
        do { try await engine.enqueueScan(locationId: loc.id); if !(await engine.isRunning) { await engine.start() }; await refresh() } catch { errorMessage = error.localizedDescription }
    }

    func backUpEverything(to loc: Location) async {
        guard let engine else { return }
        do {
            let n = try await engine.enqueueUploads(toLocationId: loc.id)
            infoMessage = n == 0 ? "\(loc.name) already has everything." : "Queued \(Format.count(n)) uploads to \(loc.name)."
            if n > 0, !(await engine.isRunning) { await engine.start() }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func importMissingToPrimary() async {
        guard let engine else { return }
        do {
            let n = try await engine.enqueueImportsToPrimary()
            infoMessage = n == 0 ? "The library already holds everything known." : "Queued \(Format.count(n)) imports into the library."
            if n > 0, !(await engine.isRunning) { await engine.start() }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func verify(_ loc: Location) async {
        guard let engine else { return }
        do {
            let n = try await engine.enqueueVerify(locationId: loc.id)
            infoMessage = "Queued \(Format.count(n)) checks for \(loc.name)."
            if n > 0, !(await engine.isRunning) { await engine.start() }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Tracked folders (the control centre)

    /// Pick any folder and track it in place. Targets can be ticked afterwards on its card.
    func trackFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = false
        panel.prompt = "Track"
        panel.message = "Choose a folder to keep track of. Nothing inside it will be moved or renamed."
        guard panel.runModal() == .OK, let url = panel.url, let db, let engine else { return }
        busy = "Adding \(url.lastPathComponent)…"
        Task {
            defer { busy = nil }
            do {
                let loc = try await db.addLocation(kind: .local, role: .tracked, name: url.lastPathComponent, rootPath: url.standardizedFileURL.path,
                                                   volumeUUID: LightroomCatalog.volumeUUID(of: url))
                await refreshLocations()                      // card appears now, marked "scanning"
                try await engine.enqueueScan(locationId: loc.id)
                if !(await engine.isRunning) { await engine.start() }
                await engine.locationsChanged()
                await refresh()
            } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    /// A root on the backup disk that receives copies of tracked folders.
    func addMirrorRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use for Backups"
        panel.message = "Choose (or create) the folder on the backup disk that will hold copies of your tracked folders."
        guard panel.runModal() == .OK, let url = panel.url, let db else { return }
        Task {
            do {
                let vol = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
                _ = try await db.addLocation(kind: .local, role: .mirror, name: vol.map { "\($0) backups" } ?? url.lastPathComponent, rootPath: url.standardizedFileURL.path,
                                             volumeUUID: LightroomCatalog.volumeUUID(of: url))
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    struct ReclassPrompt { var folder: Location; var target: Location; var storageClass: S3StorageClass; var count: Int; var bytes: Int64; var fromArchive: Bool }
    var reclassPrompt: ReclassPrompt?

    func setStorageClass(_ target: Location, on folder: Location, storageClass: S3StorageClass) async {
        guard let db else { return }
        if let i = locations.firstIndex(where: { $0.id == folder.id }) { locations[i].storageClasses[target.id] = storageClass.rawValue }
        do {
            try await db.setStorageClass(locationId: folder.id, targetId: target.id, storageClass: storageClass.rawValue)
            await refreshLocations()
            // Copies already in S3 keep their class unless the user says otherwise.
            let existing = try await db.copiesToReclass(ownerId: folder.id, targetId: target.id, storageClass: storageClass.rawValue)
            if !existing.isEmpty {
                let archived = existing.contains { S3StorageClass(rawValue: $0.storageClass ?? "")?.isArchived == true }
                reclassPrompt = ReclassPrompt(folder: folder, target: target, storageClass: storageClass, count: existing.count, bytes: existing.reduce(0) { $0 + ($1.size ?? 0) }, fromArchive: archived)
            }
        } catch { errorMessage = error.localizedDescription; await refreshLocations() }
    }

    func reclassExistingCopies(_ p: ReclassPrompt) async {
        guard let engine else { return }
        do {
            let n = try await engine.enqueueReclass(ownerId: p.folder.id, targetId: p.target.id)
            infoMessage = p.fromArchive
                ? "Moving \(Format.count(n)) copies to \(p.storageClass.displayName). The ones in Glacier or Deep Archive are being restored first; the move finishes on its own once S3 has them ready, usually within 12 hours."
                : "Moving \(Format.count(n)) copies to \(p.storageClass.displayName)."
            if n > 0, !(await engine.isRunning) { await engine.start() }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func setTarget(_ target: Location, on folder: Location, enabled: Bool) async {
        guard let db else { return }
        var t = Set(folder.targets)
        if enabled { t.insert(target.id) } else { t.remove(target.id) }
        // Optimistic: flip the checkbox now, persist, then let the heavy stats catch up.
        if let i = locations.firstIndex(where: { $0.id == folder.id }) { locations[i].targets = Array(t).sorted() }
        do {
            try await db.setTargets(locationId: folder.id, targets: Array(t))
            await refreshLocations()
            if enabled { await backUp(folderId: folder.id, quiet: true) } else { await refresh() }
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; await refreshLocations() }
    }

    /// Backup Now for one folder: queue only the copies its targets are missing.
    func backUp(folderId: Int64, quiet: Bool = false) async {
        guard let engine else { return }
        do {
            let n = try await engine.enqueueBackups(ownerId: folderId)
            if !quiet { infoMessage = n == 0 ? "Nothing to do — every target already has a copy." : "Queued \(Format.count(n)) copies." }
            if n > 0, !(await engine.isRunning) { await engine.start() }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func backUpEverything() async {
        guard let engine else { return }
        do {
            let n = try await engine.enqueueAllBackups()
            infoMessage = n == 0 ? "Every folder is already where you said it should be." : "Queued \(Format.count(n)) copies across your folders."
            if n > 0, !(await engine.isRunning) { await engine.start() }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func scanAll() async {
        guard let engine else { return }
        do {
            let n = try await engine.scanAllFolders(full: true)
            if n > 0, !(await engine.isRunning) { await engine.start() }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    var owners: [Location] { locations.filter { $0.isOwner && $0.enabled } }
    var targetsAvailable: [Location] { locations.filter { $0.isTarget && $0.enabled } }
    func coverage(for loc: Location) -> FolderCoverage? { stats.folders.first { $0.id == loc.id } }

    // MARK: Jobs

    func retryFailed() async { _ = try? await db?.retryFailedJobs(); await refresh() }
    func clearDone() async { _ = try? await db?.clearDoneJobs(); await refresh() }
}
