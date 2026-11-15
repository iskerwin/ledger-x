import AppKit
import LedgerKit

/// What was written to the ledger folder, put back with 编辑 › 撤销 (⌘Z) in the main window and done again with 重做 (⇧⌘Z),
/// on the system's undo stack. A step is refused, with why, when the files have changed since; it lasts until the app quits
/// or another folder is opened.
@MainActor
enum SaveUndo {
    /// the main window's, set while it is up
    static weak var manager: UndoManager?
    private final class Target {}
    private static let target = Target()

    /// a save just written, named for the menu (撤销记一笔)
    static func record(_ change: FolderChange, folder: URL, name: String) {
        guard !change.isEmpty else { return }
        register(change, folder: folder, name: name, undoing: true)
    }

    /// what was written, then the step for it; the error's message for the page when writing failed
    static func commit(_ save: FolderSave, folder: URL, name: String) throws {
        record(try commitFolderSave(save, folder: folder), folder: folder, name: name)
    }

    private static var folder: URL?

    /// a folder on screen: another one's steps don't apply to it
    static func opened(_ url: URL) {
        guard url != folder else { return }
        manager?.removeAllActions(withTarget: target)
        folder = url
    }

    private static func register(_ change: FolderChange, folder: URL, name: String, undoing: Bool) {
        guard let manager else { return }
        manager.registerUndo(withTarget: target) { _ in
            MainActor.assumeIsolated {
                do {
                    let next = undoing ? try undoFolderChange(change, folder: folder) : try redoFolderChange(change, folder: folder)
                    register(next, folder: folder, name: name, undoing: !undoing)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
        manager.setActionName(name)
    }
}
