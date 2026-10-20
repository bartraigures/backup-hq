import XCTest
@testable import BackupHQCore

final class S3CostTests: XCTestCase {
    func testCostPricesEachClassSeparately() {
        var p = PlaceSummary(place: "s3", locationId: 7, name: "S3 archive", role: "archive", verifiedCount: 1768, verifiedBytes: 815_000_000, reachable: true, freeBytes: nil)
        p.byClass["STANDARD"] = .init(count: 1758, bytes: 810_900_000)
        p.byClass["DEEP_ARCHIVE"] = .init(count: 10, bytes: 4_000_000)
        // 0.8109 GB × $0.023 ≈ $0.0187, plus a hair for Deep Archive and its per-object index.
        XCTAssertEqual(p.monthlyUSD, 0.0187, accuracy: 0.0005)
        // 1.75 TB in Deep Archive is about $1.73 plus 85k objects' index (85k × 32 KB ≈ 2.8 GB at the class rate + 0.7 GB at Standard).
        var all = PlaceSummary(place: "s3", locationId: 7, name: "x", role: "archive", verifiedCount: 85_000, verifiedBytes: 1_750_000_000_000, reachable: true, freeBytes: nil)
        all.byClass["DEEP_ARCHIVE"] = .init(count: 85_000, bytes: 1_750_000_000_000)
        XCTAssertEqual(all.monthlyUSD, 1.75, accuracy: 0.03)
    }
}
