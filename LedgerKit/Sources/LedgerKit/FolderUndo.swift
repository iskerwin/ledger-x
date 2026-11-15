import Foundation

/// What a written save did to a folder, enough to put it back (`undoFolderChange`) and do it again (`redoFolderChange`):
/// each text file as it was and as it was written, the files it added, and the files it moved to the Trash
public struct FolderChange: Sendable {
    /// in the order they were written; `before` nil: the file was new
    var files: [(path: String, before: String?, after: String)]
    var blobs: [(path: String, data: Data)]
    /// where each was in the folder, and where it went in the Trash
    var trashed: [(path: String, url: URL)] = []

    /// several saves made one after another as one: each file from what it was before the first to what the last left
    public static func merged(_ changes: [FolderChange]) -> FolderChange {
        var files: [(path: String, before: String?, after: String)] = []
        for change in changes {
            for file in change.files {
                if let i = files.firstIndex(where: { $0.path == file.path }) { files[i].after = file.after } else { files.append(file) }
            }
        }
        return FolderChange(files: files, blobs: changes.flatMap(\.blobs), trashed: changes.flatMap(\.trashed))
    }

    public var isEmpty: Bool { files.isEmpty && blobs.isEmpty && trashed.isEmpty }
}

/// The folder put back as it was before `change`, only while every file it touched is still as it left them: changed since,
/// nothing is written. Trashed files come back first and added ones go last, so no line points at a missing file on the way.
/// What to give `redoFolderChange` to do it again.
@discardableResult
public func undoFolderChange(_ change: FolderChange, folder: URL) throws -> FolderChange {
    let fm = FileManager.default
    for file in change.files where try current(file.path, folder) != file.after { throw changedSince(file.path, undoing: true) }
    for blob in change.blobs where (try? Data(contentsOf: folder.appendingPathComponent(blob.path))) != blob.data { throw changedSince(blob.path, undoing: true) }
    for item in change.trashed where fm.fileExists(atPath: folder.appendingPathComponent(item.path).path) || !fm.fileExists(atPath: item.url.path) {
        throw changedSince(item.path, undoing: true)
    }
    for item in change.trashed { try fm.moveItem(at: item.url, to: folder.appendingPathComponent(item.path)) }
    for file in change.files.reversed() {
        let url = folder.appendingPathComponent(file.path)
        if let before = file.before { try coordinatedWrite(url, before) } else { try fm.removeItem(at: url) }
    }
    for blob in change.blobs { try fm.trashItem(at: folder.appendingPathComponent(blob.path), resultingItemURL: nil) }
    return change
}

/// `change` done again after `undoFolderChange`, only while the folder is still as that left it; what to undo next time
@discardableResult
public func redoFolderChange(_ change: FolderChange, folder: URL) throws -> FolderChange {
    let fm = FileManager.default
    for file in change.files where try current(file.path, folder) != file.before { throw changedSince(file.path, undoing: false) }
    for blob in change.blobs where fm.fileExists(atPath: folder.appendingPathComponent(blob.path).path) { throw changedSince(blob.path, undoing: false) }
    for item in change.trashed where !fm.fileExists(atPath: folder.appendingPathComponent(item.path).path) { throw changedSince(item.path, undoing: false) }
    for blob in change.blobs {
        let url = folder.appendingPathComponent(blob.path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try blob.data.write(to: url, options: .withoutOverwriting)
    }
    for file in change.files { try coordinatedWrite(folder.appendingPathComponent(file.path), file.after) }
    var trashed: [(path: String, url: URL)] = []
    for item in change.trashed {
        var url: NSURL?
        try fm.trashItem(at: folder.appendingPathComponent(item.path), resultingItemURL: &url)
        trashed.append((item.path, (url as URL?) ?? item.url))
    }
    return FolderChange(files: change.files, blobs: change.blobs, trashed: trashed)
}

/// the file's text now; nil when it isn't there
private func current(_ path: String, _ folder: URL) throws -> String? {
    let url = folder.appendingPathComponent(path)
    return FileManager.default.fileExists(atPath: url.path) ? try coordinatedRead(url) : nil
}

private func changedSince(_ path: String, undoing: Bool) -> FolderSaveError {
    undoing ? FolderSaveError(message: tr("\(path) 之后又被改动过，没有撤销", "\(path) has changed since: nothing was undone"))
        : FolderSaveError(message: tr("\(path) 之后又被改动过，没有重做", "\(path) has changed since: nothing was redone"))
}
