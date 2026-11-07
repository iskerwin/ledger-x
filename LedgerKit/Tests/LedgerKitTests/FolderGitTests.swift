#if os(macOS)
import XCTest
@testable import LedgerKit

final class FolderGitTests: XCTestCase {
    private var root: URL!
    private var remote: URL!
    private var folder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        remote = root.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try runGit(["init", "--quiet", "--bare", "--initial-branch=main"], in: remote)
        folder = try clone(as: "ledger")
        try write("main.bean", "; start\n")
        try commitAndPush(folder)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func clone(as name: String) throws -> URL {
        try runGit(["clone", "--quiet", remote.path, name], in: root)
        let url = root.appendingPathComponent(name)
        try runGit(["config", "user.name", "Sample"], in: url)
        try runGit(["config", "user.email", "sample@example.com"], in: url)
        return url
    }

    private func commitAndPush(_ url: URL) throws {
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "--quiet", "-m", "Sample"], in: url)
        try runGit(["push", "--quiet", "-u", "origin", "main"], in: url)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func remoteFile(_ path: String) throws -> String {
        try runGit(["show", "main:\(path)"], in: remote)
    }

    func testChangedFilesAreCommittedAndPushed() throws {
        try write("main.bean", "; changed\n")
        try write("journals/2026 [a].bean", "; new\n")
        let status = try XCTUnwrap(folderGitStatus(folder))
        XCTAssertEqual(Set(status.paths), ["main.bean", "journals/2026 [a].bean"])
        XCTAssertTrue(status.canSync)
        try syncFolderGit(folder, paths: status.paths)
        XCTAssertEqual(try remoteFile("main.bean"), "; changed\n")
        XCTAssertEqual(try remoteFile("journals/2026 [a].bean"), "; new\n")
        XCTAssertFalse(try XCTUnwrap(folderGitStatus(folder)).canSync)
    }

    func testARemovedFileIsCommittedToo() throws {
        try write("old.bean", "; old\n")
        try commitAndPush(folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("old.bean"))
        try syncFolderGit(folder, paths: try XCTUnwrap(folderGitStatus(folder)).paths)
        XCTAssertThrowsError(try remoteFile("old.bean"))
    }

    func testOnlyTheListedFilesGoEvenIfOthersAreStaged() throws {
        try write("main.bean", "; changed\n")
        let listed = try XCTUnwrap(folderGitStatus(folder)).paths
        try write("later.bean", "; later\n")
        try runGit(["add", "later.bean"], in: folder)
        try syncFolderGit(folder, paths: listed)
        XCTAssertThrowsError(try remoteFile("later.bean"))
        XCTAssertEqual(try XCTUnwrap(folderGitStatus(folder)).paths, ["later.bean"])
    }

    func testWhenTheRemoteMovedOnNothingIsCommitted() throws {
        let phone = try clone(as: "phone")
        try "; phone\n".write(to: phone.appendingPathComponent("phone.bean"), atomically: true, encoding: .utf8)
        try commitAndPush(phone)
        try write("main.bean", "; changed\n")
        let head = try runGit(["rev-parse", "HEAD"], in: folder)
        XCTAssertThrowsError(try syncFolderGit(folder, paths: ["main.bean"]))
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], in: folder), head)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("main.bean"), encoding: .utf8), "; changed\n")
        XCTAssertEqual(try XCTUnwrap(folderGitStatus(folder)).behind, 1)
    }

    func testAFailedFetchCommitsNothing() throws {
        try write("main.bean", "; changed\n")
        let head = try runGit(["rev-parse", "HEAD"], in: folder)
        let moved = root.appendingPathComponent("moved.git")
        try FileManager.default.moveItem(at: remote, to: moved)
        XCTAssertThrowsError(try syncFolderGit(folder, paths: ["main.bean"]))
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], in: folder), head)
    }

    func testAFailedPushKeepsTheCommitAndTheNextTrySendsIt() throws {
        try write("main.bean", "; changed\n")
        try runGit(["config", "remote.origin.pushurl", root.appendingPathComponent("gone.git").path], in: folder)
        XCTAssertThrowsError(try syncFolderGit(folder, paths: ["main.bean"]))
        let status = try XCTUnwrap(folderGitStatus(folder))
        XCTAssertEqual(status.paths, [])
        XCTAssertEqual(status.ahead, 1)
        XCTAssertTrue(status.canSync)
        try runGit(["config", "--unset", "remote.origin.pushurl"], in: folder)
        try syncFolderGit(folder, paths: status.paths)
        XCTAssertEqual(try remoteFile("main.bean"), "; changed\n")
    }

    private func pushFromPhone(_ path: String, _ text: String) throws {
        let phone = root.appendingPathComponent("phone")
        if !FileManager.default.fileExists(atPath: phone.path) { _ = try clone(as: "phone") }
        try runGit(["pull", "--quiet"], in: phone)
        try text.write(to: phone.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try commitAndPush(phone)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    func testPullBringsInTheRemotesCommits() throws {
        try pushFromPhone("phone.bean", "; phone\n")
        try pullFolderGit(folder)
        XCTAssertEqual(try read("phone.bean"), "; phone\n")
        XCTAssertEqual(try XCTUnwrap(folderGitStatus(folder)).behind, 0)
    }

    func testPullKeepsChangesToOtherFiles() throws {
        try write("main.bean", "; changed\n")
        try pushFromPhone("phone.bean", "; phone\n")
        try pullFolderGit(folder)
        XCTAssertEqual(try read("phone.bean"), "; phone\n")
        XCTAssertEqual(try read("main.bean"), "; changed\n")
        XCTAssertEqual(try XCTUnwrap(folderGitStatus(folder)).paths, ["main.bean"])
    }

    func testPullThatWouldOverwriteALocalChangeChangesNothing() throws {
        try write("main.bean", "; changed\n")
        let head = try runGit(["rev-parse", "HEAD"], in: folder)
        try pushFromPhone("main.bean", "; phone\n")
        XCTAssertThrowsError(try pullFolderGit(folder))
        XCTAssertEqual(try read("main.bean"), "; changed\n")
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], in: folder), head)
    }

    func testPullNeverMergesCommitsOnBothSides() throws {
        try write("main.bean", "; changed\n")
        try runGit(["add", "-A"], in: folder)
        try runGit(["commit", "--quiet", "-m", "Sample"], in: folder)
        let head = try runGit(["rev-parse", "HEAD"], in: folder)
        try pushFromPhone("phone.bean", "; phone\n")
        XCTAssertThrowsError(try pullFolderGit(folder))
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], in: folder), head)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("phone.bean").path))
    }

    func testPullWithNothingNewChangesNothing() throws {
        let head = try runGit(["rev-parse", "HEAD"], in: folder)
        try pullFolderGit(folder)
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], in: folder), head)
    }

    func testAFailedFetchPullsNothing() throws {
        try FileManager.default.moveItem(at: remote, to: root.appendingPathComponent("moved.git"))
        XCTAssertThrowsError(try pullFolderGit(folder))
    }

    func testFetchingCountsTheRemotesCommitsAndChangesNoFile() throws {
        try write("main.bean", "; changed\n")
        try pushFromPhone("phone.bean", "; phone\n")
        XCTAssertEqual(try XCTUnwrap(folderGitStatus(folder)).behind, 0)
        let head = try runGit(["rev-parse", "HEAD"], in: folder)
        XCTAssertTrue(fetchFolderGit(folder))
        XCTAssertEqual(try XCTUnwrap(folderGitStatus(folder)).behind, 1)
        XCTAssertEqual(try runGit(["rev-parse", "HEAD"], in: folder), head)
        XCTAssertEqual(try read("main.bean"), "; changed\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("phone.bean").path))
    }

    func testFetchingSaysWhenTheRemoteCantBeReached() throws {
        try FileManager.default.moveItem(at: remote, to: root.appendingPathComponent("moved.git"))
        XCTAssertFalse(fetchFolderGit(folder))
    }

    func testNothingToPushWithoutARepositoryAtTheTopOrAnUpstream() throws {
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertNil(folderGitStatus(plain))
        try write("journals/a.bean", "; a\n")
        XCTAssertNil(folderGitStatus(folder.appendingPathComponent("journals")))
        try runGit(["checkout", "--quiet", "-b", "local"], in: folder)
        XCTAssertNil(folderGitStatus(folder))
    }

    func testReadingTheStatus() throws {
        let status = try XCTUnwrap(parseGitStatus("## main...origin/main [ahead 2, behind 3]\0 M a.bean\0R  new.bean\0old.bean\0?? 账本.bean\0"))
        XCTAssertEqual(status.paths, ["a.bean", "new.bean", "old.bean", "账本.bean"])
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 3)
        XCTAssertFalse(status.conflicted)
        for code in ["UU", "AA", "DD", "AU", "UD"] {
            XCTAssertTrue(try XCTUnwrap(parseGitStatus("## main...origin/main\0\(code) a.bean\0")).conflicted, code)
        }
        XCTAssertNil(parseGitStatus("## HEAD (no branch)\0"))
        XCTAssertNil(parseGitStatus("## main\0"))
    }
}
#endif
