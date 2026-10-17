import SwiftUI
import LedgerKit

extension Store {
    func rememberSourceDraft(file: String, original: String, text: String, label: String) {
        draftWorkspace.remember(SourceEditSession(file: file, original: original, text: text, label: label))
        if !demo { Prefs.set(pk("draftWorkspace"), draftWorkspace) }
    }

    func forgetSourceDraft(file: String, original: String) {
        draftWorkspace.sources[DraftWorkspace.sourceKey(file: file, original: original)] = nil
        if !demo { Prefs.set(pk("draftWorkspace"), draftWorkspace) }
    }

    func sourceDraft(file: String, original: String, fallback: String) -> String {
        draftWorkspace.sources[DraftWorkspace.sourceKey(file: file, original: original)]?.text ?? fallback
    }

    func persistActiveDraft() {
        guard let baseline = drafts.baseline else { return }
        draftWorkspace.remember(DraftSession(draft: draft, baseline: baseline))
        if !demo { Prefs.set(pk("draftWorkspace"), draftWorkspace) }
    }

    func restoreCreationDraft() {
        if let saved = draftWorkspace.creation { drafts.install(saved) }
        else {
            let initial = newDraftFor(.expense)
            drafts.install(DraftSession(draft: initial, baseline: initial))
        }
    }

    /// Called only after the operation has passed review and is accepted into the local queue.
    func finishDraft(with next: Draft) {
        let editing = draft.replacing != nil
        draftWorkspace.forget(draft)
        if editing { restoreCreationDraft() }
        else { drafts.install(DraftSession(draft: next, baseline: next)) }
        if !demo { Prefs.set(pk("draftWorkspace"), draftWorkspace) }
    }

    func discardActiveDraft() {
        draftWorkspace.forget(draft)
        if draft.replacing != nil { restoreCreationDraft() }
        else {
            let fresh = newDraftFor(draft.kind)
            drafts.install(DraftSession(draft: fresh, baseline: fresh))
        }
        if !demo { Prefs.set(pk("draftWorkspace"), draftWorkspace) }
    }

    /// Saved edits are resumed only while their exact original source still exists.
    func resumeDraft(_ key: String) async -> Bool {
        guard !drafts.isSaving, let saved = draftWorkspace.edits[key], let r = saved.draft.replacing else { return false }
        let ledgerID = cfg.id
        guard let file = try? await fileText(r.path), cfg.id == ledgerID else { return false }
        let original = parseFile(r.old, file: r.path).entries
        guard original.count == 1, EntryLocator(original[0]).text(in: file) != nil else {
            Haptics.error()
            show(LS("原记录已变化，草稿已保留。可复制草稿内容后核对。"))
            return false
        }
        persistActiveDraft()
        drafts.install(saved)
        openAdd(full: needsFullForm(saved.draft))
        return true
    }
}
