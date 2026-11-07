#if os(macOS)
import Foundation

/// what a ledger folder's git repository has to send; as of the last fetch for `ahead` and `behind`
public struct FolderGitStatus: Equatable, Sendable {
    /// every changed file, new or removed, as git lists them from the folder
    public let paths: [String]
    public let ahead: Int
    public let behind: Int
    let conflicted: Bool

    public var canSync: Bool { !paths.isEmpty || ahead > 0 }
}

/// nil unless the folder is the top of a repository on a branch with an upstream: elsewhere there is nothing to push to
public func folderGitStatus(_ folder: URL) -> FolderGitStatus? {
    guard (try? runGit(["rev-parse", "--show-prefix"], in: folder))?.trimmingCharacters(in: .whitespacesAndNewlines) == "",
          let text = try? runGit(["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"], in: folder) else { return nil }
    return parseGitStatus(text)
}

func parseGitStatus(_ text: String) -> FolderGitStatus? {
    var tokens = text.split(separator: "\0").map(String.init)[...]
    guard let branch = tokens.popFirst(), branch.hasPrefix("## "), branch.contains("...") else { return nil }
    let count = { (word: String) -> Int in
        guard let range = branch.range(of: "\(word) ") else { return 0 }
        return Int(branch[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }
    var paths: [String] = []
    var conflicted = false
    while let entry = tokens.popFirst(), entry.count > 3 {
        let code = String(entry.prefix(2))
        if code.contains("U") || code == "AA" || code == "DD" { conflicted = true }
        paths.append(String(entry.dropFirst(3)))
        // a rename or copy is followed by the path it came from
        if code.first == "R" || code.first == "C", let origin = tokens.popFirst() { paths.append(origin) }
    }
    return FolderGitStatus(paths: paths, ahead: count("ahead"), behind: count("behind"), conflicted: conflicted)
}

/// Commits `paths` and nothing else, then pushes. Never merges: when the remote has moved on nothing is committed. A push that
/// fails leaves the commit here, and calling this again sends it.
public func syncFolderGit(_ folder: URL, paths: [String]) throws {
    try runGit(["fetch", "--quiet"], in: folder)
    guard let status = folderGitStatus(folder) else { throw FolderSaveError(message: tr("这个文件夹不能推送", "This folder can't be pushed")) }
    guard !status.conflicted else { throw FolderSaveError(message: tr("账本有未解决的冲突，没有提交", "The ledger has unresolved conflicts: nothing was committed")) }
    guard status.behind == 0 else { throw FolderSaveError(message: tr("远端有新提交，请先拉取，没有提交", "The remote has new commits: pull first. Nothing was committed")) }
    let changed = paths.filter { status.paths.contains($0) }
    if !changed.isEmpty {
        let message = changed.count == 1 ? tr("更新 \(changed[0])", "Update \(changed[0])") : tr("更新 \(changed.count) 个文件", "Update \(changed.count) files")
        try runGit(["add", "-A", "--"] + changed, in: folder)
        try runGit(["commit", "--quiet", "-m", message, "--"] + changed, in: folder)
    }
    guard !changed.isEmpty || status.ahead > 0 else { return }
    do {
        try runGit(["push", "--quiet"], in: folder)
    } catch {
        throw FolderSaveError(message: tr("已提交到本机，但推送失败：\(error.localizedDescription)", "Committed here, but the push failed: \(error.localizedDescription)"))
    }
}

/// git as this user has set it up, wherever it is installed; an app started from the Finder has a short PATH, and no terminal to ask for a password on
@discardableResult
func runGit(_ arguments: [String], in folder: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "--no-optional-locks", "--literal-pathspecs"] + arguments
    process.currentDirectoryURL = folder
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
    environment["GIT_TERMINAL_PROMPT"] = "0"
    process.environment = environment
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let timeout = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
    defer { timeout.cancel() }
    // both are read at once: git stops when either pipe fills
    let errorText = ReadText()
    let reading = DispatchGroup()
    DispatchQueue.global().async(group: reading) { errorText.value = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    reading.wait()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = errorText.value.trimmingCharacters(in: .whitespacesAndNewlines)
        throw FolderSaveError(message: message.isEmpty ? tr("git 没有完成", "git didn't finish") : message)
    }
    return text
}

private final class ReadText: @unchecked Sendable {
    var value = ""
}
#endif
