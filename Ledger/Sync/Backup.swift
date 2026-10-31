import Foundation
import SwiftUI
import LedgerKit

/// Zip backups of the whole ledger (as this device sees it, queued changes included) into a folder the
/// user picked in the Files app — iCloud Drive, say. Once a week automatically, or by hand.
@MainActor
enum Backup {
    static let folderKey = "backup.folder"
    static let folderNameKey = "backup.folderName"
    static let autoKey = "backup.auto"
    /// backups kept per ledger; older ones are removed
    static let keep = 12
    static let everyDays = 7

    static var folderName: String? { UserDefaults.standard.string(forKey: folderNameKey) }
    static var auto: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    static func last(_ store: Store) -> Date? { Prefs.get(store.pk("backup.last"), Date?.none) }

    /// remember the folder picked in the Files app
    static func setFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        UserDefaults.standard.set(bm, forKey: folderKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: folderNameKey)
    }

    /// a name for this ledger's backup files
    static func baseName(_ store: Store) -> String {
        let c = store.cfg
        let raw = !c.name.isEmpty ? c.name : !c.repo.isEmpty ? c.repo : !c.folderName.isEmpty ? c.folderName : "ledger"
        let safe = raw.map { "/\\:?*\"<>|".contains($0) ? "-" : $0 }
        return "Ledger-" + String(safe)
    }

    /// every ledger file, written to a temporary folder and zipped; returns the zip's URL
    static func makeZip(_ store: Store) async throws -> URL {
        var paths = Set(store.tree?.files.keys.filter(isLedgerFile) ?? [])
        for o in store.pending where isLedgerFile(o.path) && o.kind != .deleteFile { paths.insert(o.path) }
        guard !paths.isEmpty else { throw GitHubError(status: 0, message: LS("账本还没有加载")) }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let name = baseName(store) + "-" + f.string(from: Date())
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("backup-" + UUID().uuidString)
        let dir = work.appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for p in paths.sorted() {
            let text = try await store.fileText(p)
            let url = dir.appendingPathComponent(p)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        // the system zips a folder when it is read "for uploading"
        var err: NSError?
        var zipped: URL?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &err) { tmp in
            let dest = work.appendingPathComponent(name + ".zip")
            do { try fm.copyItem(at: tmp, to: dest); zipped = dest } catch { copyError = error }
        }
        if let e = err { throw e }
        if let e = copyError { throw e }
        try? fm.removeItem(at: dir)
        guard let z = zipped else { throw GitHubError(status: 0, message: LS("无法生成备份")) }
        return z
    }

    /// zip the ledger into the chosen folder and keep the newest `keep` backups of it
    @discardableResult
    static func run(_ store: Store, quiet: Bool = false) async -> Bool {
        guard let bm = UserDefaults.standard.data(forKey: folderKey) else {
            if !quiet { store.showFailure(LS("请先选择备份文件夹")) }
            return false
        }
        do {
            let zip = try await makeZip(store)
            defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
            var stale = false
            let folder = try URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            let ok = folder.startAccessingSecurityScopedResource()
            defer { if ok { folder.stopAccessingSecurityScopedResource() } }
            if stale, let fresh = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: folderKey)
            }
            let dest = folder.appendingPathComponent(zip.lastPathComponent)
            var err: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: dest, options: .forReplacing, error: &err) { u in
                do {
                    if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
                    try FileManager.default.copyItem(at: zip, to: u)
                } catch { writeError = error }
            }
            if let e = err { throw e }
            if let e = writeError { throw e }
            prune(folder, prefix: baseName(store) + "-")
            Prefs.set(store.pk("backup.last"), Date())
            if !quiet { store.showSuccess(LS("已备份到 %@", folderName ?? "")) }
            return true
        } catch {
            if !quiet { store.showFailure(LS("备份失败：%@", error.localizedDescription)) }
            return false
        }
    }

    private static func prune(_ folder: URL, prefix: String) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let mine = items.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "zip" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in mine.dropFirst(keep) {
            var err: NSError?
            NSFileCoordinator().coordinate(writingItemAt: old, options: .forDeleting, error: &err) { u in try? fm.removeItem(at: u) }
        }
    }

    /// after a load: back up when it has been a week, without saying anything unless it fails repeatedly
    static func runIfDue(_ store: Store) async {
        guard auto, !store.demo, UserDefaults.standard.data(forKey: folderKey) != nil, store.L != nil else { return }
        if let l = last(store), Date().timeIntervalSince(l) < Double(everyDays) * 86400 { return }
        await run(store, quiet: true)
    }
}
