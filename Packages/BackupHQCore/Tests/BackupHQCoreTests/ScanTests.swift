import XCTest
@testable import BackupHQCore

/// Looking through a tracked folder: new files get queued, unchanged ones are left alone, removed ones are marked
/// missing, and a file that vanishes before it is fingerprinted is skipped rather than failed.
final class ScanTests: XCTestCase {
    var dir: URL!
    var db: Database!
    var engine: JobEngine!
    var locId: Int64 = 0

    override func setUp() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("bhq-scan-\(UUID().uuidString)")
        dir = base.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        db = try Database(url: base.appendingPathComponent("catalog.sqlite"))
        var settings = EngineSettings()
        settings.publishStatusToS3 = false
        settings.watchFolders = false
        settings.scanEveryMinutes = 0
        settings.backgroundMaintenance = false
        engine = JobEngine(db: db, settings: settings)
        let loc = try await db.addLocation(kind: .local, role: .tracked, name: "folder", rootPath: dir.path, volumeUUID: nil)
        locId = loc.id
    }

    override func tearDown() async throws {
        await engine.pause()
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func write(_ rel: String, _ text: String) throws {
        let u = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: u)
    }

    /// Runs the engine until nothing is waiting or running (or the timeout passes).
    private func drain(timeout: TimeInterval = 20) async throws {
        if !(await engine.isRunning) { await engine.start() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let counts = try await db.jobCounts()
            let busy = counts.values.reduce(0) { $0 + ($1[.pending] ?? 0) + ($1[.running] ?? 0) }
            if busy == 0 { await engine.pause(); return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await engine.pause()
        XCTFail("engine did not drain in time")
    }

    func testScanFindsNewFilesSkipsKnownOnesAndNoticesRemovals() async throws {
        try write("a.txt", "alpha")
        try write("sub/b.txt", "bravo")
        try await engine.enqueueScan(locationId: locId, full: true)
        try await drain()

        var copies = try await db.copies(locationId: locId, status: .verified)
        let dbg = try await db.jobs(limit: 20).map { "\($0.kind) \($0.state) \($0.sourcePath ?? "") \($0.error ?? "")" } + (try await db.events(limit: 20)).map(\.message)
        XCTAssertEqual(Set(copies.map(\.path)), ["a.txt", "sub/b.txt"], dbg.joined(separator: "\n"))
        let firstPass = try await db.jobCounts()[.hash]?[.done] ?? 0
        XCTAssertEqual(firstPass, 2)
        let after = try await db.location(id: locId)
        XCTAssertNotNil(after?.scanCursor, "cursor should be stored after a look: \(String(describing: after))")
        XCTAssertNotNil(after?.scanDevice)

        // Nothing changed: a second look queues no fingerprinting at all.
        try await engine.enqueueScan(locationId: locId, full: false)
        try await drain()
        let secondPass = try await db.jobCounts()[.hash]?[.done] ?? 0
        XCTAssertEqual(secondPass, 2, "unchanged files must not be re-fingerprinted")

        // One new file, one removed, one changed in place.
        try await Task.sleep(nanoseconds: 1_200_000_000)   // mtime granularity
        try write("sub/c.txt", "charlie")
        try write("a.txt", "alpha-2")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("sub/b.txt"))
        // The journal is written a moment after the change; the live watch waits for things to settle before looking.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        try await engine.enqueueScan(locationId: locId, full: false)
        try await drain()

        copies = try await db.copies(locationId: locId, status: .verified)
        XCTAssertEqual(Set(copies.map(\.path)), ["a.txt", "sub/c.txt"])
        let missing = try await db.copies(locationId: locId, status: .missing)
        XCTAssertEqual(missing.map(\.path), ["sub/b.txt"])
        let hashCounts = try await db.jobCounts()[.hash] ?? [:]
        XCTAssertEqual(hashCounts[.done] ?? 0, 4, "exactly the new and the changed file were fingerprinted")
        XCTAssertEqual(hashCounts[.failed] ?? 0, 0)
        let looks = try await db.events(limit: 50).filter { $0.message.hasPrefix("Looked through folder") }
        XCTAssertEqual(looks.count, 3, looks.map(\.message).joined(separator: "\n"))
        // The second and third looks should have used the volume's change journal rather than walking everything.
        // (The second may still see the first look's own files: the journal lags a little and the cursor is taken early on purpose.)
        XCTAssertTrue(looks[0].message.contains("that changed"), looks[0].message)
        XCTAssertTrue(looks[1].message.contains("that changed") || looks[1].message.contains("nothing changed"), looks[1].message)
        XCTAssertTrue(looks[2].message.contains("whole folder"), looks[2].message)
    }

    func testJournalReplayReportsTouchedDirectory() async throws {
        let before = FSEventsJournal.currentEventId()
        XCTAssertNotNil(FSEventsJournal.deviceUUID(forPath: dir.path))
        try await Task.sleep(nanoseconds: 300_000_000)
        try write("sub/new.txt", "new")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let replay = await FSEventsJournal.replay(root: dir.resolvingSymlinksInPath().path, since: before)
        XCTAssertNotNil(replay, "journal replay returned nil")
        let paths = replay?.changes.map(\.path) ?? []
        XCTAssertTrue(paths.contains { $0.hasSuffix("/folder/sub") }, paths.joined(separator: ", "))
    }

    func testFileRemovedBeforeFingerprintingIsSkippedNotFailed() async throws {
        try write("gone.txt", "soon gone")
        try await engine.enqueueScan(locationId: locId, full: true)
        // Run the scan alone, then pull the file out from under the queued hash job.
        await engine.start()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (try await db.jobCounts()[.scan]?[.done] ?? 0) == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        await engine.pause()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("gone.txt"))
        try await drain()
        let counts = try await db.jobCounts()[.hash] ?? [:]
        XCTAssertEqual(counts[.failed] ?? 0, 0, "a vanished file is not a failure")
        XCTAssertEqual(counts[.done] ?? 0, 1)
        let job = try await db.jobs(state: .done, kind: .hash).first
        XCTAssertTrue(job?.error?.hasPrefix("Skipped") ?? false, String(describing: job?.error))
    }

    func testIgnoreRulesSkipFilesAndForgetOnesAlreadyTracked() async throws {
        try write("keep.txt", "keep")
        try write("cache/junk.o", "junk")          // "cache" is ignored by the standard list (.cache is; cache is not) → add our own rule below
        try write("sub/.build/x.o", "object")     // .build is on the standard list
        try await engine.enqueueScan(locationId: locId, full: true)
        try await drain()
        var paths = Set(try await db.copies(locationId: locId, status: .verified).map(\.path))
        XCTAssertEqual(paths, ["keep.txt", "cache/junk.o"], "standard list should skip .build only")

        // A folder rule added later drops what it covers from the inventory on the next look, without touching copies elsewhere.
        try await db.setIgnoreRules(locationId: locId, rules: ["cache"], useStandard: true)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await engine.enqueueScan(locationId: locId, full: false)
        try await drain()
        paths = Set(try await db.copies(locationId: locId, status: .verified).map(\.path))
        XCTAssertEqual(paths, ["keep.txt"])
        let missing = try await db.copies(locationId: locId, status: .missing)
        XCTAssertTrue(missing.isEmpty, "ignored files are forgotten, not marked missing")
        let look = try await db.events(limit: 5).first { $0.message.hasPrefix("Looked through") }
        XCTAssertTrue(look?.message.contains("1 now covered by ignore rules") ?? false, look?.message ?? "no look logged")
    }

    func testOldVanishedFailuresAreRequeuedAndSettled() async throws {
        let id = try await db.addJob(kind: .hash, sourcePath: dir.appendingPathComponent("never.txt").path, sourceLocationId: locId)!
        try await db.finishJob(id: id, state: .failed, error: "Source file is missing: \(dir.path)/never.txt")
        try await drain()
        let counts = try await db.jobCounts()[.hash] ?? [:]
        XCTAssertEqual(counts[.failed] ?? 0, 0)
        XCTAssertEqual(counts[.done] ?? 0, 1)
    }
}
