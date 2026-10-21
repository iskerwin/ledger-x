import XCTest
@testable import LedgerKit

/// What a push does when the files moved on since the edits were made on this device: two devices editing,
/// a queue built up offline, a retry after another push landed in between.
final class PushPlanTests: XCTestCase {
    let path = "journals/2026.bean"
    /// a file that isn't on the server
    let absent: String? = nil
    let lunch = """
    2026-10-01 * "食堂" "午饭"
      Expenses:Food                                       20.00 CNY
      Assets:Cash                                        -20.00 CNY
    """
    let dinner = """
    2026-10-03 * "饭店" "晚饭"
      Expenses:Food                                       80.00 CNY
      Assets:Cash                                        -80.00 CNY
    """
    let coffee = """
    2026-10-02 * "瑞幸" "咖啡"
      Expenses:Food                                        9.90 CNY
      Assets:Cash                                         -9.90 CNY
    """

    func insert(_ text: String, _ date: String, path p: String? = nil) -> Op {
        var o = Op(kind: .insert, path: p ?? path); o.text = text; o.date = date; return o
    }
    func replace(_ old: String, _ new: String) -> Op {
        var o = Op(kind: .replace, path: path); o.old = old; o.text = new; o.label = "修改"; return o
    }
    func remove(_ old: String) -> Op {
        var o = Op(kind: .remove, path: path); o.old = old; o.label = "删除：x"; return o
    }

    func testEditsApplyOnTopOfAnotherDevicesPush() {
        // this device queued coffee offline; meanwhile the other device pushed dinner
        let server = lunch + "\n\n" + dinner + "\n"
        let plan = planPush([insert(coffee, "2026-10-02")], bases: [path: server])
        XCTAssertTrue(plan.failed.isEmpty)
        XCTAssertEqual(plan.changes.count, 1)
        let text = plan.changes[0].text!
        XCTAssertTrue(text.contains("瑞幸") && text.contains("饭店") && text.contains("食堂"), text)
        // in date order, between the two
        XCTAssertLessThan(text.range(of: "食堂")!.lowerBound, text.range(of: "瑞幸")!.lowerBound)
        XCTAssertLessThan(text.range(of: "瑞幸")!.lowerBound, text.range(of: "饭店")!.lowerBound)
    }

    func testEditOfAnEntryChangedElsewhereIsParked() {
        // this device edited lunch; the other device changed lunch's amount first
        let theirs = lunch.replacingOccurrences(of: "20.00", with: "25.00")
        let mine = lunch.replacingOccurrences(of: "午饭", with: "工作餐")
        let r = replace(lunch, mine)
        let other = insert(coffee, "2026-10-02", path: "journals/other.bean")
        let plan = planPush([r, other], bases: [path: theirs + "\n", "journals/other.bean": absent])
        XCTAssertNotNil(plan.failed[r.id])
        XCTAssertEqual(plan.included, [other.id], "the other file still goes")
        XCTAssertEqual(plan.changes.map { $0.path }, ["journals/other.bean"])
    }

    func testEntryMovedToAnotherDayGoesWithItsRemoval() {
        // an edit that changed the date: remove the old entry, insert it on the new day (silent)
        let r = remove(lunch)
        var moved = insert(lunch.replacingOccurrences(of: "2026-10-01", with: "2026-10-05"), "2026-10-05")
        moved.silent = true
        let plan = planPush([r, moved], bases: [path: dinner + "\n"])   // lunch is gone already
        XCTAssertNotNil(plan.failed[r.id])
        XCTAssertNotNil(plan.failed[moved.id], "not inserted twice when its original can't be removed")
        XCTAssertTrue(plan.changes.isEmpty)
    }

    func testDeletionOfAnEntryStillThere() {
        let plan = planPush([remove(dinner)], bases: [path: lunch + "\n\n" + dinner + "\n"])
        XCTAssertTrue(plan.failed.isEmpty)
        XCTAssertFalse(plan.changes[0].text!.contains("饭店"))
    }

    func testDeletingAFileOnlyWhenNobodyWroteToIt() {
        var del = Op(kind: .deleteFile, path: path); del.old = lunch + "\n"
        // unchanged: deleted
        var plan = planPush([del], bases: [path: lunch + "\n"])
        XCTAssertEqual(plan.changes, [PlannedChange(path: path, text: nil)])
        // someone added an entry since: kept, the undo is parked
        plan = planPush([del], bases: [path: lunch + "\n\n" + dinner + "\n"])
        XCTAssertNotNil(plan.failed[del.id])
        XCTAssertTrue(plan.changes.isEmpty)
        // already gone: nothing to do, the op leaves the queue
        plan = planPush([del], bases: [path: absent])
        XCTAssertEqual(plan.included, [del.id])
        XCTAssertTrue(plan.changes.isEmpty)
    }

    func testWholeFileWriteIsCheckedAgainstWhatItReplaced() {
        let q = "queries/custom.bql"
        var w = Op(kind: .write, path: q); w.old = "-- a\n\nSELECT 1\n"; w.text = "-- a\n\nSELECT 2\n"
        XCTAssertEqual(planPush([w], bases: [q: "-- a\n\nSELECT 1\n"]).changes.first?.text, "-- a\n\nSELECT 2\n")
        let plan = planPush([w], bases: [q: "-- a\n\nSELECT 1\n\n-- b\n\nSELECT 3\n"])
        XCTAssertNotNil(plan.failed[w.id], "another device's query is not overwritten")
        // a write queued before writes remembered their base (old == nil) still goes, as it used to
        var writeOp = Op(kind: .write, path: q); writeOp.text = "x\n"
        XCTAssertEqual(planPush([writeOp], bases: [q: "y\n"]).changes.first?.text, "x\n")
    }

    func testConfigChangesFromTwoDevicesAreMerged() {
        let base = LedgerXConfig().json()
        var mineC = LedgerXConfig(); mineC.defaultCurrency = "HKD"
        var theirsC = LedgerXConfig(); theirsC.defaultFunding = "Assets:Bank:BOC"
        var w = Op(kind: .write, path: LedgerXConfig.path); w.old = base; w.text = mineC.json()
        let plan = planPush([w], bases: [LedgerXConfig.path: theirsC.json()])
        XCTAssertTrue(plan.failed.isEmpty)
        let merged = LedgerXConfig.parse(plan.changes[0].text!)
        XCTAssertEqual(merged?.defaultCurrency, "HKD")
        XCTAssertEqual(merged?.defaultFunding, "Assets:Bank:BOC")
        // both changed the same setting: parked rather than one silently winning
        var clash = LedgerXConfig(); clash.defaultCurrency = "USD"
        XCTAssertNotNil(planPush([w], bases: [LedgerXConfig.path: clash.json()]).failed[w.id])
    }

    func testConfigKeyRemovedOnThisDevice() {
        var b = LedgerXConfig(); b.defaultCurrency = "HKD"; b.defaultFunding = "Assets:Cash"
        var m = b; m.defaultCurrency = nil
        var t = b; t.largeExpense = 500
        let merged = mergeConfigJSON(base: b.json(), mine: m.json(), theirs: t.json()).flatMap(LedgerXConfig.parse)
        XCTAssertNil(merged?.defaultCurrency)
        XCTAssertEqual(merged?.largeExpense, 500)
        XCTAssertEqual(merged?.defaultFunding, "Assets:Cash")
        XCTAssertNil(mergeConfigJSON(base: "{", mine: "{}", theirs: "{}"))
    }

    func testFailedAndHeldEditsAreLeftOut() {
        var held = insert(coffee, "2026-10-02"); held.held = "余额不足"
        var failed = insert(dinner, "2026-10-03"); failed.failed = "x"
        let ok = insert(lunch, "2026-10-01")
        let plan = planPush([held, failed, ok], bases: [path: absent])
        XCTAssertEqual(plan.included, [ok.id])
        XCTAssertEqual(plan.changes.first?.text?.contains("瑞幸"), false)
    }

    func testRetryAfterAPartialWriteDoesNotRepeatEdits() {
        // file A was written before file B failed: A's edits left the queue, so only B's are planned again
        let a = insert(lunch, "2026-10-01", path: "a.bean"), b = insert(dinner, "2026-10-03", path: "b.bean")
        let first = planPush([a, b], bases: ["a.bean": absent, "b.bean": absent])
        XCTAssertEqual(first.changes.map { $0.path }, ["a.bean", "b.bean"])
        let serverA = first.changes[0].text!
        let retry = planPush([b], bases: ["a.bean": serverA, "b.bean": absent])
        XCTAssertEqual(retry.changes.map { $0.path }, ["b.bean"])
    }
}
