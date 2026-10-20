import XCTest
@testable import BackupHQCore

final class ClaimTests: XCTestCase {
    func testSmallFolderIsNotStuckBehindBulkCopy() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bhq-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let db = try Database(url: base.appendingPathComponent("catalog.sqlite"))
        // 1,000 copies of a huge folder (20 → 19) queued first, then 3 copies for a small folder (17 → 16).
        for i in 0..<1000 { _ = try await db.addJob(kind: .backup, sha256: "big\(i)", sourcePath: "/big/\(i)", sourceLocationId: 20, targetLocationId: 19, bytesTotal: 1) }
        for i in 0..<3 { _ = try await db.addJob(kind: .backup, sha256: "small\(i)", sourcePath: "/small/\(i)", sourceLocationId: 17, targetLocationId: 16, bytesTotal: 1) }
        // Two workers: each round should give one slot to each folder until the small one is done.
        let first = try await db.claimJobs(kind: .backup, limit: 2)
        XCTAssertEqual(Set(first.map { $0.targetLocationId }), [19, 16])
        var smallSeen = 1
        for _ in 0..<2 {
            let next = try await db.claimJobs(kind: .backup, limit: 2)
            smallSeen += next.filter { $0.targetLocationId == 16 }.count
        }
        XCTAssertEqual(smallSeen, 3, "the three small-folder copies should all be claimed within three rounds")
        // Small queue drained: both slots go to the bulk copy again, oldest first.
        let after = try await db.claimJobs(kind: .backup, limit: 2)
        XCTAssertEqual(after.map { $0.targetLocationId }, [19, 19])
        // A higher-priority job jumps every queue.
        _ = try await db.addJob(kind: .backup, sha256: "urgent", sourcePath: "/u", sourceLocationId: 17, targetLocationId: 16, priority: 10, bytesTotal: 1)
        try await db.forgetClaimCache()
        let urgent = try await db.claimJobs(kind: .backup, limit: 1)
        XCTAssertEqual(urgent.first?.sha256, "urgent")
    }
}
