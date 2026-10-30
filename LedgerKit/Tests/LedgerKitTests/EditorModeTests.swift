import XCTest
@testable import LedgerKit

final class EditorModeTests: XCTestCase {
    private func environment() -> (Ledger, Derived) {
        let L = loadLedger { _ in """
        option "operating_currency" "CNY"
        2025-01-01 open Assets:Bank:Example CNY
        2025-01-01 open Assets:Cash CNY
        2025-01-01 open Expenses:Food CNY
        2025-01-01 open Income:Salary CNY
        """ }
        return (L, Derived(L))
    }

    private func simple(_ kind: DraftKind) -> Draft {
        var d = Draft()
        d.date = "2025-02-01"; d.kind = kind; d.amount = "12.00"
        d.account = kind == .income ? "Income:Salary" : "Expenses:Food"
        d.funding = "Assets:Bank:Example"; d.to = "Assets:Cash"
        d.payee = "Example"; d.narration = "Keep this description"
        d.tags = ["test"]; d.keepLinks = ["doc-example"]
        d.keepMeta = [KeptMeta(key: "order", value: "\"000123\"")]
        return d
    }

    func testEveryEditorPairKeepsTheLatestTransaction() throws {
        let (L, D) = environment()
        for kind in [DraftKind.expense, .income, .transfer] {
            let original = simple(kind)
            let expected = try XCTUnwrap(validateText(draftText(original, L, D), L).txn)
            for first in [kind, .multi, .raw] {
                for second in [kind, .multi, .raw] {
                    let a = try convertingEditor(original, to: first, ledger: L, derived: D).get()
                    let b = try convertingEditor(a, to: second, ledger: L, derived: D).get()
                    let actual = try XCTUnwrap(validateText(draftText(b, L, D), L).txn)
                    XCTAssertTrue(sameTxn(expected, actual), "\(kind): \(first) → \(second)")
                }
            }
        }
    }

    func testChangedSplitAndRawBecomeTheQuickEditorsCurrentValues() throws {
        let (L, D) = environment()
        let original = simple(.expense)
        var split = try convertingEditor(original, to: .multi, ledger: L, derived: D).get()
        split.narration = "Changed in split"
        for i in split.rows.indices { split.rows[i].amount = split.rows[i].account.hasPrefix("Expenses:") ? "25.00" : "-25.00" }
        var text = try convertingEditor(split, to: .raw, ledger: L, derived: D).get()
        text.raw = text.raw.replacingOccurrences(of: "Changed in split", with: "Changed in text")
        let restored = try convertingEditor(text, to: .expense, ledger: L, derived: D, previous: original).get()
        XCTAssertEqual(restored.amount, "25")
        XCTAssertEqual(restored.narration, "Changed in text")
        XCTAssertEqual(restored.keepMeta.first(where: { $0.key == "order" })?.value, "\"000123\"")
        XCTAssertTrue(restored.keepLinks.contains("doc-example"))
    }

    func testUnchangedRoundTripRestoresExactEditingSnapshot() throws {
        let (L, D) = environment()
        var original = simple(.expense)
        original.replacing = Replacing(path: "journal.bean", old: "original", date: original.date,
                                       summary: "Example", baseline: draftText(original, L, D))
        let split = try convertingEditor(original, to: .multi, ledger: L, derived: D).get()
        let raw = try convertingEditor(split, to: .raw, ledger: L, derived: D).get()
        let back = try convertingEditor(raw, to: .expense, ledger: L, derived: D, previous: original).get()
        XCTAssertEqual(back, original)
        XCTAssertFalse(DraftSession(draft: back, baseline: original).hasChanges)
    }

    func testSourceOverrideIsTheInputAndSurvivesRecovery() throws {
        let (L, D) = environment()
        var source = simple(.expense)
        source.edited = draftText(source, L, D).replacingOccurrences(of: "12.00", with: "30.00")
            .replacingOccurrences(of: "-12.00", with: "-30.00")
        let raw = try convertingEditor(source, to: .raw, ledger: L, derived: D).get()
        let data = try JSONEncoder().encode(DraftSession(draft: raw, baseline: simple(.expense)))
        let recovered = try JSONDecoder().decode(DraftSession.self, from: data)
        XCTAssertEqual(recovered.draft.raw, source.edited)
        let back = try convertingEditor(recovered.draft, to: .expense, ledger: L, derived: D).get()
        XCTAssertEqual(back.amount, "30")
    }

    func testIncompleteAndUnrepresentableInputIsNeverReplaced() throws {
        let (L, D) = environment()
        var incomplete = simple(.expense); incomplete.amount = "12+"
        XCTAssertThrowsError(try convertingEditor(incomplete, to: .multi, ledger: L, derived: D).get())
        XCTAssertEqual(incomplete.amount, "12+")
        var raw = simple(.expense)
        raw.kind = .raw; raw.raw = "2025-02-01 note Assets:Cash \"Keep note\""
        XCTAssertThrowsError(try convertingEditor(raw, to: .expense, ledger: L, derived: D).get())
        raw.raw = draftText(simple(.expense), L, D) + " ; keep comment"
        XCTAssertThrowsError(try convertingEditor(raw, to: .multi, ledger: L, derived: D).get())
        XCTAssertTrue(raw.raw.contains("keep comment"))
        let kept = try convertingEditor(raw, to: .raw, ledger: L, derived: D).get()
        XCTAssertEqual(kept.raw, raw.raw)
    }

    func testEmptyModeRoundTripDoesNotCreateContent() throws {
        let (L, D) = environment()
        let initial = newDraft(.expense, D, defaultFunding: "Assets:Bank:Example")
        for kind in [DraftKind.multi, .raw] {
            let advanced = try convertingEditor(initial, to: kind, ledger: L, derived: D).get()
            let back = try convertingEditor(advanced, to: .expense, ledger: L, derived: D, previous: initial).get()
            XCTAssertFalse(DraftSession(draft: back, baseline: initial).shouldKeep)
        }
    }

    /// 分录 left unbalanced: refused, the user was locked in it (no switching, no way back). Now the other editor
    /// opens and the rows wait, exactly as they were, for the way back
    private func unfinishedSplit() -> Draft {
        var d = Draft()
        d.kind = .multi; d.date = "2025-02-01"; d.payee = "Example"; d.funding = "Assets:Bank:Example"
        d.rows = [DraftRow(account: "Expenses:Food"), DraftRow(account: "Assets:Bank:Example")]
        d.rows[0].amount = "12.00"; d.rows[1].amount = "-10.00"
        return d
    }

    func testAnUnfinishedSplitIsSetAsideAndComesBack() throws {
        let (L, D) = environment()
        let split = unfinishedSplit()
        guard case .failure(.incomplete) = convertingEditor(split, to: .expense, ledger: L, derived: D) else {
            return XCTFail("an unbalanced split converted")
        }
        var quick = settingAside(split, to: .expense, previous: nil)
        XCTAssertEqual(quick.kind, .expense)
        XCTAssertEqual(quick.payee, "Example")
        XCTAssertEqual(quick.date, "2025-02-01")
        XCTAssertTrue(quick.raw.isEmpty)
        XCTAssertNil(returningToSetAside(quick, to: .raw), "only the editor it was left in")

        quick.narration = "Typed meanwhile"
        let back = try XCTUnwrap(returningToSetAside(quick, to: .multi))
        XCTAssertEqual(back.rows, split.rows)
        XCTAssertEqual(back.narration, "Typed meanwhile")
        XCTAssertNil(back.setAside)
    }

    func testTheSetAsideSplitIsKeptAsTheFormIsKeptAndChanged() throws {
        let split = unfinishedSplit()
        let blank = Draft()
        let quick = settingAside(split, to: .expense, previous: blank)
        XCTAssertTrue(DraftSession(draft: quick, baseline: blank).shouldKeep, "closing asks before the rows are lost")

        // saved with the draft
        let data = try JSONEncoder().encode(DraftSession(draft: quick, baseline: blank))
        let saved = try JSONDecoder().decode(DraftSession.self, from: data)
        XCTAssertEqual(returningToSetAside(saved.draft, to: .multi)?.rows, split.rows)

        // 支出 → 收入 → 支出 restores the remembered 支出 and still carries the rows
        let toIncome = switchingKind(quick, to: .income, remembering: [:], fundingCurrency: "CNY", defaultCurrency: "CNY")
        let toExpense = switchingKind(toIncome.draft, to: .expense, remembering: toIncome.snapshots, fundingCurrency: "CNY", defaultCurrency: "CNY")
        XCTAssertEqual(returningToSetAside(toExpense.draft, to: .multi)?.rows, split.rows)
    }

    /// a whole split with more lines than the quick editors show is set aside the same way, untouched
    func testASplitTheQuickEditorsCantShowIsSetAsideToo() throws {
        let (L, D) = environment()
        var split = unfinishedSplit()
        split.rows.append(DraftRow(account: "Assets:Cash"))
        split.rows[1].amount = "-10.00"; split.rows[2].amount = "-2.00"
        XCTAssertTrue(validateText(draftText(split, L, D), L, single: true).ok)
        guard case .failure(.notRepresentable) = convertingEditor(split, to: .expense, ledger: L, derived: D) else {
            return XCTFail("three lines shown as an expense")
        }
        let quick = settingAside(split, to: .expense, previous: nil)
        XCTAssertEqual(returningToSetAside(quick, to: .multi)?.rows, split.rows)
    }
}
