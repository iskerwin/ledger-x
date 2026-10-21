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

    func testOnlySwitchingTypeOnEmptyCreationDoesNotKeepDraft() {
        var initial = Draft(); initial.funding = "Assets:Bank"; initial.events = ["trip"]
        var session = DraftSession(draft: initial, baseline: initial)
        for kind in [DraftKind.income, .transfer, .expense] {
            var next = session.draft; next.kind = kind
            next.account = ""; next.currency = kind == .transfer ? "USD" : "CNY"
            session = session.selectingKind(next)
            XCTAssertFalse(session.shouldKeep)
            var workspace = DraftWorkspace(); workspace.remember(session)
            XCTAssertNil(workspace.creation)
        }
    }

    func testExistingExpenseRoundTripThroughIncomeAndTransferIsClean() {
        var original = edit()
        original.account = "Expenses:Food"
        original.funding = "Assets:Bank:CGB"
        original.amount = "12"
        original.narration = "Interaction test"
        var snapshots: [DraftKind: Draft] = [:]
        var current = original
        for kind in [DraftKind.income, .transfer, .expense] {
            let switched = switchingKind(current, to: kind, remembering: snapshots, fundingCurrency: "CNY", defaultCurrency: "CNY")
            snapshots = switched.snapshots
            current = switched.draft
            if kind != .expense {
                XCTAssertTrue(DraftSession(draft: current, baseline: original).hasChanges)
            }
        }
        XCTAssertEqual(current.kind, .expense)
        XCTAssertEqual(current.account, "Expenses:Food")
        XCTAssertFalse(DraftSession(draft: current, baseline: original).hasChanges)
    }

    func testAmountChangedOnAnotherTypeIsStillAnEdit() {
        var original = edit()
        original.account = "Expenses:Food"
        original.amount = "12"
        let income = switchingKind(original, to: .income, remembering: [:], fundingCurrency: "CNY", defaultCurrency: "CNY")
        var edited = income.draft
        edited.amount = "25.00"
        let back = switchingKind(edited, to: .expense, remembering: income.snapshots, fundingCurrency: "CNY", defaultCurrency: "CNY")
        XCTAssertEqual(back.draft.account, "Expenses:Food")
        XCTAssertTrue(DraftSession(draft: back.draft, baseline: original).hasChanges)
        XCTAssertFalse(sameDraftContent(back.draft, original))
    }

    func testCategoryChosenBeforeLeavingTheTypeComesBack() {
        var original = edit()
        original.account = "Expenses:Food"
        var chosen = original
        chosen.account = "Expenses:Drink"
        let away = switchingKind(chosen, to: .income, remembering: [:], fundingCurrency: nil, defaultCurrency: "CNY")
        let back = switchingKind(away.draft, to: .expense, remembering: away.snapshots, fundingCurrency: nil, defaultCurrency: "CNY")
        XCTAssertEqual(back.draft.account, "Expenses:Drink")
        XCTAssertTrue(DraftSession(draft: back.draft, baseline: original).hasChanges)
    }

    func testPlainAmountsAndBlankNotesAreTheSameContent() {
        var original = edit()
        original.amount = "25"
        original.narration = ""
        var typed = original
        typed.amount = "25.00"
        typed.narration = "  "
        XCTAssertTrue(sameDraftContent(original, typed))
        typed.amount = "26"
        XCTAssertFalse(sameDraftContent(original, typed))
        typed.amount = "25"
        typed.narration = "note"
        XCTAssertFalse(sameDraftContent(original, typed))
        var expression = original
        expression.amount = "12+"
        XCTAssertFalse(sameDraftContent(original, expression))
    }

    func testBlankNewEntryCanStillChangeTypeWithoutAPrompt() {
        var initial = Draft()
        initial.funding = "Assets:Bank"
        initial.events = ["trip"]
        var snapshots: [DraftKind: Draft] = [:]
        var session = DraftSession(draft: initial, baseline: initial)
        for kind in [DraftKind.income, .transfer, .expense] {
            let switched = switchingKind(session.draft, to: kind, remembering: snapshots, fundingCurrency: "USD", defaultCurrency: "CNY")
            snapshots = switched.snapshots
            session = session.selectingKind(switched.draft)
            XCTAssertFalse(session.shouldKeep)
            var workspace = DraftWorkspace()
            workspace.remember(session)
            XCTAssertNil(workspace.creation)
        }
    }

    func testTypeSwitchKeepsRealInputAndExistingTransactionProtected() {
        for key in [\Draft.amount, \Draft.narration, \Draft.account, \Draft.funding] {
            let baseline = Draft(); var input = baseline; input[keyPath: key] = "user input"
            var next = input; next.kind = .income
            XCTAssertTrue(DraftSession(draft: input, baseline: baseline).selectingKind(next).shouldKeep)
        }
        let original = edit(); var next = original; next.kind = .income
        XCTAssertTrue(DraftSession(draft: original, baseline: original).selectingKind(next).hasChanges)
    }

    func testManualChoicesSurviveRecoveryAndPayeeRecommendations() throws {
        var d = Draft(); d.account = "Expenses:Manual"; d.funding = "Assets:Manual"
        var choices = DraftSelection(); choices.category = true; choices.funding = true; d.selection = choices
        var workspace = DraftWorkspace(); workspace.remember(DraftSession(draft: d, baseline: Draft()))
        let restored = try JSONDecoder().decode(DraftWorkspace.self, from: JSONEncoder().encode(workspace))
        let result = applyingSuggestedAccounts(restored.creation!.draft, category: "Expenses:Suggested", funding: "Assets:Suggested")
        XCTAssertEqual(result.account, "Expenses:Manual"); XCTAssertEqual(result.funding, "Assets:Manual")
    }

    func testRecommendationsFillAutomaticFieldsIndependently() {
        var d = Draft(); d.account = "Expenses:Manual"
        var choices = DraftSelection(); choices.category = true; d.selection = choices
        let result = applyingSuggestedAccounts(d, category: "Expenses:Suggested", funding: "Assets:Suggested")
        XCTAssertEqual(result.account, d.account); XCTAssertEqual(result.funding, "Assets:Suggested")
        XCTAssertEqual(applyingSuggestedAccounts(Draft(), category: "Expenses:Suggested", funding: nil).account, "Expenses:Suggested")
    }

    func testRecommendationDoesNotRewriteExistingTransactionAccounts() {
        var d = edit(); d.account = "Expenses:Original"; d.funding = "Assets:Original"
        let result = applyingSuggestedAccounts(d, category: "Expenses:Suggested", funding: "Assets:Suggested")
        XCTAssertEqual(result.account, d.account); XCTAssertEqual(result.funding, d.funding)
    }

    func testOldDraftsDecodeWithoutSelectionAndSelectionAloneIsNotDirty() throws {
        var d = Draft(); var choices = DraftSelection(); choices.funding = true; d.selection = choices
        XCTAssertTrue(sameDraftContent(d, Draft()))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(d)) as! [String: Any]
        object.removeValue(forKey: "selection")
        let old = try JSONDecoder().decode(Draft.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.selection)
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

    func testReportJumpOpensThatMonthAndKeepsTheEarlierBrowse() {
        var earlier = BrowseContext()
        earlier.query = "Coffee"
        earlier.filters = ["month", "pending"]
        earlier.limit = 450
        earlier.anchor = "Assets:Bank:CGB"
        let first = journalLink(.report(month: "2026-10", account: "Expenses:Food"), from: earlier, previous: nil)
        XCTAssertEqual(first.previous, earlier)
        XCTAssertEqual(first.browse.query, "2026-10 科目:Expenses:Food")
        XCTAssertTrue(first.browse.filters.isEmpty)
        XCTAssertNil(first.browse.anchor)
        XCTAssertEqual(first.browse.limit, 450)

        let again = journalLink(.report(month: " 2026-09 ", account: " Expenses:Transport "), from: first.browse, previous: first.previous)
        XCTAssertEqual(again.previous, earlier)
        XCTAssertEqual(again.browse.query, "2026-09 科目:Expenses:Transport")
        XCTAssertEqual(again.previous.query, "Coffee")
    }

    func testAccountJumpClearsTheSearchAndIgnoresABlankName() {
        var current = BrowseContext()
        current.query = "2026-10 科目:Expenses:Food"
        current.filters = ["large"]
        current.anchor = "Assets:Bank:CGB"
        let link = journalLink(.account("Assets:Cash"), from: current, previous: nil)
        XCTAssertEqual(link.previous, current)
        XCTAssertEqual(link.browse.query, "")
        XCTAssertTrue(link.browse.filters.isEmpty)
        XCTAssertEqual(link.browse.anchor, "Assets:Cash")
        XCTAssertEqual(link.browse.limit, 150)

        let blank = journalLink(.account("  "), from: current, previous: nil)
        XCTAssertNil(blank.browse.anchor)
        let emptyReport = journalLink(.report(month: " ", account: " "), from: current, previous: link.previous)
        XCTAssertEqual(emptyReport.browse.query, "")
        XCTAssertEqual(emptyReport.previous.query, "2026-10 科目:Expenses:Food")
    }

    func testBrowseEmptyDistinguishesAFilterFromAnEmptyPage() {
        XCTAssertEqual(browseEmpty(count: 4, filtered: true), .showing)
        XCTAssertEqual(browseEmpty(count: 0, filtered: false), .nothingHere)
        XCTAssertEqual(browseEmpty(count: 0, filtered: true), .nothingMatches)
    }

    func testNewPrefilledDraftRequiresProtectionEvenWithoutTyping() {
        var d = Draft(); d.amount = "12"; d.payee = "Template"
        XCTAssertTrue(DraftSession(draft: d, baseline: d).shouldKeep)
        XCTAssertFalse(DraftSession(draft: Draft(), baseline: Draft()).shouldKeep)
    }

    func testIncompleteSplitWithOnlyRowInputIsRetained() {
        var baseline = Draft(); baseline.kind = .multi; baseline.date = "2026-09-30"
        var draft = baseline; draft.rows[0].amount = "8+"
        XCTAssertTrue(draftHasContent(draft))
        var workspace = DraftWorkspace()
        workspace.remember(DraftSession(draft: draft, baseline: baseline))
        XCTAssertEqual(workspace.creation?.draft.date, "2026-09-30")
        XCTAssertEqual(workspace.creation?.draft.rows[0].amount, "8+")
    }
}
