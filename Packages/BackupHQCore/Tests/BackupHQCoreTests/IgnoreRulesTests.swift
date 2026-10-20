import XCTest
@testable import BackupHQCore

final class IgnoreRulesTests: XCTestCase {
    func testNameRulesMatchAtAnyDepthIgnoringCase() {
        let r = IgnoreRules(["node_modules", "*.tmp", "# a note", "", "  DerivedData  "])
        XCTAssertTrue(r.matches(name: "node_modules"))
        XCTAssertTrue(r.matches(name: "Node_Modules"))
        XCTAssertTrue(r.matches(name: "draft.TMP"))
        XCTAssertFalse(r.matches(name: "draft.tmp.txt"))
        XCTAssertTrue(r.shouldSkip(relPath: "web/app/node_modules/left-pad/index.js"))
        XCTAssertTrue(r.shouldSkip(relPath: "Build/DerivedData/x.o"))
        XCTAssertFalse(r.shouldSkip(relPath: "web/app/src/index.js"))
        XCTAssertEqual(r.namePatterns.count, 3)
    }

    func testPathRulesAreRelativeToTheFolder() {
        let r = IgnoreRules(["Exports/*", "/Scratch/", "Photos/*/Previews"])
        XCTAssertTrue(r.shouldSkip(relPath: "Exports/2024/a.jpg"))
        XCTAssertFalse(r.shouldSkip(relPath: "Other/Exports/a.jpg"))
        XCTAssertTrue(r.shouldSkip(relPath: "Scratch"))
        XCTAssertTrue(r.shouldSkip(relPath: "Photos/2019/Previews"))
        XCTAssertFalse(r.shouldSkip(relPath: "Photos/2019/Originals/x.dng"))
    }

    func testStandardListSkipsBuildOutputButNotGit() {
        let r = IgnoreRules(IgnoreRules.standard)
        XCTAssertTrue(r.shouldSkip(relPath: "Packages/Core/.build/debug/x.o"))
        XCTAssertTrue(r.shouldSkip(relPath: "Lightroom Catalog Previews.lrdata/1/a.lrprev"))
        XCTAssertFalse(r.shouldSkip(relPath: ".git/objects/ab/cdef"))
        XCTAssertFalse(r.shouldSkip(relPath: "Lightroom Catalog.lrcat"))
    }
}
