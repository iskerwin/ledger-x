import XCTest
@testable import LedgerKit

final class EditSessionTests: XCTestCase {
    private func edit(_ payee: String = "Coffee") -> Draft {
        var d = Draft()
        d.amount = "12"; d.payee = payee
        d.replacing = Replacing(path: "journal.bean", old: "2026-10-17 * \"\(payee)\"\n  Expenses:Food 12 CNY\n  Assets:Bank",
                                date: "2026-10-17", summary: payee, baseline: "original")
        return d
    }

    func testNewDraftAndSeveralEditsSurviveIndependentSaveAndDiscard() throws {
        var workspace = DraftWorkspace()
        var creation = Draft(); creation.amount = "8+"; creation.narration = "incomplete"
        workspace.remember(DraftSession(draft: creation, baseline: Draft()))
        let first = edit(); var changed = first; changed.amount = "20"
        workspace.remember(DraftSession(draft: changed, baseline: first))
        let second = edit("Lunch"); var changedSecond = second; changedSecond.narration = "keep this"
        workspace.remember(DraftSession(draft: changedSecond, baseline: second))
        workspace.forget(changed)
        XCTAssertEqual(workspace.creation?.draft.amount, "8+")
        XCTAssertEqual(workspace.edits.count, 1)
        XCTAssertEqual(workspace.session(for: second).draft.narration, "keep this")
        workspace.forget(creation)
        XCTAssertNil(workspace.creation)
        XCTAssertEqual(workspace.edits.count, 1)
    }

    func testDisplayUUIDChangesAreCleanButChangedRowValuesAreDirty() {
        var a = Draft()
        a.shares = [Share(person: "Alice", amount: "4")]
        a.extraFunds = [ExtraFund(account: "Assets:Cash", amount: "2")]
        var b = a
        b.rows[0].id = UUID(); b.shares[0].id = UUID(); b.extraFunds[0].id = UUID()
        XCTAssertTrue(sameDraftContent(a, b))
        b.rows[0].amount = "15"
        XCTAssertTrue(DraftSession(draft: b, baseline: a).hasChanges)
    }

    func testReturningAnEditToItsInitialContentRemovesRecoveryEntry() {
        var workspace = DraftWorkspace()
        let initial = edit(); var changed = initial; changed.amount = "30"
        workspace.remember(DraftSession(draft: changed, baseline: initial))
        XCTAssertEqual(workspace.edits.count, 1)
        workspace.remember(DraftSession(draft: initial, baseline: initial))
        XCTAssertTrue(workspace.edits.isEmpty)
    }

    func testWorkspaceRoundTripPreservesComplexAndScannedDrafts() throws {
        var initial = edit(); initial.kind = .multi
        initial.rows = [DraftRow(account: "Expenses:Food"), DraftRow(account: "Assets:Bank")]
        initial.rows[0].amount = "12+"; initial.rows[0].meta = ["invoice": "A123"]
        initial.shares = [Share(person: "Alice", amount: "4")]
        initial.extraFunds = [ExtraFund(account: "Assets:Cash", amount: "2")]
        initial.keepMeta = [KeptMeta(key: "note", value: "\"keep\"")]
        initial.fxRate = KeptRate(text: "1 USD = 7.8 HKD", amount: 1, toAmount: 7.8)
        var fields = ScanFields(); fields.kind = .several(2); fields.last4 = "1234"
        initial.scan = ScanMemo(fields: fields, cardKey: "1234", funding: "Assets:Bank", sure: true)
        var changed = initial; changed.narration = "after restart"
        var workspace = DraftWorkspace()
        workspace.remember(DraftSession(draft: changed, baseline: initial))
        let data = try JSONEncoder().encode(workspace)
        let restored = try JSONDecoder().decode(DraftWorkspace.self, from: data)
        XCTAssertEqual(restored, workspace)
        XCTAssertEqual(restored.session(for: initial).draft.rows[0].amount, "12+")
        XCTAssertEqual(restored.session(for: initial).draft.scan?.fields.kind, .several(2))
    }

    func testSourceDraftStaysSeparateAndRejectsDifferentOriginalIdentity() {
        var workspace = DraftWorkspace()
        let original = "2026-10-17 note Assets:Bank \"old\""
        let session = SourceEditSession(file: "notes.bean", original: original,
                                       text: original.replacingOccurrences(of: "old", with: "new"), label: "Note")
        workspace.remember(session)
        XCTAssertEqual(workspace.sources.count, 1)
        XCTAssertNil(workspace.sources[DraftWorkspace.sourceKey(file: "other.bean", original: original)])
        XCTAssertNil(workspace.sources[DraftWorkspace.sourceKey(file: "notes.bean", original: original + " ; changed")])
        workspace.remember(SourceEditSession(file: "notes.bean", original: original, text: original, label: "Note"))
        XCTAssertTrue(workspace.sources.isEmpty)
    }

    func testSeparateLedgerWorkspacesAndControlsRoundTrip() throws {
        var a = DraftWorkspace(); var d = Draft(); d.amount = "99"
        a.remember(DraftSession(draft: d, baseline: Draft()))
        let books = ["book-A": a, "book-B": DraftWorkspace()]
        let restored = try JSONDecoder().decode([String: DraftWorkspace].self, from: JSONEncoder().encode(books))
        XCTAssertEqual(restored["book-A"]?.creation?.draft.amount, "99")
        XCTAssertNil(restored["book-B"]?.creation)
        var context = BrowseContext()
        context.query = "Coffee"; context.filters = ["pending", "month"]; context.limit = 450
        context.month = "2026-09"; context.opened = ["2026-08": true]
        let controls = try JSONDecoder().decode(BrowseContext.self, from: JSONEncoder().encode(context))
        XCTAssertEqual(controls, context)
    }

    func testDraftKeysFramePathsAndSourceWithoutSeparatorCollisions() {
        XCTAssertNotEqual(DraftWorkspace.sourceKey(file: "a\u{1}b", original: "c"),
                          DraftWorkspace.sourceKey(file: "a", original: "b\u{1}c"))
    }

    func testNewPrefilledDraftRequiresProtectionEvenWithoutTyping() {
        var d = Draft(); d.amount = "12"; d.payee = "Template"
        XCTAssertTrue(DraftSession(draft: d, baseline: d).shouldKeep)
        XCTAssertFalse(DraftSession(draft: Draft(), baseline: Draft()).shouldKeep)
    }
}
