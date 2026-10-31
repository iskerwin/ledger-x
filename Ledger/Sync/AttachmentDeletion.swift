import Foundation
import LedgerKit

// 移除并删除文件: a document's record and its file in storage. The file is copied to this device first and
// deleted only once the record's removal has synced; 撤回 in 最近改动 uploads the copy again. A file that
// another record still points at is never deleted.

extension Store {
    private static let deletedKind = "deleted-attachments"
    private static func copyKind(_ id: UUID) -> String { "deleted-attachment-" + id.uuidString }

    func deletedAttachments(ledger: String? = nil) -> [DeletedAttachment] {
        if case .value(let items) = readDeletedAttachments(ledger ?? cfg.id) { return items }
        return []
    }

    private func readDeletedAttachments(_ ledger: String) -> RecoveryRead<[DeletedAttachment]> {
        let read = RecoveryFiles.read([DeletedAttachment].self, kind: Self.deletedKind, ledger: ledger)
        if case .damaged = read { noteUnreadable() }
        return read
    }

    /// false while the list is there but can't be opened: nothing may be written over it
    private func deletedAttachmentsWritable(_ ledger: String) -> Bool {
        if case .unavailable = readDeletedAttachments(ledger) { return false }
        return true
    }

    private func saveDeletedAttachments(_ items: [DeletedAttachment], ledger: String) {
        guard deletedAttachmentsWritable(ledger) else { return }
        if items.isEmpty { try? RecoveryFiles.remove(kind: Self.deletedKind, ledger: ledger) }
        else { try? RecoveryFiles.save(items, kind: Self.deletedKind, ledger: ledger) }
    }

    private func dropDeletedAttachment(_ id: UUID, ledger: String) {
        try? RecoveryFiles.removeData(kind: Self.copyKind(id), ledger: ledger)
        saveDeletedAttachments(deletedAttachments(ledger: ledger).filter { $0.id != id }, ledger: ledger)
    }

    /// Removes a document. With `file`, also deletes the file in storage unless another record still uses it.
    /// Nothing changes when the copy cannot be made.
    func deleteDocument(_ e: Entry, file: Bool, summary: String) async -> Bool {
        guard file else { return await deleteDirective(e, summary: summary, pop: false) }
        let ledgerID = cfg.id
        guard let path = documentRepoPath(e), let L else { return await deleteDirective(e, summary: summary, pop: false) }
        let others = documentReferences(L, path: path).filter { $0 !== e }
        if !others.isEmpty {
            guard await deleteDirective(e, summary: summary, pop: false) else { return false }
            show(LS("文件还被其他 %@ 条记录使用，已保留文件", others.count))
            return true
        }
        guard let version = tree?.files[path] else {
            guard await deleteDirective(e, summary: summary, pop: false) else { return false }
            show(LS("存储里没有这个文件，只移除了引用"))
            return true
        }
        // its copy could not be listed for 恢复 afterwards
        guard deletedAttachmentsWritable(ledgerID) else {
            showFailure(LS("已删除附件的恢复记录暂时读不出来，没有做任何改动，请稍后再试"))
            return false
        }
        let data: Data
        do { data = try await backend.readData(path) } catch {
            showFailure(LS("无法下载文件，没有做任何改动：%@", error.localizedDescription))
            return false
        }
        guard cfg.id == ledgerID else { return false }
        var item = DeletedAttachment(path: path, version: version, record: nil, time: Date(), text: e.src, file: e.file)
        do { try RecoveryFiles.saveData(data, kind: Self.copyKind(item.id), ledger: ledgerID) } catch {
            showFailure(LS("无法在本机保存副本，没有做任何改动：%@", error.localizedDescription))
            return false
        }
        let before = history.first?.id
        guard await deleteDirective(e, summary: summary, pop: false) else {
            try? RecoveryFiles.removeData(kind: Self.copyKind(item.id), ledger: ledgerID)
            return false
        }
        // commit puts its record first; commits never overlap
        if let r = history.first, r.id != before { item.record = r.id }
        saveDeletedAttachments(deletedAttachments(ledger: ledgerID) + [item], ledger: ledgerID)
        Task { await finishAttachmentDeletions() }
        return true
    }

    /// Deletes the files whose records' removal has synced. Called after a delete and after each sync;
    /// a file a record points at again, or one changed in storage since it was copied, stays.
    func finishAttachmentDeletions() async {
        // one run at a time: two runs deleted the same file, and between deleting a file and marking it deleted
        // a restore read it as still waiting, skipped the upload and lost the file
        while let running = attachmentDeletionRun { await running.value }
        // the run clears itself as it ends: a waiter woken by it must not find it still there and spin on it
        let run = Task { @MainActor in
            await self.deletePendingAttachmentFiles()
            self.attachmentDeletionRun = nil
        }
        attachmentDeletionRun = run
        await run.value
    }

    /// Waits out a deletion in progress: what it is doing to a file is then written down.
    private func waitForAttachmentDeletions() async {
        while let running = attachmentDeletionRun { await running.value }
    }

    private func deletePendingAttachmentFiles() async {
        let ledgerID = cfg.id
        guard deletedAttachments(ledger: ledgerID).contains(where: { $0.state == .pending }) else { return }
        await waitForSavedSync()
        // the removal must be in storage before its file goes; held changes are never pushed
        guard cfg.id == ledgerID, !pending.contains(where: { $0.held == nil }), let L else { return }
        for item in deletedAttachments(ledger: ledgerID) where item.state == .pending {
            if !documentReferences(L, path: item.path).isEmpty {
                dropDeletedAttachment(item.id, ledger: ledgerID)
                continue
            }
            do {
                try await backend.delete(item.path, version: item.version, message: LS("删除附件：%@", item.path))
            } catch let e as GitHubError where e.status == 409 {
                dropDeletedAttachment(item.id, ledger: ledgerID)
                showFailure(LS("%@ 在存储里已被改动，没有删除", (item.path as NSString).lastPathComponent))
                continue
            } catch {
                return      // offline or refused: tried again after the next sync
            }
            guard cfg.id == ledgerID else { return }
            var items = deletedAttachments(ledger: ledgerID)
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i].state = .deleted
                items[i].time = Date()
                saveDeletedAttachments(items, ledger: ledgerID)
            }
        }
    }

    /// Before 撤回 of a removal that took its file: put the file back from the copy. False when it could not.
    func restoreDeletedAttachment(record: UUID) async -> Bool {
        await waitForAttachmentDeletions()
        guard let item = deletedAttachments().first(where: { $0.record == record }) else { return true }
        return await putBackDeletedFile(item, failure: LS("无法恢复文件，没有撤回：%@"))
    }

    /// 恢复 in 最近删除. Through its 最近改动 record while that is kept (file first, then the record); after the
    /// record has dropped out of the last 100, the file is uploaded again and the directive written back.
    func recoverDeletedAttachment(_ id: UUID) async -> Bool {
        let ledgerID = cfg.id
        guard let item = deletedAttachments(ledger: ledgerID).first(where: { $0.id == id }) else { return false }
        if let r = item.record, history.contains(where: { $0.id == r && $0.undone == nil }) {
            return await revert(r)
        }
        guard await putBackDeletedFile(item), cfg.id == ledgerID, let L else { return false }
        let name = (item.path as NSString).lastPathComponent
        guard documentReferences(L, path: item.path).isEmpty else { return true }
        // the directive again, with its path relative to the file it now goes into
        guard let text = item.text, let old = parseFile(text, file: item.file ?? main).entries.first(where: { $0.type == .document }),
              let account = old.account else {
            showFailure(LS("文件已恢复，但找不到原来的记录，请重新添加附件"))
            return false
        }
        let line = documentText(date: old.date, account: account, path: item.path) + old.links.map { " ^" + $0 }.joined()
        guard var ops = makeOps(line, extra: OpExtra(label: LS("恢复附件：%@", name)), single: false) else { return false }
        for i in ops.indices where ops[i].kind == .insert {
            ops[i].text = ops[i].text?.replacingOccurrences(of: "\"\(item.path)\"", with: "\"\(relativePath(item.path, from: ops[i].path))\"")
        }
        guard await commit(ops, word: LS("已恢复")) else {
            showFailure(LS("文件已恢复，但记录没有写回，可重新添加附件"))
            return false
        }
        return true
    }

    /// Uploads the copy (when the file had gone) and forgets the deletion at once. Left marked as pending, a sync
    /// before the record was written back deleted the restored file again: the same bytes have the same version.
    func putBackDeletedFile(_ given: DeletedAttachment, failure: String = LS("无法恢复文件：%@")) async -> Bool {
        let ledgerID = cfg.id
        // what has happened to the file is read after any deletion in progress, not from the caller's copy
        await waitForAttachmentDeletions()
        guard cfg.id == ledgerID else { return false }
        guard let item = deletedAttachments(ledger: ledgerID).first(where: { $0.id == given.id }) else { return true }
        if item.state == .deleted {
            guard let data = RecoveryFiles.loadData(kind: Self.copyKind(item.id), ledger: ledgerID) else {
                showFailure(LS("本机副本已不存在，无法恢复 %@", (item.path as NSString).lastPathComponent))
                return false
            }
            do { try await backend.writeData(item.path, data: data, message: LS("恢复附件：%@", item.path)) } catch {
                Haptics.error()
                showFailure(failure.replacingOccurrences(of: "%@", with: error.localizedDescription))
                return false
            }
        }
        guard cfg.id == ledgerID else { return false }
        dropDeletedAttachment(item.id, ledger: ledgerID)
        return true
    }

    /// Copies whose file has been gone for longer than `DeletedAttachment.keep`.
    func pruneDeletedAttachments(now: Date = Date()) {
        let ledgerID = cfg.id
        for item in deletedAttachments(ledger: ledgerID) where item.expired(now: now) {
            dropDeletedAttachment(item.id, ledger: ledgerID)
        }
    }
}
