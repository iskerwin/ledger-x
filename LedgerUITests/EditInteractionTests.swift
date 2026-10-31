import XCTest

final class EditInteractionTests: XCTestCase {
    private func launch(tab: String = "add", filled: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": tab, "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 20))
        if filled {
            app.buttons["1"].tap()
            app.buttons["2"].tap()
        }
        return app
    }

    func testExistingExpenseTypeRoundTripClosesWithoutPrompt() {
        let app = openExistingExpense()
        tapKind(app, "收入")
        tapKind(app, "转账")
        tapKind(app, "支出")
        tapPoint(app.buttons["关闭"], timeout: 5)
        let prompted = app.buttons["继续编辑"].waitForExistence(timeout: 2)
        if prompted { print(app.debugDescription) }
        XCTAssertFalse(prompted)
        XCTAssertTrue(app.buttons["关闭"].waitForNonExistence(timeout: 5))
    }

    func testChangingAnExistingExpenseStillPromptsOnClose() {
        let app = openExistingExpense()
        tapKind(app, "收入")
        tapPoint(app.buttons["关闭"], timeout: 5)
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
    }

    private func openExistingExpense() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "journal", "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        // A journal row's title is not always the hittable control. Waiting for tap()
        // to become hittable can stall the whole simulator job.
        let row = app.staticTexts["Coffee"].firstMatch
        tapPoint(row, timeout: 20)
        let edit = app.buttons["编辑"]
        // The row title's center is not always the control that opens the entry. Tap once more before failing.
        if !edit.waitForExistence(timeout: 8) { tapPoint(row, timeout: 5) }
        tapPoint(edit, timeout: 8)
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls.buttons["支出"].waitForExistence(timeout: 5))
        return app
    }

    /// Tap the center of an element that exists. Does not wait for it to report itself hittable.
    private func tapPoint(_ element: XCUIElement, timeout: TimeInterval) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// In an open account picker: search for the account and tap it. The picker opens on the recent and most used,
    /// so an account further down is found by searching, as a person would.
    private func pickAccount(_ app: XCUIApplication, _ account: String) {
        let search = app.textFields["account.search"]
        tapPoint(search, timeout: 5)
        search.typeText(account)
        tapPoint(app.buttons["account." + account].firstMatch, timeout: 5)
    }

    private func tapKind(_ app: XCUIApplication, _ title: String) {
        tapPoint(app.segmentedControls.buttons[title].firstMatch, timeout: 5)
    }

    func testCloseProtectsChangesAndContinueKeepsForm() {
        let app = launch()
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        close.tap()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        app.buttons["放弃修改并关闭"].tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    func testKeptNewDraftCanBeReopened() {
        let app = launch()
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        close.tap()
        app.buttons["保留草稿并关闭"].tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        app.tabBars.buttons["记一笔"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["保留草稿并关闭"].waitForExistence(timeout: 5))
    }

    func testSwipeToDismissOffersTheSameUnsavedChangesChoices() {
        let app = launch()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 20))
        // Drag the sheet by its grabber. Starting on 关闭 was sometimes taken as holding that button, and the sheet
        // never moved (one full run in a few).
        let grabber = app.buttons["表单控制柄"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        start.press(forDuration: 0.15, thenDragTo: end)
        let confirmation = app.buttons["继续编辑"].waitForExistence(timeout: 5)
        if !confirmation { print(app.debugDescription) }
        XCTAssertTrue(confirmation)
        app.buttons["继续编辑"].tap()
        XCTAssertTrue(app.buttons["关闭"].exists)
    }

    func testEmptyIncomeFormClosesWithoutPrompt() {
        assertTypeOnlyClose("收入")
    }

    func testEmptyTransferFormClosesWithoutPrompt() {
        assertTypeOnlyClose("转账")
    }

    private func assertTypeOnlyClose(_ type: String) {
        let app = launch(filled: false)
        app.segmentedControls.buttons[type].tap()
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["保留草稿并关闭"].exists)
    }

    func testQuickAndFullFormsShareAmount() {
        let app = launch()
        openFull(app)
        XCTAssertEqual(app.textFields["0.00"].value as? String, "12")
        app.buttons["快捷记账"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
        openFull(app)
        XCTAssertEqual(app.textFields["0.00"].value as? String, "12")
    }

    func testAccountPickerCancelAndComplete() {
        let app = launch(filled: false)
        app.segmentedControls.buttons["转账"].tap()
        let to = app.buttons["draft.account.转入"]
        to.tap()
        let search = app.textFields["account.search"]
        tapPoint(search, timeout: 5)
        // One tap must retain focus through the medium → large sheet transition; do not tap again.
        assertCanType(app, into: search)
        XCTAssertLessThan(search.frame.minY, app.windows.firstMatch.frame.height / 3, "searching must expand the picker")
        search.typeText("Assets:Cash")
        XCTAssertTrue(app.buttons["account.cancel"].isHittable)
        let choice = app.buttons["account.Assets:Cash"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        let cancel = app.buttons["account.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertEqual(to.value as? String, "")
        to.tap()
        tapPoint(app.textFields["account.search"], timeout: 5)
        assertCanType(app, into: app.textFields["account.search"])
        app.textFields["account.search"].typeText("Assets:Cash")
        app.buttons["account.Assets:Cash"].firstMatch.tap()
        let done = app.buttons["account.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertEqual(to.value as? String, "Assets:Cash")
    }

    func testQuickContentsOpenAsSplitRowsAndReturn() {
        let app = launch()
        app.buttons["category.Expenses:Food"].firstMatch.tap()
        app.navigationBars.buttons["更多"].firstMatch.tap()
        app.buttons["分录（多行）"].tap()
        let row = app.textFields["draft.row.Expenses:Food"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "12.00")
        app.buttons["快捷记账"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
        openFull(app)
        XCTAssertEqual(app.textFields["0.00"].value as? String, "12")
    }

    /// 分录 left unbalanced used to lock the card: 支出 / 收入 / 转账 and 快捷记账 all said it couldn't convert. The rows
    /// now wait, as they were, while the user leaves and comes back
    func testAnUnfinishedSplitCanBeLeftAndComesBack() {
        let app = launch()
        app.buttons["category.Expenses:Food"].firstMatch.tap()
        app.navigationBars.buttons["更多"].firstMatch.tap()
        app.buttons["分录（多行）"].tap()
        let row = app.textFields["draft.row.Expenses:Food"]
        tapPoint(row, timeout: 5)
        assertCanType(app, into: row)
        row.typeText("9")
        let unbalanced = row.value as? String
        XCTAssertNotEqual(unbalanced, "12.00")

        // the full form's type picker (the quick page under it has a 支出 / 收入 / 转账 one of its own), back in sight:
        // typing in the row scrolled the form past it
        let types = app.segmentedControls.containing(.button, identifier: "分录").firstMatch
        for _ in 0..<6 where !(types.exists && types.isHittable) { app.swipeDown() }
        XCTAssertTrue(types.isHittable)
        types.buttons["支出"].tap()
        XCTAssertTrue(app.textFields["field.amount"].waitForExistence(timeout: 5), "still locked in 分录")
        types.buttons["分录"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, unbalanced)

        app.buttons["快捷记账"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5), "no way back to 快捷记账")
    }

    /// 清空 in the full form starts the 分录 over in one tap; 撤销 in the toast brings the rows back
    func testClearingTheFormStartsOverAndCanBeUndone() {
        let app = launch()
        app.buttons["category.Expenses:Food"].firstMatch.tap()
        app.navigationBars.buttons["更多"].firstMatch.tap()
        app.buttons["分录（多行）"].tap()
        let row = app.textFields["draft.row.Expenses:Food"]
        tapPoint(row, timeout: 5)
        assertCanType(app, into: row)
        row.typeText("9")
        let typed = row.value as? String

        app.buttons["form.clear"].tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "the rows are still there")
        let undo = app.buttons["撤销"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, typed)
    }

    func testQuickContentsOpenAsTextAndSourceWithoutClearing() {
        let app = launch()
        app.buttons["category.Expenses:Food"].firstMatch.tap()
        app.navigationBars.buttons["更多"].firstMatch.tap()
        app.buttons["quick.source"].tap()
        let source = app.textViews.firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue((source.value as? String ?? "").contains("Expenses:Food"))
        app.navigationBars.buttons["取消"].tap()
        app.navigationBars.buttons["更多"].firstMatch.tap()
        app.buttons["文本（Beancount 指令）"].tap()
        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String ?? "").contains("Expenses:Food"))
        XCTAssertTrue((text.value as? String ?? "").contains("12.00"))
        app.buttons["快捷记账"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
    }

    func testFullFormPointsToMissingAmount() {
        let app = launch(filled: false)
        openFull(app)
        let save = app.buttons["保存并关闭"]
        for _ in 0..<8 { if save.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.descendants(matching: .any)["field.error.amount"].waitForExistence(timeout: 5))
        let amount = app.textFields["field.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        assertCanType(app, into: amount)
        amount.typeText("25")
        // Both keys reach the field, but while the form relays out (the error goes away after the first key)
        // the value read straight after typing can still be the first key alone: wait for the exact value.
        let typed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "25"), object: amount)
        XCTAssertEqual(XCTWaiter().wait(for: [typed], timeout: 3), .completed, "value=\(amount.value ?? "nil")")
        XCTAssertFalse(app.descendants(matching: .any)["field.error.amount"].exists)
    }

    func testSaveAnotherClearsAmountAndKeepsForm() {
        let app = launch()
        let food = app.buttons["category.Expenses:Food"].firstMatch
        XCTAssertTrue(food.waitForExistence(timeout: 5)); food.tap()
        app.buttons["保存再记"].tap()
        XCTAssertTrue(app.staticTexts["金额"].waitForExistence(timeout: 10))
        let cleared = NSPredicate(format: "value == %@", "0")
        let reset = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: cleared, object: app.staticTexts["金额"])], timeout: 10)
        if reset != .completed { print(app.debugDescription) }
        XCTAssertEqual(reset, .completed)
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForNonExistence(timeout: 5))
    }

    /// 退款 from a transaction's page opens the full form; 保存再记 there puts the cursor in the amount
    /// synced: the fixture as a connected local folder ledger, rebuilt after the save and synced (the demo ledger
    /// is never rebuilt, so the purchase keeps its old text there)
    private func refundAndSaveAgain(synced: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = [synced ? "LEDGER_FOLDER" : "LEDGER_DEMO": fixture, "LEDGER_TAB": "journal", "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let row = app.staticTexts["Coffee"].firstMatch
        tapPoint(row, timeout: 20)
        let refund = app.buttons["退款"]
        if !refund.waitForExistence(timeout: 8) { tapPoint(row, timeout: 5) }
        tapPoint(refund, timeout: 8)
        // the full form: its save buttons are at the bottom, made as the form scrolls there
        XCTAssertTrue(app.staticTexts["登记退款"].waitForExistence(timeout: 10))
        let again = app.buttons["保存再记"]
        for _ in 0..<8 { if again.exists && again.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(again.isHittable); again.tap()
        return app
    }

    /// A button in a row is drawn 32 pt high but answers from 44 pt: a tap just above its edge still works
    func testARowButtonAnswersJustOutsideItsEdge() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "journal", "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let row = app.staticTexts["Coffee"].firstMatch
        tapPoint(row, timeout: 20)
        let refund = app.buttons["退款"]
        if !refund.waitForExistence(timeout: 8) { tapPoint(row, timeout: 5) }
        tapPoint(refund, timeout: 8)
        XCTAssertTrue(app.staticTexts["登记退款"].waitForExistence(timeout: 10))
        let cancel = app.buttons["refund.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        // what answers is 44 pt; the capsule drawn in its middle is 32 pt
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        // 4 pt above the drawn capsule (16 pt above its middle): outside it, inside what answers
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: -20)).tap()
        XCTAssertTrue(app.staticTexts["登记退款"].waitForNonExistence(timeout: 5), "the tap above the button was lost")
    }

    /// 设置 → 外观 → 明细样式: 图标 puts the category's icon before the payee, 紧凑 one line a transaction
    func testJournalStylesMoveThePayeeAndShortenTheRow() {
        func measure(_ style: String) -> CGRect {
            let app = XCUIApplication()
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
            app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "journal", "LEDGER_LANG": "zh"]
            app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-ledger.journal.style", style]
            app.launch()
            let payee = app.staticTexts["Coffee"].firstMatch
            XCTAssertTrue(payee.waitForExistence(timeout: 20))
            let cell = app.cells.containing(.staticText, identifier: "Coffee").firstMatch
            XCTAssertTrue(cell.exists)
            let r = CGRect(x: payee.frame.minX - cell.frame.minX, y: 0, width: 0, height: cell.frame.height)
            app.terminate()
            return r
        }
        continueAfterFailure = false
        let plain = measure("plain"), icon = measure("icon"), compact = measure("compact")
        XCTAssertGreaterThan(icon.minX, plain.minX + 30, "the icon goes before the payee")
        XCTAssertLessThan(compact.height, plain.height - 8, "one line instead of two")
    }

    /// After 保存再记 the cursor is put in the amount once: put the keyboard away at once, without typing, and it stays
    /// away (for 6s after the save the cursor was taken back each time, and the keyboard came up again)
    func testAfterSaveAgainTheKeyboardCanBePutAway() {
        let app = refundAndSaveAgain()
        let hide = app.buttons["收起键盘"]
        XCTAssertTrue(hide.waitForExistence(timeout: 8))
        hide.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        // and does not come back by itself
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 6), "the keyboard came back")
    }

    /// 保存再记 on a refund, then closing the card with nothing typed: the transaction's page is still there
    func testClosingAfterARefundSavedAgainKeepsTheTransactionPage() {
        let app = refundAndSaveAgain(synced: true)
        // the cursor goes to the amount and the keyboard comes up
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 8))
        // out of the full form to the card, then the card closed
        tapPoint(app.navigationBars.buttons["快捷记账"], timeout: 5)
        tapPoint(app.buttons["关闭"], timeout: 5)
        let discard = app.buttons["放弃"]
        if discard.waitForExistence(timeout: 2) { discard.tap() }
        XCTAssertTrue(app.buttons["关闭"].waitForNonExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["该交易已不存在"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["退款"].waitForExistence(timeout: 5))
    }

    func testSaveToastStaysUpAfterTheCardCloses() {
        let app = launch()
        let food = app.buttons["category.Expenses:Food"].firstMatch
        XCTAssertTrue(food.waitForExistence(timeout: 5))
        food.tap()
        app.buttons["保存并关闭"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForNonExistence(timeout: 10))
        let saved = app.descendants(matching: .any)["toast.message"]
        XCTAssertTrue(saved.waitForExistence(timeout: 8))
        XCTAssertTrue(saved.label.contains("已入账"))
        // A plain save toast is only about 3s, and resolving this label already
        // takes about a second. One more second is still inside that window.
        // Waiting a full two seconds, then querying again, lands on the moment
        // the plain toast is supposed to leave.
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: saved)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 1), .timedOut)
    }

    func testTagPickerCancelDoesNotChangeDraft() {
        let app = launch(filled: false)
        // spending's 标签 is in 更多
        app.buttons["quick.more"].tap(); tapPoint(app.buttons["标签…"].firstMatch, timeout: 5)
        let input = app.textFields["新标签，如 trip-shanghai"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("phase-two")
        app.buttons["添加"].tap()
        app.navigationBars.buttons["取消"].tap()
        app.buttons["quick.more"].tap(); tapPoint(app.buttons["标签…"].firstMatch, timeout: 5)
        XCTAssertFalse(app.staticTexts["#phase-two"].exists)
        app.navigationBars.buttons["取消"].tap()
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForNonExistence(timeout: 5))
    }

    /// The account, the day and 更多 (标签 for income and transfers) are one row, the same height for every kind, so
    /// the grid keeps its room; a line under the amount (here the fee) takes less than the row that was saved.
    func testChoicesAreOneRowAndTheGridKeepsItsRoom() {
        let app = launch()
        let grid = app.scrollViews["quick.grid"]
        let more = app.buttons["quick.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        let funding = app.buttons["付款账户"].firstMatch
        XCTAssertEqual(funding.frame.midY, more.frame.midY, accuracy: 1)
        XCTAssertEqual(funding.frame.height, more.frame.height, accuracy: 0.5)
        XCTAssertFalse(app.buttons["保存至"].exists)
        let height = grid.frame.height
        let row = more.frame.height
        for kind in ["收入", "转账"] {
            tapKind(app, kind)
            let tag = app.buttons["标签"].firstMatch
            XCTAssertTrue(tag.waitForExistence(timeout: 5))
            XCTAssertFalse(more.exists)
            XCTAssertEqual(grid.frame.height, height, accuracy: 0.5, kind)
            XCTAssertEqual(tag.frame.height, row, accuracy: 0.5, kind)
        }
        tapKind(app, "支出")
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertEqual(grid.frame.height, height, accuracy: 0.5)
        // picking a category changes the symbol beside 收付款方 · 摘要, not the height below the grid
        for category in ["category.Expenses:Food", "category.Expenses:Fee"] {
            let cell = app.buttons[category].firstMatch
            guard cell.waitForExistence(timeout: 5) else { continue }
            cell.tap()
            XCTAssertEqual(grid.frame.height, height, accuracy: 0.5, category)
        }
        app.buttons["draft.rate"].tap()
        let fee = app.textFields["transfer.fee.amount"]
        tapPoint(fee, timeout: 5)
        assertCanType(app, into: fee)
        fee.typeText("2")
        app.buttons["收起键盘"].tap()
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["expense.fee"].waitForExistence(timeout: 5))
        XCTAssertLessThan(height - grid.frame.height, row, "the fee line costs less than the row the choices gave back")
    }

    func testManualFundingSurvivesPayeeSuggestionInFullForm() {
        let app = launch()
        openFull(app)
        let funding = app.descendants(matching: .any)["field.付款账户"]
        for _ in 0..<5 { if funding.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(funding.isHittable); funding.tap()
        pickAccount(app, "Assets:Cash")
        app.navigationBars.buttons["完成"].tap()
        let merchant = app.textFields["收付款方（如 便利店、淘宝）"]
        for _ in 0..<5 { if merchant.isHittable { break }; app.swipeDown() }
        merchant.tap()
        if !waitForSoftwareKeyboard(app, field: merchant, timeout: 3).focused {
            merchant.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        }
        assertCanType(app, into: merchant)
        merchant.typeText("Coffee\n")
        let done = app.buttons["收起键盘"].firstMatch
        if done.exists { done.tap() }
        for _ in 0..<5 { if funding.exists { break }; app.swipeUp() }
        XCTAssertEqual(funding.value as? String, "Assets:Cash")
    }

    private func openFull(_ app: XCUIApplication) {
        app.navigationBars.buttons["更多"].firstMatch.tap(); app.buttons["完整表单"].tap()
        XCTAssertTrue(app.buttons["快捷记账"].waitForExistence(timeout: 5))
    }

    /// The full form's date has 今天, 昨天, 前天 like the entry's date sheet; the one picked is shown as chosen
    func testFormDateHasTheSameThreeDays() {
        let app = launch()
        openFull(app)
        let before = app.buttons["前天"].firstMatch
        for _ in 0..<4 where !(before.exists && before.isHittable) { app.swipeUp() }
        XCTAssertTrue(app.buttons["今天"].firstMatch.exists)
        XCTAssertTrue(app.buttons["昨天"].firstMatch.exists)
        XCTAssertTrue(app.buttons["今天"].firstMatch.isSelected, "a new entry starts on today")
        tapPoint(before, timeout: 5)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: before)], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["今天"].firstMatch.isSelected)
    }

    /// The fee is set in 币种、汇率与手续费 (no row of its own); once set, its line under the amount opens it again.
    func testTransferFeeCancelCompleteAndKeyboardDismissal() {
        let app = launch()
        tapKind(app, "转账")
        let fee = app.buttons["transfer.fee"]
        XCTAssertFalse(fee.exists)
        tapPoint(app.buttons["draft.rate"], timeout: 5)
        let input = app.textFields["transfer.fee.amount"]
        tapPoint(input, timeout: 5)
        assertCanType(app, into: input)
        input.typeText("2")
        tapPoint(app.buttons["收起键盘"], timeout: 5)
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["draft.rate"].waitForExistence(timeout: 5))
        XCTAssertFalse(fee.exists)
        app.buttons["draft.rate"].tap()
        tapPoint(input, timeout: 5)
        assertCanType(app, into: input)
        input.typeText("2")
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(fee.waitForExistence(timeout: 5))
        XCTAssertEqual(fee.value as? String, "2")
    }

    func testExchangeTargetCurrencyAndQuoteDirectionApply() {
        let app = launch()
        tapKind(app, "转账")
        app.buttons["draft.account.转入"].tap()
        tapPoint(app.buttons["account.Assets:Bank:ExampleFX"].firstMatch, timeout: 5)
        app.navigationBars.buttons["完成"].tap()
        app.buttons["draft.rate"].tap()
        let picker = app.descendants(matching: .any)["rate.targetCurrency"].firstMatch
        tapPoint(picker, timeout: 5)
        tapPoint(app.buttons["GBP"].firstMatch, timeout: 5)
        app.descendants(matching: .any)["transfer.fee.mode"].firstMatch.tap()
        tapPoint(app.buttons["转出金额已含手续费"].firstMatch, timeout: 5)
        let fee = app.textFields["transfer.fee.amount"]
        fee.tap()
        assertCanType(app, into: fee)
        fee.typeText("2")
        let received = app.textFields["rate.converted"]
        XCTAssertTrue(received.waitForExistence(timeout: 5))
        received.tap()
        assertCanType(app, into: received)
        received.typeText("1.2")
        tapPoint(app.buttons["收起键盘"], timeout: 5)
        app.buttons["交换汇率方向"].tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "换汇-汇率与手续费同页"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["更多"].firstMatch.tap()
        app.buttons["quick.source"].tap()
        let text = app.textViews.firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let value = text.value as? String ?? ""
        XCTAssertTrue(value.contains("GBP"))
        XCTAssertTrue(value.contains("exchange_rate: \"1 GBP ="))
        XCTAssertTrue(value.contains("@@ 10.00 CNY"))
        XCTAssertTrue(value.contains("fee_mode: \"included\""))
    }

    /// FX4: the fee account picker used to close itself right after opening (its sheet was copied onto
    /// every row of the fee section). It must stay open long enough to search, pick and confirm.
    func testSeparateFeeAccountPickerStaysOpenAndApplies() {
        let app = launch()
        tapKind(app, "转账")
        app.buttons["draft.account.转入"].tap()
        tapPoint(app.buttons["account.Assets:Bank:ExampleFX"].firstMatch, timeout: 5)
        app.navigationBars.buttons["完成"].tap()
        app.buttons["draft.rate"].tap()
        tapPoint(app.descendants(matching: .any)["transfer.fee.mode"].firstMatch, timeout: 5)
        tapPoint(app.buttons["其他账户或币种单独支付"].firstMatch, timeout: 5)
        let payer = app.buttons["transfer.fee.account"]
        tapPoint(payer, timeout: 5)
        let search = app.textFields["account.search"]
        tapPoint(search, timeout: 5)
        search.typeText("Assets:Cash")
        let choice = app.buttons["account.Assets:Cash"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        let done = app.buttons["account.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertTrue(app.textFields["account.search"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(payer.waitForExistence(timeout: 5))
        XCTAssertTrue(payer.label.contains("Cash"), payer.label)
    }

    /// 明细 search runs when typing is finished (搜索 on the keyboard), not on every keystroke; clearing restores all.
    func testJournalSearchAppliesOnSubmitAndClearRestores() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "journal", "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Coffee"].firstMatch.waitForExistence(timeout: 20))
        let result = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "筛选结果")).firstMatch
        let search = app.searchFields.firstMatch
        tapPoint(search, timeout: 5)
        search.typeText("Coffee")
        XCTAssertFalse(result.exists, "searching while still typing")
        XCTAssertTrue(app.staticTexts["Example supplier"].firstMatch.exists)
        search.typeText("\n")
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertEqual(result.label, "筛选结果 · 1 笔")
        XCTAssertFalse(app.staticTexts["Example supplier"].firstMatch.exists)
        // 清除 empties the applied search and the box together
        tapPoint(app.buttons["清除"].firstMatch, timeout: 5)
        XCTAssertTrue(result.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Example supplier"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertNotEqual(search.value as? String, "Coffee")
    }

    /// The saved searches (and 保存 for the one applied) scroll with the list. Pinned under the search box, the large
    /// title collapsing moved them, which pushed the list back and opened the title again, over and over.
    func testQuickSearchesScrollWithTheJournal() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        app.launchEnvironment = ["LEDGER_DEMO": fixtures.path, "LEDGER_EXTRA": fixtures.appendingPathComponent("journal-extra.bean").path,
                                 "LEDGER_TAB": "journal", "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Coffee"].firstMatch.waitForExistence(timeout: 20))
        let search = app.searchFields.firstMatch
        tapPoint(search, timeout: 5)
        search.typeText("Cafe\n")
        let save = app.buttons["保存"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable)
        let window = app.windows.firstMatch.frame
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: window.midY + 120))
        for _ in 0..<3 {
            start.press(forDuration: 0, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertFalse(save.exists && save.isHittable, "scrolled away with the list, not pinned under the search box")
    }

    func testCopiedExpenseShowsPartyAndDescriptionInQuickEditor() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "journal", "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let original = app.staticTexts["Coffee"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 20))
        original.press(forDuration: 1)
        let copyMenu = app.buttons["entry.copy"].firstMatch
        XCTAssertTrue(copyMenu.waitForExistence(timeout: 5))
        XCTAssertTrue(copyMenu.isHittable)
        copyMenu.tap()
        // iOS 27 no longer exposes identifiers of buttons in a nested context submenu; its title still identifies it.
        let duplicate = app.buttons["复制为新交易"].firstMatch
        let appeared = duplicate.waitForExistence(timeout: 5)
        if !appeared { print(app.debugDescription) }
        XCTAssertTrue(appeared)
        duplicate.tap()
        let summary = app.buttons["收付款方与摘要"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue((summary.value as? String ?? "").contains("Coffee"))
        XCTAssertTrue((summary.value as? String ?? "").contains("Interaction test"))
        app.navigationBars.buttons["更多"].firstMatch.tap()
        app.buttons["quick.source"].tap()
        let source = app.textViews.firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue((source.value as? String ?? "").contains("Coffee"))
        XCTAssertTrue((source.value as? String ?? "").contains("Interaction test"))
    }

    /// 编辑源文本 has 关闭 ✕ on the left and 保存 ✓ on the right, not two ✓ buttons.
    func testSourceEditorClosesWithXNotASecondCheckmark() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "journal", "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let original = app.staticTexts["Coffee"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 20))
        original.press(forDuration: 1)
        let sourceMenu = app.buttons["源文件"].firstMatch
        XCTAssertTrue(sourceMenu.waitForExistence(timeout: 5))
        sourceMenu.tap()
        let edit = app.buttons["编辑源文本"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let bar = app.navigationBars["编辑源文本"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.buttons["关闭"].exists)
        XCTAssertTrue(bar.buttons["保存"].exists)
        XCTAssertFalse(bar.buttons["完成"].exists)
        bar.buttons["关闭"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
    }

    func testReimbursementCurrencySeparatesAdvancesAndProtectsChanges() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "overview", "LEDGER_LANG": "zh", "LEDGER_REIMB": "1"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let local = app.buttons["reimbursement.row.CNY"]
        XCTAssertTrue(local.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["reimbursement.row.HKD"].exists)
        tapPoint(app.descendants(matching: .any)["reimbursement.currency"].firstMatch, timeout: 5)
        tapPoint(app.buttons["HKD"].firstMatch, timeout: 5)
        XCTAssertTrue(app.buttons["reimbursement.row.HKD"].waitForExistence(timeout: 5))
        XCTAssertFalse(local.exists)
        app.navigationBars.buttons["取消"].tap()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].tap()
        XCTAssertTrue(app.buttons["reimbursement.row.HKD"].exists)
    }

    func testQuickCandidatesStayAboveKeyboardAndRemainTappable() {
        let app = openExistingExpense()
        app.buttons["收付款方与摘要"].tap()
        let note = app.textFields["quick.narration"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let noteCandidate = app.buttons["quick.narration.suggestion"].firstMatch
        XCTAssertTrue(noteCandidate.waitForExistence(timeout: 5))
        XCTAssertTrue(noteCandidate.isHittable)
        XCTAssertLessThanOrEqual(noteCandidate.frame.maxY, keyboard.frame.minY)
        noteCandidate.tap()
        XCTAssertEqual(note.value as? String, "Interaction test")
        let party = app.textFields["quick.payee"]
        party.tap()
        let partyCandidate = app.buttons["quick.payee.suggestion"].firstMatch
        XCTAssertTrue(partyCandidate.waitForExistence(timeout: 5))
        XCTAssertTrue(partyCandidate.isHittable)
        XCTAssertLessThanOrEqual(partyCandidate.frame.maxY, keyboard.frame.minY)
        partyCandidate.tap()
        XCTAssertEqual(party.value as? String, "Coffee")
        note.tap(); note.typeText(" updated")
        XCTAssertEqual(note.value as? String, "Interaction test updated")
        app.buttons["quick.text.done"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        XCTAssertTrue((app.buttons["收付款方与摘要"].value as? String ?? "").contains("updated"))
    }

    func testImportKeepsFundingChoiceAfterClosingAndReopening() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        app.launchEnvironment = ["LEDGER_DEMO": directory.path, "LEDGER_TAB": "add", "LEDGER_LANG": "zh", "LEDGER_IMPORT": directory.appendingPathComponent("recovery.csv").path]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let funding = app.buttons["import.funding"].firstMatch
        // a run before kept its progress on this simulator (this test ends by resuming it): carry on from there
        let resume = app.buttons["继续上次导入"]
        if !funding.waitForExistence(timeout: 20), resume.exists { resume.tap() }
        tapPoint(funding, timeout: 20)
        pickAccount(app, "Assets:Cash")
        app.navigationBars.buttons["完成"].tap()
        XCTAssertEqual(funding.value as? String, "Assets:Cash")
        app.navigationBars.buttons["保留进度并关闭"].tap()
        app.navigationBars.buttons["更多"].firstMatch.tap()
        app.buttons["导入账单"].tap()
        tapPoint(app.buttons["继续上次导入"], timeout: 5)
        XCTAssertTrue(funding.waitForExistence(timeout: 5))
        XCTAssertEqual(funding.value as? String, "Assets:Cash")
    }

    func testHiddenAmountsStayHiddenInAccessibilityAtLargeTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "overview", "LEDGER_LANG": "zh", "LEDGER_PRIVACY": "1", "LEDGER_CHART": "donut"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let hidden = app.descendants(matching: .any)["金额已隐藏"].firstMatch
        XCTAssertTrue(hidden.waitForExistence(timeout: 20))
        tapPoint(app.buttons["显示金额"].firstMatch, timeout: 5)
        XCTAssertTrue(hidden.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["隐藏金额"].firstMatch.exists)
    }

    func testExpenseRateAndFeeApplyTogetherAndCancelKeepsOriginal() {
        let app = openExistingExpense()
        app.buttons["draft.rate"].tap()
        let fee = app.textFields["transfer.fee.amount"]
        XCTAssertTrue(fee.waitForExistence(timeout: 5))
        fee.tap()
        assertCanType(app, into: fee)
        fee.typeText("2")
        app.buttons["收起键盘"].tap()
        app.navigationBars.buttons["取消"].tap()
        XCTAssertFalse(app.buttons["expense.fee"].exists)
        XCTAssertEqual(app.staticTexts["金额"].value as? String, "12")
        app.buttons["draft.rate"].tap()
        XCTAssertTrue(fee.waitForExistence(timeout: 5))
        XCTAssertNotEqual(fee.value as? String, "2")
        fee.tap()
        assertCanType(app, into: fee)
        fee.typeText("2")
        app.buttons["收起键盘"].tap()
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "支出-币种汇率与手续费统一编辑"
        image.lifetime = .keepAlways
        add(image)
        app.navigationBars.buttons["完成"].tap()
        XCTAssertEqual(app.buttons["expense.fee"].value as? String, "2")
        app.navigationBars.buttons["更多"].firstMatch.tap()
        // Editing shows a keypad key and a menu item that share the title 源文本. Open the menu, then use the menu item.
        XCTAssertTrue(app.buttons["quick.keypad.source"].waitForExistence(timeout: 5))
        let menuSource = app.buttons.matching(identifier: "quick.source")
        XCTAssertEqual(menuSource.count, 1)
        menuSource.element.tap()
        let source = app.textViews.firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        let text = source.value as? String ?? ""
        XCTAssertTrue(text.contains("Expenses:Fee:Bank"))
        XCTAssertTrue(text.contains("14.00 CNY"))
        XCTAssertTrue(text.contains("12.00 CNY"))
    }

    func testAccountActionsRemainReadableAndUsableAtLargestTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "add", "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-ledger.appearance", "dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 20))
        let to = showTransferAccount(app)
        to.tap()
        let search = app.textFields["account.search"]
        tapPoint(search, timeout: 5)
        // One tap must retain focus through the medium → large sheet transition; do not tap again.
        assertCanType(app, into: search)
        XCTAssertLessThan(search.frame.minY, app.windows.firstMatch.frame.height / 3, "searching must expand the picker")
        search.typeText("Assets:Cash")
        app.buttons["account.Assets:Cash"].firstMatch.tap()
        let cancel = app.buttons["account.cancel"]
        let done = app.buttons["account.done"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(done.isHittable)
        XCTAssertEqual(cancel.label, "取消")
        XCTAssertEqual(done.label, "完成")
        XCTAssertLessThanOrEqual(cancel.frame.maxX, done.frame.minX)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "账户选择器-最大字体-深色-图标与操作"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        done.tap()
        XCTAssertEqual(to.value as? String, "Assets:Cash")
    }

    /// Switch to 转账 and return the 转入 row.
    ///
    /// At the largest accessibility size, a tap aimed at the right side of the kind control once
    /// opened the day calendar. 月 was on screen but not hittable, and tapping it failed the test.
    /// Tap the 转账 segment itself. If the calendar is in front, close it with 完成 or a swipe,
    /// then try the segment again. Do not tap 月.
    private func showTransferAccount(_ app: XCUIApplication) -> XCUIElement {
        let transfer = app.segmentedControls.buttons["转账"]
        XCTAssertTrue(transfer.waitForExistence(timeout: 5))
        let to = app.buttons["draft.account.转入"]
        for _ in 0..<3 {
            transfer.tap()
            if to.waitForExistence(timeout: 3) { return to }
            closeDaySheetIfPresent(app)
        }
        XCTAssertTrue(to.waitForExistence(timeout: 2), "转入 was not on screen.\n\(app.debugDescription)")
        return to
    }

    private func closeDaySheetIfPresent(_ app: XCUIApplication) {
        let done = app.navigationBars["日期"].buttons["完成"]
        if done.exists && done.isHittable {
            done.tap()
            return
        }
        if app.buttons["月"].exists || app.buttons["今天"].exists {
            app.swipeDown()
        }
    }

    /// True when this field is the keyboard's first responder. The trait is present even if a
    /// hardware keyboard is hiding the on-screen keys; `app.keyboards` is not.
    private func isKeyboardFocused(_ field: XCUIElement) -> Bool {
        field.exists && field.debugDescription.contains("Keyboard Focused")
    }

    private func waitForSoftwareKeyboard(_ app: XCUIApplication, field: XCUIElement, timeout: TimeInterval) -> (focused: Bool, keyboard: Bool) {
        let ready = NSPredicate { _, _ in
            self.isKeyboardFocused(field) && app.keyboards.firstMatch.exists
        }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app)], timeout: timeout)
        return (isKeyboardFocused(field), app.keyboards.firstMatch.exists)
    }

    /// Fails with the two causes separated: the form never moved the cursor, or the Simulator
    /// hardware keyboard is connected so the software keyboard cannot appear.
    private func assertCanType(_ app: XCUIApplication, into field: XCUIElement, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line) {
        let ready = waitForSoftwareKeyboard(app, field: field, timeout: timeout)
        if !(ready.focused && ready.keyboard) { print(app.debugDescription) }
        XCTAssertTrue(ready.focused && ready.keyboard, """
            field exists=\(field.exists), hittable=\(field.isHittable), focused=\(ready.focused), \
            frame=\(field.frame), software keyboard=\(ready.keyboard). \
            Not focused: validation did not move the cursor onto this field. \
            Focused without a software keyboard: the Simulator hardware keyboard is still connected.
            """, file: file, line: line)
    }

    private func launchCardAccount(accessibility: Bool, style: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        app.launchEnvironment = [
            "LEDGER_DEMO": fixtures.path,
            "LEDGER_EXTRA": fixtures.appendingPathComponent("card-extra.bean").path,
            "LEDGER_TAB": "accounts",
            "LEDGER_OPEN_ACCOUNT": "Liabilities:CreditCard:Example",
            "LEDGER_LANG": "zh",
        ]
        var args = ["-AppleLanguages", "(zh-Hans)"] + (style.map { ["-ledger.card.style", $0] } ?? [])
        if accessibility {
            args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchArguments = args
        app.launch()
        return app
    }

    /// Move toward the control in short drags. A full-page flick can pass a button between snapshots;
    /// if its cell has left the accessibility tree, return toward this card at the top of the list.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            // a list still moving from the last drag takes a tap as "stop" rather than a press on the button
            if element.exists { waitUntilStill(element) }
            let window = app.windows.firstMatch.frame
            let navigation = app.navigationBars.firstMatch
            let search = app.searchFields.firstMatch
            let tabs = app.tabBars.firstMatch
            let top = max(navigation.exists ? navigation.frame.maxY : window.minY,
                          search.exists && search.isHittable ? search.frame.maxY : window.minY)
            let bottom = tabs.exists ? tabs.frame.minY : window.maxY
            // hittable is not enough: under the large navigation bar it still is, and the tap lands on the bar
            if element.exists && element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom { return }
            let height = bottom - top
            let middle = top + height / 2
            let delta = element.exists ? element.frame.midY - middle : -height
            let distance = min(max(abs(delta), 32), height * 0.35)
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.midX, dy: middle))
            let end = start.withOffset(CGVector(dx: 0, dy: delta > 0 ? -distance : distance))
            start.press(forDuration: 0, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        }
    }

    /// the element reads the same frame twice in a row
    private func waitUntilStill(_ element: XCUIElement) {
        var last = CGRect.null
        let still = expectation(for: NSPredicate { _, _ in
            let frame = element.frame
            defer { last = frame }
            return frame == last
        }, evaluatedWith: nil)
        wait(for: [still], timeout: 5)
    }

    /// An exchange inside one account: its two currencies stack on the right, each on one line, and the payee
    /// keeps its room (side by side they squeezed the payee and broke the amounts across lines).
    func testExchangeInAnAccountStacksBothCurrencies() {
        for size in [nil, "UICTContentSizeCategoryXXL"] {
            let extra = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fx-extra.bean").path
            let app = launchTab("accounts", textSize: size, env: ["LEDGER_EXTRA": extra, "LEDGER_OPEN_ACCOUNT": "Assets:Bank:ExampleFX"])
            let hkd = app.staticTexts["+HK$123,456.70"].firstMatch
            let gbp = app.staticTexts["-£12,345.67"].firstMatch
            let payee = app.staticTexts["Example exchange counter"].firstMatch
            XCTAssertTrue(hkd.waitForExistence(timeout: 20))
            XCTAssertTrue(gbp.exists)
            XCTAssertTrue(payee.exists)
            let top = gbp.frame.minY < hkd.frame.minY ? gbp : hkd, bottom = top == gbp ? hkd : gbp
            XCTAssertGreaterThanOrEqual(bottom.frame.minY, top.frame.maxY - 1, "stacked, not side by side")
            XCTAssertEqual(hkd.frame.maxX, gbp.frame.maxX, accuracy: 1, "both right-aligned")
            XCTAssertEqual(hkd.frame.height, gbp.frame.height, accuracy: 1, "each on one line")
            XCTAssertLessThan(hkd.frame.height, payee.frame.height * 1.5, "each on one line")
            XCTAssertGreaterThan(payee.frame.width, app.frame.width * 0.3, "the payee is not squeezed")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "账户内换汇-两种货币上下排列-\(size ?? "默认字号")"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    /// 设置 → 外观 → 账户卡片 → 卡面: the bill's top is drawn as the card; the figures and buttons under it stay
    func testCardFaceKeepsTheFiguresAndButtons() {
        let app = launchCardAccount(accessibility: false, style: "card")
        let face = app.descendants(matching: .any)["card.face"]
        XCTAssertTrue(face.waitForExistence(timeout: 20))
        XCTAssertTrue(face.label.contains("剩余应还"), face.label)
        XCTAssertTrue(face.label.contains("已还"), face.label)
        XCTAssertTrue(app.staticTexts["最低还款"].exists)
        let bill = app.buttons["填写本期账单"].firstMatch
        XCTAssertTrue(bill.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(bill.frame.minY, face.frame.maxY, "the buttons come after the card")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "信用卡账单-卡面"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// 设置 → 外观 → 账户卡片 → 卡面 on a bank account: its top is a card with the balance, when it was last checked
    /// and this month's money in and out; the buttons stay under it
    func testAssetAccountFaceKeepsTheBalanceAndButtons() {
        for size in [nil, "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
            app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "accounts", "LEDGER_OPEN_ACCOUNT": "Assets:Bank:CGB", "LEDGER_LANG": "zh"]
            app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-ledger.card.style", "card"]
                + (size.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
            app.launch()
            let face = app.descendants(matching: .any)["card.face"]
            XCTAssertTrue(face.waitForExistence(timeout: 20))
            XCTAssertTrue(face.label.contains("当前余额"), face.label)
            XCTAssertTrue(face.label.contains("核对"), face.label)
            XCTAssertTrue(face.label.contains("本月流入"), face.label)
            XCTAssertTrue(face.label.contains("Assets:Bank:CGB"), "the account's full name, as on the plain header: \(face.label)")
            XCTAssertLessThanOrEqual(face.frame.maxX, app.frame.width + 1, "the card fits the screen")
            // inside the same panel as a credit card's: the list's margin and the panel's own padding
            XCTAssertGreaterThanOrEqual(face.frame.minX, 24, "the card sits inside the panel")
            let detail = app.buttons["查看明细"].firstMatch
            let check = app.buttons["余额核对"].firstMatch
            XCTAssertTrue(check.waitForExistence(timeout: 5))
            XCTAssertTrue(detail.exists)
            XCTAssertGreaterThan(check.frame.minY, face.frame.maxY, "the buttons come after the card")
            XCTAssertGreaterThanOrEqual(detail.frame.minX, face.frame.minX - 1, "the buttons line up with the card")
            XCTAssertLessThanOrEqual(check.frame.maxX, face.frame.maxX + 1, "the buttons line up with the card")
            if size == nil {
                // as on a credit card's panel: one row of two equal capsules
                XCTAssertLessThan(abs(detail.frame.midY - check.frame.midY), 12)
                XCTAssertEqual(detail.frame.height, check.frame.height, accuracy: 2)
                XCTAssertEqual(detail.frame.width, check.frame.width, accuracy: 2)
                XCTAssertGreaterThanOrEqual(detail.frame.height, 36)
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "账户卡面-银行-\(size ?? "默认字号")"
            shot.lifetime = .keepAlways
            add(shot)
            app.terminate()
        }
    }

    func testCardBillActionsStayOnOneRowAtNormalTextSize() {
        let app = launchCardAccount(accessibility: false)
        let bill = app.buttons["填写本期账单"].firstMatch
        let repay = app.buttons["记录还款"].firstMatch
        XCTAssertTrue(bill.waitForExistence(timeout: 20))
        XCTAssertTrue(repay.waitForExistence(timeout: 5))
        XCTAssertEqual(bill.label, "填写本期账单")
        XCTAssertEqual(repay.label, "记录还款")
        XCTAssertLessThan(bill.frame.maxX, repay.frame.minX + 1)
        XCTAssertLessThan(abs(bill.frame.midY - repay.frame.midY), 12)
        XCTAssertEqual(bill.frame.width, repay.frame.width, accuracy: 2)
        XCTAssertEqual(bill.frame.height, repay.frame.height, accuracy: 2)
        XCTAssertGreaterThanOrEqual(bill.frame.height, 36)
        XCTAssertLessThan(bill.frame.minX, app.frame.width * 0.45)
        XCTAssertLessThan(bill.frame.width, app.frame.width * 0.7)
        XCTAssertLessThan(repay.frame.width, app.frame.width * 0.7)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "信用卡账单按钮-普通字号-靠左一行"
        shot.lifetime = .keepAlways
        add(shot)
        reveal(bill, in: app)
        XCTAssertTrue(bill.isHittable)
        bill.tap()
        XCTAssertTrue(app.navigationBars["本期账单"].waitForExistence(timeout: 5))
    }

    func testCardBillActionsStackAtAccessibilityTextSize() {
        let app = launchCardAccount(accessibility: true)
        let bill = app.buttons["填写本期账单"].firstMatch
        let repay = app.buttons["记录还款"].firstMatch
        XCTAssertTrue(bill.waitForExistence(timeout: 20))
        XCTAssertTrue(repay.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(repay.frame.minY, bill.frame.maxY - 2)
        XCTAssertEqual(bill.frame.width, repay.frame.width, accuracy: 2)
        XCTAssertGreaterThan(bill.frame.width, app.frame.width * 0.5)
        XCTAssertLessThanOrEqual(bill.frame.maxX, app.frame.width + 1)
        XCTAssertLessThanOrEqual(repay.frame.maxX, app.frame.width + 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "信用卡账单按钮-最大字号-上下排列"
        shot.lifetime = .keepAlways
        add(shot)
        reveal(bill, in: app)
        XCTAssertTrue(bill.isHittable)
        reveal(repay, in: app)
        XCTAssertTrue(repay.isHittable)
        repay.tap()
        XCTAssertTrue(app.navigationBars["信用卡还款"].waitForExistence(timeout: 5))
    }

    func testCardBillActionCanBeReachedAfterScrollingPastIt() {
        let app = launchCardAccount(accessibility: true)
        let bill = app.buttons["填写本期账单"].firstMatch
        XCTAssertTrue(bill.waitForExistence(timeout: 20))
        let lowerSection = app.staticTexts["额度与账单"].firstMatch
        for _ in 0..<8 {
            if lowerSection.exists && lowerSection.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(lowerSection.isHittable)
        XCTAssertFalse(bill.isHittable, "start below the bill action, so reaching it requires scrolling back")
        reveal(bill, in: app)
        XCTAssertTrue(bill.isHittable)
        bill.tap()
        XCTAssertTrue(app.navigationBars["本期账单"].waitForExistence(timeout: 5))
    }

    func testUntouchedFormClosesWithoutPrompt() {
        let app = launch(filled: false)
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["放弃修改并关闭"].exists)
    }

    /// The journal's calendar is the system's: it keeps its height from month to month (a four-week February as a
    /// six-week one), so the list under it does not move; open, it takes the quick filters' place, and what is on
    /// stays with its ✕
    func testTheCalendarTakesTheQuickFiltersPlaceAndKeepsItsHeight() {
        let app = launchTab("journal", env: ["LEDGER_FILTERS": "large", "LEDGER_GLASS_CALENDAR": "0"])
        // the calendar opens as it was left
        let toggle = app.buttons.matching(NSPredicate(format: "label IN %@", ["月历", "收起月历"])).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        let calendar = app.descendants(matching: .any)["calendar.month"].firstMatch
        if !calendar.exists { tapPoint(app.buttons["月历"], timeout: 5) }
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["本月"].exists)
        XCTAssertFalse(app.buttons["#refund"].exists)
        XCTAssertTrue(app.buttons["清除"].exists)
        let height = calendar.frame.height, below = app.otherElements["calendar.figures"].frame.minY
        let previous = calendar.buttons["上个月"]
        for _ in 0..<8 {
            previous.tap()
            XCTAssertEqual(calendar.frame.height, height, accuracy: 0.5)
            XCTAssertEqual(app.otherElements["calendar.figures"].frame.minY, below, accuracy: 0.5)
        }
        // closed again, the quick filters are back
        tapPoint(app.buttons["收起月历"], timeout: 5)
        XCTAssertTrue(app.buttons["本月"].waitForExistence(timeout: 5))
    }

    /// A day's dots sit centred under its date; the system puts a decoration at the day's leading edge, and they
    /// were off to the left of it
    func testTheCalendarDotsSitUnderTheirDate() {
        let app = launchTab("journal", env: ["LEDGER_GLASS_CALENDAR": "0"])
        let calendar = app.descendants(matching: .any)["calendar.month"].firstMatch
        let toggle = app.buttons.matching(NSPredicate(format: "label IN %@", ["月历", "收起月历"])).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        if !calendar.exists { tapPoint(app.buttons["月历"], timeout: 5) }
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        let dots = calendar.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'calendar.dots.'"))
        for _ in 0..<24 where dots.count == 0 { calendar.buttons["上个月"].tap() }
        XCTAssertGreaterThan(dots.count, 0)
        for i in 0..<min(dots.count, 6) {
            let dot = dots.element(boundBy: i).frame
            let day = calendar.buttons.allElementsBoundByIndex.first { $0.frame.width < calendar.frame.width / 2 && $0.frame.contains(CGPoint(x: dot.midX, y: dot.midY)) }
            XCTAssertNotNil(day)
            if let day { XCTAssertEqual(dot.midX, day.frame.midX, accuracy: 1, "\(dots.element(boundBy: i).identifier)") }
        }
    }

    private func openGlassCalendar(_ app: XCUIApplication) -> XCUIElement {
        let toggle = app.buttons.matching(NSPredicate(format: "label IN %@", ["月历", "收起月历"])).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        let card = app.descendants(matching: .any)["calendar.glass"].firstMatch
        if !card.exists { tapPoint(app.buttons["月历"], timeout: 5) }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        return card
    }

    private func chooseCalendarMonth(_ app: XCUIApplication, year: String, month: String) {
        tapPoint(app.buttons["calendar.monthTitle"], timeout: 5)
        // the wheels can only be turned once the popover has finished appearing: turning one while it still
        // animates in fails with "Failed to get possible values for picker"
        for (name, value) in [("calendar.yearWheel", year), ("calendar.monthWheel", month)] {
            let wheel = app.pickers[name].pickerWheels.firstMatch
            XCTAssertTrue(wheel.waitForExistence(timeout: 5))
            // asking for hittability before the wheel has a frame ({inf, inf}) fails the test outright instead of
            // answering no, so wait for a real frame first; and it is already hittable while the sheet still slides
            // up, so also wait until two reads in a row find it in the same place. On a slow runner the sheet's
            // contents can lose their frame again right after that, so frame, place and hittability are one wait
            var previous = CGRect.null
            let ready = expectation(for: NSPredicate { _, _ in
                let frame = wheel.frame
                defer { previous = frame }
                guard !frame.isInfinite && !frame.isNull && frame.width > 0 && frame.height > 0 && frame == previous
                else { return false }
                return wheel.isHittable
            }, evaluatedWith: nil)
            wait(for: [ready], timeout: 15)
            wheel.adjust(toPickerWheelValue: value)
        }
        tapPoint(app.buttons["完成"], timeout: 5)
    }

    func testGlassCalendarFixedRowsAndDaySelection() {
        checkGlassCalendar(textSize: nil)
    }

    func testGlassCalendarFixedRowsAndDaySelectionAtLargeText() {
        checkGlassCalendar(textSize: "UICTContentSizeCategoryXXXL")
    }

    private func checkGlassCalendar(textSize: String?) {
        let app = launchTab("journal", textSize: textSize, env: ["LEDGER_CALENDAR": "1"])
        let card = openGlassCalendar(app)
        let height = card.frame.height
        let figuresY = app.otherElements["calendar.figures"].frame.minY
        // Six fixed rows, so a short month and a long month keep the same card height.
        for (year, month) in [("2015", "2"), ("2021", "4"), ("2021", "5")] {
            chooseCalendarMonth(app, year: year, month: month)
            XCTAssertEqual(card.frame.height, height, accuracy: 0.5)
            XCTAssertEqual(app.otherElements["calendar.figures"].frame.minY, figuresY, accuracy: 0.5)
            assertNoDaySummary(app)
        }
        chooseCalendarMonth(app, year: "2026", month: "10")
        assertNoDaySummary(app)
        let header = app.descendants(matching: .any)["calendar.weekdays"]
        XCTAssertEqual(header.label, expectedWeekdayHeader())
        XCTAssertEqual(header.value as? String, expectedGridStart("2026-10-01"))
        let plain = XCTAttachment(screenshot: app.screenshot())
        plain.name = "calendar-no-summary"
        plain.lifetime = .keepAlways
        add(plain)
        // The first row must remain tappable above the day sheet, including on short phones.
        // Tapping the open day again keeps its sheet open: dismissal is a swipe down
        // or the sheet's own Done button, not a second tap on the date.
        let first = app.buttons["calendar.day.2026-10-01"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let cardBeforeSheet = card.frame
        let dayBeforeSheet = first.frame
        let spot = first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        spot.tap()
        let opened = app.navigationBars["10月1日 周四"]
        XCTAssertTrue(opened.waitForExistence(timeout: 5))
        let dayAfterSheet = first.frame
        let geometry = XCTAttachment(string: "screen=\(app.frame); cardBefore=\(cardBeforeSheet); cardAfter=\(card.frame); dayBefore=\(dayBeforeSheet); dayAfter=\(dayAfterSheet); sheetNavigation=\(opened.frame)")
        geometry.name = "calendar-day-sheet-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let openedShot = XCTAttachment(screenshot: app.screenshot())
        openedShot.name = "calendar-first-row-with-sheet"
        openedShot.lifetime = .keepAlways
        add(openedShot)
        XCTAssertEqual(card.frame.height, cardBeforeSheet.height, accuracy: 0.5)
        XCTAssertEqual(card.frame.minY, cardBeforeSheet.minY, accuracy: 0.5)
        XCTAssertEqual(dayAfterSheet.midY, dayBeforeSheet.midY, accuracy: 0.5)
        XCTAssertTrue(first.isHittable, "The open date remains tappable above its sheet")
        spot.tap()
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "Tapping the open day again keeps its sheet open")
        XCTAssertEqual(first.value as? String, "已选中")
        tapPoint(app.buttons["完成"], timeout: 5)
        XCTAssertTrue(opened.waitForNonExistence(timeout: 5), "The sheet's Done button dismisses it")
        XCTAssertNotEqual(first.value as? String, "已选中")
        let coffee = app.buttons["calendar.day.2026-10-17"]
        for _ in 0..<4 where !(coffee.exists && coffee.isHittable) { app.swipeUp() }
        tapPoint(coffee, timeout: 5)
        XCTAssertTrue(app.navigationBars["10月17日 周六"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "12.00")).firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "calendar-day-sheet"
        shot.lifetime = .keepAlways
        add(shot)
        tapPoint(app.buttons["完成"], timeout: 5)
        let advance = app.buttons["calendar.day.2026-10-16"]
        for _ in 0..<4 where !(advance.exists && advance.isHittable) { app.swipeUp() }
        tapPoint(advance, timeout: 5)
        XCTAssertTrue(app.navigationBars["10月16日 周五"].waitForExistence(timeout: 5))
    }

    /// An open sheet stays open through the lock: going to the background locks the app, the lock screen covers
    /// the sheet, and unlocking shows the same sheet again. Locking used to close it.
    func testLockingKeepsTheOpenSheet() {
        let app = launchTab("journal", env: ["LEDGER_CALENDAR": "1", "LEDGER_LOCK": "1"])
        let unlock = app.buttons["unlock"]
        XCTAssertTrue(unlock.waitForExistence(timeout: 20))
        unlock.tap()
        XCTAssertTrue(unlock.waitForNonExistence(timeout: 5))
        _ = openGlassCalendar(app)
        chooseCalendarMonth(app, year: "2026", month: "10")
        tapPoint(app.buttons["calendar.day.2026-10-01"], timeout: 5)
        let sheet = app.navigationBars["10月1日 周四"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(unlock.waitForExistence(timeout: 10))
        XCTAssertFalse(sheet.exists && sheet.isHittable, "the lock screen covers the sheet")
        let locked = XCTAttachment(screenshot: app.screenshot())
        locked.name = "locked-over-sheet"
        locked.lifetime = .keepAlways
        add(locked)
        unlock.tap()
        XCTAssertTrue(unlock.waitForNonExistence(timeout: 5))
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "the same sheet is back after unlocking")
        XCTAssertTrue(sheet.isHittable)
    }

    /// With a day's sheet open at half height, tapping another date above it switches the sheet to that day
    /// at the same height: it used to come back at full screen, covering the calendar.
    func testSwitchingDaysKeepsTheSheetAtHalfHeight() {
        let app = launchTab("journal", env: ["LEDGER_CALENDAR": "1"])
        _ = openGlassCalendar(app)
        chooseCalendarMonth(app, year: "2026", month: "10")
        let first = app.buttons["calendar.day.2026-10-01"]
        tapPoint(first, timeout: 5)
        let opened = app.navigationBars["10月1日 周四"]
        XCTAssertTrue(opened.waitForExistence(timeout: 5))
        let top = opened.frame.minY
        XCTAssertGreaterThan(top, app.frame.height * 0.55, "the day sheet starts low on every phone, not only short ones")
        let second = app.buttons["calendar.day.2026-10-02"]
        XCTAssertTrue(second.isHittable, "the first row stays above the half sheet")
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let switched = app.navigationBars["10月2日 周五"]
        XCTAssertTrue(switched.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "calendar-switched-day-sheet"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertEqual(switched.frame.minY, top, accuracy: 1, "the sheet keeps its height when the day changes")
        XCTAssertTrue(second.isHittable, "the calendar stays visible above the sheet")
    }

    private func assertNoDaySummary(_ app: XCUIApplication) {
        XCTAssertFalse(app.staticTexts["本月暂无记录"].exists)
        XCTAssertFalse(app.staticTexts["查看当天明细"].exists)
        XCTAssertFalse(app.buttons["calendar.openDay"].exists)
        XCTAssertFalse(app.otherElements["calendar.summary"].exists)
    }

    /// Weekday names in the app's Chinese, ordered from the phone's first day of the week.
    private func expectedWeekdayHeader() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = Calendar.current.firstWeekday
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday
        var names: [String] = []
        names.reserveCapacity(7)
        for offset in 0..<7 {
            names.append(symbols[(first - 1 + offset) % 7])
        }
        return names.joined(separator: " ")
    }

    /// The grid's first cell, including a day from the previous month. Same count as 本周.
    private func expectedGridStart(_ day: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        calendar.firstWeekday = Calendar.current.firstWeekday
        let parts = day.split(separator: "-").compactMap { Int($0) }
        let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
        let weekday = calendar.component(.weekday, from: start)
        let back = (weekday - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -back, to: start)!
        let components = calendar.dateComponents([.year, .month, .day], from: first)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    func testGlassSubscriptionCalendarRangeAndSelection() {
        checkGlassSubscriptions(textSize: nil)
    }

    func testGlassSubscriptionCalendarRangeAndSelectionAtLargeText() {
        checkGlassSubscriptions(textSize: "UICTContentSizeCategoryXXXL")
    }

    private func checkGlassSubscriptions(textSize: String?) {
        let app = launchTab("reports", textSize: textSize)
        let subs = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "订阅管理")).firstMatch
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "年度回顾")).firstMatch.waitForExistence(timeout: 20))
        for _ in 0..<8 { if subs.exists && subs.isHittable { break }; app.swipeUp() }
        tapPoint(subs, timeout: 5)
        tapPoint(app.buttons["订阅日历"], timeout: 5)
        XCTAssertTrue(app.otherElements["calendar.glass"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["点越大，当日金额越大"].exists)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        let day = app.buttons["calendar.day." + today]
        for cell in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'calendar.day.'")).allElementsBoundByIndex {
            if String(cell.identifier.suffix(10)) < today { XCTAssertFalse(cell.isEnabled) }
        }
        day.tap()
        XCTAssertEqual(day.value as? String, "已选中")
        let allMonth = app.buttons["显示整月"]
        for _ in 0..<5 { if allMonth.exists && allMonth.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(allMonth.waitForExistence(timeout: 5))
        allMonth.tap()
        XCTAssertNotEqual(day.value as? String, "已选中")
        let last = formatter.string(from: Calendar.current.date(byAdding: .day, value: 62, to: Date())!)
        // 62 days ahead is two months on, or three from the 30th/31st (10-31 → 01-01): step to the month it falls in
        let months = { (d: String) in Int(d.prefix(4))! * 12 + Int(d.dropFirst(5).prefix(2))! }
        for _ in 0..<(months(last) - months(today)) { app.buttons["下个月"].tap() }
        for cell in app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'calendar.day.'")).allElementsBoundByIndex {
            if String(cell.identifier.suffix(10)) > last { XCTAssertFalse(cell.isEnabled) }
        }
        XCTAssertFalse(app.buttons["下个月"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "subscription-range"; shot.lifetime = .keepAlways; add(shot)
    }

    func testGlassCalendarAccessibilityTextRemainsReadable() {
        let app = launchTab("journal", accessibility: true, env: ["LEDGER_CALENDAR": "1"])
        _ = openGlassCalendar(app)
        let top = XCTAttachment(screenshot: app.screenshot()); top.name = "calendar-ax3-top"; top.lifetime = .keepAlways; add(top)
        app.swipeUp()
        let bottom = XCTAttachment(screenshot: app.screenshot()); bottom.name = "calendar-ax3-bottom"; bottom.lifetime = .keepAlways; add(bottom)
        let grid = app.otherElements["calendar.grid"].frame
        let first = app.buttons["calendar.day.2026-10-04"].frame
        let last = app.buttons["calendar.day.2026-10-10"].frame
        XCTAssertGreaterThanOrEqual(first.minX, grid.minX - 0.5)
        XCTAssertLessThanOrEqual(last.maxX, grid.maxX + 0.5)
        XCTAssertEqual(first.width, grid.width / 7, accuracy: 0.5)
        let selected = app.buttons["calendar.day.2026-10-24"]
        XCTAssertTrue(selected.exists)
        selected.tap()
        XCTAssertTrue(app.navigationBars["10月24日 周六"].waitForExistence(timeout: 5))
        let selection = XCTAttachment(screenshot: app.screenshot()); selection.name = "calendar-ax3-day"; selection.lifetime = .keepAlways; add(selection)
    }

    func testCalendarUsesFullRowWidthWithoutHint() {
        let app = launchTab("journal", env: ["LEDGER_CALENDAR": "1"])
        let calendar = openGlassCalendar(app)
        let grid = app.otherElements["calendar.grid"]
        XCTAssertEqual(grid.frame.minX, calendar.frame.minX, accuracy: 0.5)
        XCTAssertEqual(grid.frame.maxX, calendar.frame.maxX, accuracy: 0.5)
        XCTAssertFalse(app.staticTexts["点越大，当日金额越大"].exists)
        XCTAssertFalse(app.buttons["calendar.openDay"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["calendar.weekdays"].label, expectedWeekdayHeader())
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "calendar-without-inner-card"; shot.lifetime = .keepAlways; add(shot)
    }

    private func launchTab(_ tab: String, accessibility: Bool = false, textSize: String? = nil, env: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": tab, "LEDGER_LANG": "zh"].merging(env) { $1 }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
            + (accessibility ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
            + (textSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        app.launch()
        return app
    }

    /// 月 and 年 on the overview's card: the year had no average line, so the card was a line shorter and
    /// everything under it jumped when switching
    func testOverviewCardKeepsItsHeightBetweenMonthAndYear() {
        let app = launchTab("overview")
        let hero = app.otherElements["overview.hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        // the period is remembered: start from 月
        app.buttons["月"].tap()
        XCTAssertTrue(hero.staticTexts["本年支出"].waitForNonExistence(timeout: 5))
        let income = hero.staticTexts["收入"]
        XCTAssertTrue(income.exists)
        // the arrows are read for what they do (they were read as 返回 / 前进)
        XCTAssertTrue(app.buttons["上个月"].exists && app.buttons["下个月"].exists)
        let before = income.frame.minY
        app.buttons["年"].tap()
        XCTAssertTrue(hero.staticTexts["本年支出"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["上一年"].exists && app.buttons["下一年"].exists)
        XCTAssertEqual(income.frame.minY, before, accuracy: 0.5)
    }

    /// 全部 and 收支 on the accounts page: the 收支 card was shorter, so the switch under it moved away from the finger
    func testAccountsCardKeepsItsHeightBetweenTabs() {
        // one currency: a figure each; the card keeps the taller tab's height
        for extra in [nil, heightExtra] {
            let app = launchTab("accounts", env: extra.map { ["LEDGER_EXTRA": $0] } ?? [:])
            let flows = app.buttons["收支"]
            XCTAssertTrue(flows.waitForExistence(timeout: 20))
            // the tab is remembered: start from 全部
            app.buttons["全部"].tap()
            // a second currency (HKD without a price): both tabs are a table, a row per currency
            let several = extra != nil
            XCTAssertTrue(app.staticTexts[several ? "净额" : "资产负债率"].waitForExistence(timeout: 5))
            // the other tab's card keeps its place unseen: VoiceOver does not read it
            XCTAssertFalse(app.staticTexts[several ? "结余" : "储蓄率"].exists)
            let before = flows.frame.minY
            flows.tap()
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", several ? "年收支" : "年结余")).firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(flows.frame.minY, before, accuracy: 0.5)
            app.terminate()
        }
    }

    /// Several currencies as booked: the accounts card, the balance sheet and the income statement list each currency
    /// once, a row with its figures (they listed every currency under each figure, three times over)
    func testSeveralCurrenciesAreOneRowEach() {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for (tab, report, extra) in [("accounts", nil, "fx-extra.bean"), ("reports", "balance", "fx-extra.bean"), ("reports", "income", "flow-extra.bean")] {
            var env = ["LEDGER_EXTRA": fixtures.appendingPathComponent(extra).path, "LEDGER_CURRENCY_MODE": "units"]
            if let report { env["LEDGER_REPORT"] = report }
            let app = launchTab(tab, env: env)
            if tab == "accounts" {
                XCTAssertTrue(app.buttons["全部"].waitForExistence(timeout: 20))
                app.buttons["全部"].tap()
            }
            let table = app.otherElements["currency.table"].firstMatch
            XCTAssertTrue(table.waitForExistence(timeout: 20), report ?? tab)
            XCTAssertEqual(table.staticTexts.matching(identifier: "HKD").count, 1, report ?? tab)
            XCTAssertTrue(table.staticTexts["CNY"].exists, report ?? tab)
            app.terminate()
        }
    }

    /// Under the bar both tabs of the card have a line: 净资产 against last month, 收支 by the month (收支 had
    /// nothing there, a blank under its bar when 净资产 had its accounts-left-out line); 收支's opens the year's review
    func testBothTabsOfTheAccountsCardHaveALineUnderTheBar() {
        let app = launchTab("accounts")
        let flows = app.buttons["收支"]
        XCTAssertTrue(flows.waitForExistence(timeout: 20))
        app.buttons["全部"].tap()
        let nw = app.buttons["accounts.nwLine"]
        XCTAssertTrue(nw.waitForExistence(timeout: 5))
        XCTAssertTrue(nw.label.hasPrefix("较上月末"))
        let at = nw.frame.minY
        flows.tap()
        let line = app.buttons["accounts.flowLine"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.label.hasPrefix("月均支出"))
        XCTAssertEqual(line.frame.minY, at, accuracy: 0.5)
        line.tap()
        XCTAssertTrue(app.navigationBars["年度回顾"].waitForExistence(timeout: 5))
    }

    /// At the largest text size the card's figures are not shrunk to fit one row: they stack, one a line, and the
    /// card grows
    func testOverviewFiguresStackAtAccessibilityTextSize() {
        let app = launchTab("overview", accessibility: true)
        let hero = app.otherElements["overview.hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        let income = hero.staticTexts["收入"], net = hero.staticTexts["净资产"]
        XCTAssertTrue(income.exists && net.exists)
        XCTAssertGreaterThan(net.frame.minY, income.frame.maxY)
        // the headline amount grows with the text size too (it stayed 40 pt: about 48 pt tall at every size)
        XCTAssertGreaterThan(hero.staticTexts["overview.spent"].frame.height, 64)
    }

    /// The account picker keeps the chosen account and the groups under the search: scrolling the list or searching
    /// does not take them away, and a group picked while searching clears the search and goes to that group
    func testAccountPickerKeepsGroupsInSight() {
        let app = launch()
        openFull(app)
        let funding = app.descendants(matching: .any)["field.付款账户"]
        // iOS can expose this account control as a PopUpButton; locate its stable identifier,
        // while retaining the same hittability and selection assertions as for a plain Button.
        for _ in 0..<5 { if funding.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(funding.isHittable); funding.tap()
        let search = app.textFields["account.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["account.chosen"].exists)
        // the first group: the row scrolls sideways, so its chip may show only in part
        let chip = app.buttons["account.group.Assets:Bank"], row = app.buttons["account.Assets:Bank:CGB"]
        XCTAssertTrue(chip.exists)
        // a picker opens at half the screen; dragged up, it fills it
        let height = app.windows.firstMatch.frame.height
        XCTAssertGreaterThan(chip.frame.minY, height / 3)
        // dragged up by its grabber (a swipe from the middle of the screen can start on the dimmed page above it)
        let grabber = app.buttons["表单控制柄"].firstMatch
        XCTAssertTrue(grabber.exists)
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        XCTAssertLessThan(chip.frame.minY, height / 3)
        let top = chip.frame.minY
        app.swipeUp()
        XCTAssertEqual(chip.frame.minY, top, accuracy: 0.5)
        tapPoint(search, timeout: 5)
        // One tap must retain focus through the medium → large sheet transition; do not tap again.
        assertCanType(app, into: search)
        search.typeText("Cash")
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertEqual(chip.frame.minY, top, accuracy: 1)
        chip.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String ?? "", "搜索账户")
        XCTAssertTrue(row.isHittable)
    }

    /// Every list's search sits under the title like the journal's and stays there while scrolling: the guide,
    /// accounts, payees and others had it at the bottom of the screen (the system's default on iOS 26)
    func testAListsSearchStaysInSightWhileScrolling() {
        let app = launchTab("settings")
        let guide = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "使用指南")).firstMatch
        for _ in 0..<6 { if guide.exists && guide.isHittable { break }; app.swipeUp() }
        guide.tap()
        let search = app.searchFields["搜索指南和问题"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        for _ in 0..<3 { app.swipeUp() }
        XCTAssertTrue(search.isHittable)
        XCTAssertLessThan(search.frame.minY, app.windows.firstMatch.frame.height / 3)
    }

    /// The month arrows are touched over 44 × 44 while the bar keeps its height: a finger beside the chevron
    /// still turns the month
    func testMonthArrowsHaveAFullSizeTapArea() {
        let app = launchTab("overview")
        let period = app.staticTexts["overview.period"]
        XCTAssertTrue(period.waitForExistence(timeout: 20))
        let first = period.label
        let back = app.buttons["上个月"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(back.frame.width, 44)
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)
        // near the edge of the touch area, away from the chevron itself
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", first), object: period)], timeout: 5), .completed)
    }

    /// 关于 shows the build with the version, so a preview and the dev build of one version are told apart
    func testAboutShowsTheBuildNumber() {
        let app = launchTab("settings")
        let about = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "关于 Ledger X")).firstMatch
        for _ in 0..<6 { if about.exists && about.isHittable { break }; app.swipeUp() }
        about.tap()
        let version = app.staticTexts["about.version"]
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue(version.label.range(of: #"^版本 \d+\.\d+\.\d+（构建 \d+(\.\d+)?）$"#, options: .regularExpression) != nil, version.label)
    }

    /// The month bars of 概览 and 报表 swipe like their arrows: to the right goes back a month, to the left on again
    func testAMonthBarSwipesToTheNextMonth() {
        var app = launchTab("overview")
        let period = app.staticTexts["overview.period"]
        XCTAssertTrue(period.waitForExistence(timeout: 20))
        let first = period.label
        period.swipeRight()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", first), object: period)], timeout: 5), .completed)
        period.swipeLeft()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", first), object: period)], timeout: 5), .completed)

        app.terminate()
        app = launchTab("reports")
        let bar = app.descendants(matching: .any)["reports.monthbar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        let now = app.buttons["本月"]
        if now.exists { now.tap() }
        XCTAssertTrue(now.waitForNonExistence(timeout: 5))
        bar.swipeRight()
        XCTAssertTrue(now.waitForExistence(timeout: 5))
        bar.swipeLeft()
        XCTAssertTrue(now.waitForNonExistence(timeout: 5))
    }

    /// 月 / 年 on the overview slide like any segmented control: the month swipe of the row it sits in took the
    /// drag, so only a tap switched it
    func testTheOverviewPeriodPickerSlides() {
        let app = launchTab("overview")
        let picker = app.segmentedControls.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        let month = picker.buttons["月"], year = picker.buttons["年"]
        if !month.isSelected { month.tap() }
        XCTAssertTrue(month.isSelected)
        month.press(forDuration: 0.2, thenDragTo: year)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: year)], timeout: 5), .completed)
    }

    /// Every month switcher is ‹ title ›, the title in the middle and, away from now, the way back beside it:
    /// its coming and going leaves the title where it is, and it brings the bar back to now (the overview's way back
    /// is on its card: testTheOverviewCardTakesYouBackToNow; the calendars are the system's)
    func testMonthSwitchersShowTheWayBackBesideTheTitle() {
        func check(_ app: XCUIApplication, bar: XCUIElement, title: XCUIElement, back: XCUIElement, previous: String) {
            XCTAssertTrue(bar.waitForExistence(timeout: 20))
            if back.exists { back.tap() }
            XCTAssertTrue(back.waitForNonExistence(timeout: 5))
            let now = title.label, x = title.frame.midX
            XCTAssertEqual(x, bar.frame.midX, accuracy: 2)
            let arrow = bar.buttons[previous], arrowX = arrow.frame.minX
            arrow.tap()
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(back.frame.minX, title.frame.maxX)
            XCTAssertGreaterThan(title.frame.minX, arrow.frame.maxX)
            XCTAssertEqual(arrow.frame.minX, arrowX, accuracy: 0.5)
            XCTAssertEqual(title.frame.midX, x, accuracy: 2)
            back.tap()
            XCTAssertTrue(back.waitForNonExistence(timeout: 5))
            XCTAssertEqual(title.label, now)
        }
        let app = launchTab("reports")
        let bar = app.descendants(matching: .any)["reports.monthbar"].firstMatch
        check(app, bar: bar, title: bar.staticTexts["period.title"], back: bar.buttons["本月"], previous: "上个月")
    }

    /// At larger text sizes too, the month's title stays where it was from one month to the next: the bar chose its
    /// layout by the month's own name, so a wider one (2026年10月) could get another than a narrower one (2026年9月),
    /// and the title jumped
    func testTheMonthTitleStaysPutAtLargerTextSizes() {
        for size in ["UICTContentSizeCategoryXL", "UICTContentSizeCategoryXXL", "UICTContentSizeCategoryXXXL", "UICTContentSizeCategoryAccessibilityM"] {
            let overview = launchTab("overview", textSize: size)
            overview.buttons["月"].firstMatch.tap()
            let bar = overview.descendants(matching: .any)["overview.monthbar"].firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 20))
            // no way back on the overview's bar: the title stays put from one month to the next
            let heading = overview.staticTexts["overview.period"], name = heading.label
            let at = heading.frame.midX
            bar.buttons["上个月"].tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", name), object: heading)], timeout: 5), .completed)
            XCTAssertEqual(heading.frame.midX, at, accuracy: 1, "overview " + size)
            overview.terminate()
        }
    }

    /// The overview's ‹ month › keep together at the trailing end beside 月 / 年, as before the bars were made one;
    /// spread across the row, the arrows sat far from the month, one against 月 / 年
    func testTheOverviewMonthBarKeepsItsArrowsBesideTheMonth() {
        for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryXXXL"] {
            let app = launchTab("overview", textSize: size)
            app.buttons["月"].firstMatch.tap()
            let bar = app.descendants(matching: .any)["overview.monthbar"].firstMatch
            XCTAssertTrue(bar.waitForExistence(timeout: 20))
            let title = app.staticTexts["overview.period"], previous = bar.buttons["上个月"], next = bar.buttons["下个月"]
            let segment = app.segmentedControls.firstMatch.frame
            // an arrow's button reaches 10 points past the arrow on each side (its 44 × 44 tap area, PeriodBar.arrow),
            // so measure the arrow as drawn
            let drawn = { (arrow: XCUIElement) in arrow.frame.insetBy(dx: 10, dy: 0) }
            XCTAssertLessThan(title.frame.minX - drawn(previous).maxX, 24, size)
            XCTAssertLessThan(drawn(next).minX - title.frame.maxX, 24, size)
            XCTAssertGreaterThan(drawn(previous).minX - segment.maxX, 24, size)
            XCTAssertEqual(drawn(next).maxX, bar.frame.maxX, accuracy: 1, size)
            // and nothing moves from one month to the next
            let at = (previous.frame.minX, title.frame.midX, next.frame.minX), name = title.label
            previous.tap()
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", name), object: title)], timeout: 5), .completed)
            XCTAssertEqual(previous.frame.minX, at.0, accuracy: 0.5, size)
            XCTAssertEqual(title.frame.midX, at.1, accuracy: 1, size)
            XCTAssertEqual(next.frame.minX, at.2, accuracy: 0.5, size)
            app.terminate()
        }
    }

    /// The overview card's way back keeps its room when it is not shown: it is taller than the heading beside it, and
    /// picking a month on the chart made the card taller
    func testTheOverviewCardKeepsItsHeightWithTheWayBack() {
        let app = launchTab("overview")
        app.buttons["月"].firstMatch.tap()
        let hero = app.otherElements["overview.hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        let height = hero.frame.height
        let chart = app.otherElements["overview.trend"]
        scrollIntoView(chart, in: app)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        let back = hero.buttons["回到本月"]
        for _ in 0..<4 where !back.isHittable { app.swipeDown() }
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertEqual(hero.frame.height, height, accuracy: 0.5)
    }

    /// The overview's way back to now is on its card, not on the month bar: it comes when the bar is stepped away
    /// from now (it came only for a month picked on the chart, and the bar had a 本月 / 今年 of its own) and brings
    /// the page back to the current month or year
    func testTheOverviewCardTakesYouBackToNow() {
        let app = launchTab("overview")
        app.buttons["月"].firstMatch.tap()
        let bar = app.descendants(matching: .any)["overview.monthbar"].firstMatch
        let hero = app.otherElements["overview.hero"], title = app.staticTexts["overview.period"]
        XCTAssertTrue(bar.waitForExistence(timeout: 20))
        let now = title.label, height = hero.frame.height
        XCTAssertFalse(hero.buttons["回到本月"].exists)
        bar.buttons["上个月"].tap()
        XCTAssertFalse(bar.buttons["本月"].exists)
        let back = hero.buttons["回到本月"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertEqual(hero.frame.height, height, accuracy: 0.5)
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 5))
        XCTAssertEqual(title.label, now)

        app.buttons["年"].firstMatch.tap()
        let year = title.label
        bar.buttons["上一年"].tap()
        XCTAssertFalse(bar.buttons["今年"].exists)
        let thisYear = hero.buttons["回到今年"]
        XCTAssertTrue(thisYear.waitForExistence(timeout: 5))
        thisYear.tap()
        XCTAssertTrue(thisYear.waitForNonExistence(timeout: 5))
        XCTAssertEqual(title.label, year)
    }

    /// Under the overview's trend chart there is always one line, so the card keeps its height through 月 / 年 and
    /// 支出 / 收支: the year without a picked month had nothing under 支出 and a legend under 收支
    func testTheTrendChartAlwaysHasOneLineUnderIt() {
        let app = launchTab("overview")
        app.buttons["月"].firstMatch.tap()
        let chart = app.otherElements["overview.trend"]
        XCTAssertTrue(chart.waitForExistence(timeout: 20))
        scrollIntoView(chart, in: app)
        let line = app.staticTexts["overview.trendLine"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        // measured from the chart's top, as the cards above it change with 月 / 年
        let bottom = line.frame.maxY - chart.frame.minY
        for (period, trend) in [("月", "收支"), ("年", "收支"), ("年", "支出"), ("月", "支出")] {
            let tab = app.buttons[period].firstMatch
            for _ in 0..<4 where !tab.isHittable { app.swipeDown() }
            tab.tap()
            scrollIntoView(chart, in: app)
            app.buttons[trend].firstMatch.tap()
            XCTAssertTrue(line.waitForExistence(timeout: 5), period + trend)
            XCTAssertEqual(line.frame.maxY - chart.frame.minY, bottom, accuracy: 0.5, period + trend)
        }
        // 收支: the figures say which is which (the legend was a line of its own)
        app.buttons["收支"].firstMatch.tap()
        XCTAssertTrue(line.label.contains("收入") && line.label.contains("支出"))
    }

    /// The net worth chart by currency held lists the latest month's parts under it until a month is picked, so
    /// picking one no longer makes the card taller
    func testTheNetWorthPartsAreThereBeforeAMonthIsPicked() {
        let extra = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/worth-extra.bean").path
        let app = launchTab("reports", env: ["LEDGER_EXTRA": extra, "LEDGER_REPORT": "balance"])
        let parts = app.otherElements["networth.parts"]
        XCTAssertTrue(parts.waitForExistence(timeout: 20))
        scrollIntoView(parts, in: app)
        let range = app.buttons["1 年"].firstMatch
        XCTAssertTrue(range.exists)
        let gap = range.frame.minY - parts.frame.minY
        XCTAssertTrue(parts.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "HKD")).firstMatch.exists)
        let chart = parts.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -100))
        chart.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "月末")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(parts.exists)
        XCTAssertEqual(range.frame.minY - parts.frame.minY, gap, accuracy: 0.5)
    }

    /// One chart per currency (amounts kept in their own currencies): picking a month adds its line under or above
    /// each chart in a place kept for it, so the charts are as tall before as after
    func testChartsPerCurrencyKeepTheirHeightWhenAMonthIsPicked() {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for (report, extra, id) in [("income", "flow-extra.bean", "flow.charts"), ("balance", "worth-extra.bean", "networth.charts")] {
            let app = launchTab("reports", env: ["LEDGER_EXTRA": fixtures.appendingPathComponent(extra).path, "LEDGER_REPORT": report,
                                                 "LEDGER_CURRENCY_MODE": "units"])
            let charts = app.otherElements[id]
            XCTAssertTrue(charts.waitForExistence(timeout: 20), report)
            scrollIntoView(charts, in: app)
            let height = charts.frame.height
            // inside the first chart: under the currency's title (and the legend of 月度收支)
            charts.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0)).withOffset(CGVector(dx: 0, dy: 100)).tap()
            let line = report == "income"
                ? app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "收入 ")).firstMatch
                : app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "月末")).firstMatch
            XCTAssertTrue(line.waitForExistence(timeout: 5), report)
            XCTAssertEqual(charts.frame.height, height, accuracy: 0.5, report)
            app.terminate()
        }
    }

    /// The trial balance's 币种 · 借方合计 · 贷方合计 span the card in three equal centred columns (they hugged the left)
    func testTheTrialBalanceColumnsSpanTheCard() {
        let app = launchTab("reports", env: ["LEDGER_REPORT": "trial"])
        let debit = app.staticTexts["借方合计"].firstMatch
        XCTAssertTrue(debit.waitForExistence(timeout: 20))
        let currency = app.staticTexts["币种"].firstMatch, credit = app.staticTexts["贷方合计"].firstMatch
        let mid = app.windows.firstMatch.frame.midX
        XCTAssertEqual(debit.frame.midX, mid, accuracy: 2)
        XCTAssertEqual(currency.frame.midX + credit.frame.midX, 2 * mid, accuracy: 2)
        XCTAssertGreaterThan(debit.frame.midX - currency.frame.midX, app.windows.firstMatch.frame.width / 4)
        // the figures sit under their headings
        let cny = app.staticTexts["CNY"].firstMatch
        XCTAssertEqual(cny.frame.midX, currency.frame.midX, accuracy: 2)
    }

    /// A gesture's hints go once it has been used: the charts' after a tap on one, 点按查看交易 / 点按扇区展开 after a
    /// category or payee is opened, the 左滑 half of a footer after a row has been swiped, 长按 after a long press; and they stay gone
    func testGestureHintsGoOnceTheGestureIsUsed() {
        func text(_ app: XCUIApplication, _ s: String) -> XCUIElement {
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", s)).firstMatch
        }
        var app = launchTab("overview", env: ["LEDGER_UNLEARN": "1"])
        app.buttons["月"].firstMatch.tap()
        let chart = app.otherElements["overview.trend"]
        XCTAssertTrue(chart.waitForExistence(timeout: 20))
        scrollIntoView(chart, in: app)
        let chartHint = text(app, "点按或左右滑动查看月份")
        XCTAssertTrue(chartHint.exists)
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(chartHint.waitForNonExistence(timeout: 5))
        // the payees' list: a row opened shows its transactions
        let payee = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Coffee")).firstMatch
        for _ in 0..<6 where !(payee.exists && payee.isHittable) { app.swipeUp() }
        XCTAssertTrue(text(app, "点按查看交易").exists)
        payee.tap()
        XCTAssertTrue(text(app, "点按查看交易").waitForNonExistence(timeout: 5))
        app.terminate()

        // learned stays learned
        app = launchTab("overview")
        app.buttons["月"].firstMatch.tap()
        XCTAssertTrue(chart.waitForExistence(timeout: 20))
        scrollIntoView(chart, in: app)
        XCTAssertFalse(text(app, "点按或左右滑动查看月份").exists)
        app.terminate()

        app = launchTab("overview", env: ["LEDGER_UNLEARN": "1", "LEDGER_LINK_ISSUES": "1"])
        let footer = text(app, "链接检查")
        XCTAssertTrue(footer.waitForExistence(timeout: 20))
        XCTAssertTrue(footer.label.contains("左滑可忽略"))
        app.terminate()
        // a row swiped anywhere (here a change waiting to sync; nothing removed) ...
        app = launchTab("overview", env: ["LEDGER_SYNC": "1", "LEDGER_HELD": "1"])
        let pending = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "sync.pending", "Held cafe")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 20))
        pending.swipeLeft()
        XCTAssertTrue(app.buttons["trash"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        // ... and the 左滑 half is gone from every footer
        app = launchTab("overview", env: ["LEDGER_LINK_ISSUES": "1"])
        XCTAssertTrue(footer.waitForExistence(timeout: 20))
        XCTAssertFalse(footer.label.contains("左滑"))
        app.terminate()

        app = launchTab("overview", env: ["LEDGER_UNLEARN": "1"])
        let hold = text(app, "点按打开或关掉")
        tapPoint(app.buttons["币种与换算"].firstMatch, timeout: 20)
        XCTAssertTrue(app.staticTexts["币种"].firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<3 where !hold.exists { app.staticTexts["币种"].firstMatch.swipeUp() }
        XCTAssertTrue(hold.waitForExistence(timeout: 5))
        XCTAssertTrue(hold.label.contains("长按"))
        app.staticTexts["CNY"].firstMatch.press(forDuration: 1)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (label CONTAINS %@)", "长按"), object: hold)], timeout: 5), .completed)
    }

    /// While the ledger loads, the tabs are there and 概览 and 明细 show their shape in grey, rather than a page
    /// with a spinner alone
    func testPagesShowTheirShapeWhileTheLedgerLoads() {
        var app = launchTab("overview", env: ["LEDGER_LOADING": "1"])
        let skeleton = app.descendants(matching: .any)["page.skeleton"].firstMatch
        XCTAssertTrue(skeleton.waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["明细"].exists)
        app.terminate()
        app = launchTab("journal", env: ["LEDGER_LOADING": "1"])
        XCTAssertTrue(app.descendants(matching: .any)["page.skeleton"].firstMatch.waitForExistence(timeout: 20))
    }

    private var heightExtra: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/height-extra.bean").path
    }

    /// The calendar's 支出 · 收入 · 结余 sit centred in equal columns: a month's wide income no longer pushes 收入 aside
    func testCalendarFiguresSitInEqualColumns() {
        let app = launchTab("journal", env: ["LEDGER_EXTRA": heightExtra, "LEDGER_CALENDAR": "1", "LEDGER_GLASS_CALENDAR": "0"])
        let calendar = app.descendants(matching: .any)["calendar.month"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 20))
        let figures = app.otherElements["calendar.figures"]
        let spent = figures.staticTexts["支出"], income = figures.staticTexts["收入"], net = figures.staticTexts["结余"]
        XCTAssertTrue(spent.exists && income.exists && net.exists)
        // each column centred: 收入 in the middle of the row, the three centres evenly apart
        XCTAssertEqual(income.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1)
        XCTAssertEqual(income.frame.midX - spent.frame.midX, net.frame.midX - income.frame.midX, accuracy: 1)
    }

    /// The overview card's 收入 · 结余 · 净资产 sit centred in equal columns, like the calendar's: they were set at
    /// each column's left edge, so the row looked pushed to the left
    func testOverviewFiguresSitCentredInEqualColumns() {
        let app = launchTab("overview")
        let hero = app.otherElements["overview.hero"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        let income = hero.staticTexts["收入"], worth = hero.staticTexts["净资产"]
        let net = hero.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "结余")).firstMatch
        XCTAssertTrue(income.exists && net.exists && worth.exists)
        XCTAssertEqual(net.frame.midX, hero.frame.midX, accuracy: 1)
        XCTAssertEqual(net.frame.midX - income.frame.midX, worth.frame.midX - net.frame.midX, accuracy: 1)
    }

    /// A long condition is cut short on its own line; it never runs under 清除 (or 回到刚才的筛选)
    func testLongFilterConditionDoesNotRunUnderItsActions() {
        let long = "一段很长很长的搜索文字，用来检查筛选条件放不下时的排布"
        let app = launchTab("journal", env: ["LEDGER_QUERY": long])
        let clear = app.buttons["清除"]
        XCTAssertTrue(clear.waitForExistence(timeout: 20))
        let chip = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "一段很长")).firstMatch
        XCTAssertTrue(chip.exists)
        XCTAssertFalse(chip.frame.intersects(clear.frame))
        XCTAssertLessThanOrEqual(chip.frame.maxX, app.windows.firstMatch.frame.maxX)
    }

    /// A change not pushed yet, swiped away on 账本同步: asked first, since nothing can bring it back
    func testRemovingAPendingChangeAsksFirst() {
        let app = launchTab("overview", env: ["LEDGER_SYNC": "1", "LEDGER_HELD": "1"])
        // the change LEDGER_HELD kept (other tests' saves may be waiting in the queue too)
        let row = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "sync.pending", "Held cafe")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let count = app.buttons.matching(identifier: "sync.pending").count
        row.swipeLeft()
        tapPoint(app.buttons["trash"].firstMatch, timeout: 5)
        XCTAssertTrue(app.staticTexts["移除这项改动？"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "sync.pending").count, count)
        // confirmed, it goes (and leaves the test ledger as it was)
        app.sheets.buttons["移除"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    /// A sync queue that doesn't read back is set aside, not written over: 账本同步 lists it, to share or discard
    func testAnUnreadableQueueIsListedOnTheSyncPage() {
        let app = launchTab("overview", env: ["LEDGER_SYNC": "1", "LEDGER_UNREADABLE": "1"])
        let row = app.descendants(matching: .any)["sync.unreadable.pending"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["分享原文件"].firstMatch.exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "账本同步-读不出来的记录"
        shot.lifetime = .keepAlways
        add(shot)
        // discarded after asking (and the test ledger left as it was)
        app.buttons["放弃"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["放弃这份记录？"].waitForExistence(timeout: 5))
        app.sheets.buttons["放弃"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    /// The keypad's long presses still work with the keys' pressed look: hold + for ×, hold ⌫ to clear
    func testKeypadLongPressesStillTypeAndClear() {
        let app = launch()   // 12 typed
        let amount = app.staticTexts["金额"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        app.buttons["加，长按为乘"].press(forDuration: 0.8)
        app.buttons["3"].tap()
        XCTAssertEqual(amount.value as? String, "12×3")
        app.buttons["退格"].press(forDuration: 0.8)
        XCTAssertEqual(amount.value as? String, "0")
    }

    /// An empty list of things to add (here budgets) has its own add button, opening the same form as + in the bar
    func testAnEmptyBudgetListOffersToAddOne() {
        let app = launchTab("reports")
        let budgets = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "预算")).firstMatch
        XCTAssertTrue(budgets.waitForExistence(timeout: 20))
        for _ in 0..<5 { if budgets.isHittable { break }; app.swipeUp() }
        budgets.tap()
        let add = app.buttons["empty.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.navigationBars["添加预算"].waitForExistence(timeout: 5))
    }

    /// A long category with a large budget: the figures on the right wrapped to two lines in 本年 (wider than the
    /// month's), so the row, and the card, grew when switching
    func testABudgetRowKeepsItsHeightBetweenMonthAndYear() {
        let extra = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/budget-extra.bean").path
        let app = launchTab("reports", env: ["LEDGER_EXTRA": extra])
        let budgets = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "预算")).firstMatch
        scrollIntoView(budgets, in: app)
        XCTAssertTrue(budgets.waitForExistence(timeout: 20))
        for _ in 0..<5 { if budgets.isHittable { break }; app.swipeUp() }
        budgets.tap()
        let row = app.buttons["budget.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.segmentedControls.buttons["本月"].tap()
        let month = row.frame.height
        app.segmentedControls.buttons["本年"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "3,000,000"), object: row)], timeout: 5), .completed)
        XCTAssertEqual(row.frame.height, month, accuracy: 0.5)
    }

    /// small steps up until `element` is wholly on screen (a full swipe can carry it past)
    private func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists, element.isHittable, element.frame.maxY < app.frame.maxY - 100 { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -150)))
        }
    }

    /// The overview's trend chart is read month by month by VoiceOver, and a finger slid sideways along it picks
    /// months (the last one stays picked: the page shows it, 回到本月 on the card leaves it; there is no 查看该月,
    /// which only made the picked month the page's month and changed nothing in sight)
    func testTheTrendChartIsReadAndSlidAlong() {
        let app = launchTab("overview")
        app.buttons["月"].tap()
        let chart = app.otherElements["overview.trend"]
        XCTAssertTrue(chart.waitForExistence(timeout: 20))
        scrollIntoView(chart, in: app)
        // each month a mark of its own, read with its amount (the chart was one image before)
        let month = chart.otherElements.matching(NSPredicate(format: "label ENDSWITH %@", "月 支出")).firstMatch
        XCTAssertTrue(month.exists)
        XCTAssertTrue((month.value as? String ?? "").hasPrefix("¥"))
        // slid from right to left: the month under the finger last is the one picked, shown on the card above
        let from = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let to = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to)
        let picked = app.otherElements["overview.hero"].staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\\d{4}年\\d{1,2}月支出")).firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["查看该月"].exists)
        let back = app.otherElements["overview.hero"].buttons["回到本月"]
        for _ in 0..<4 where !back.isHittable { app.swipeDown() }
        back.tap()
        XCTAssertTrue(picked.waitForNonExistence(timeout: 5))
    }

    /// A finger drawn up the trend chart scrolls the page, as anywhere else on it (sliding along the chart took
    /// every drag on it, so the page stuck there)
    func testSwipingUpOnTheTrendChartScrollsThePage() {
        let app = launchTab("overview")
        let chart = app.otherElements["overview.trend"]
        XCTAssertTrue(chart.waitForExistence(timeout: 20))
        scrollIntoView(chart, in: app)
        let top = chart.frame.minY
        let from = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -200)))
        // scrolled up, or off the screen altogether
        let moved = NSPredicate { _, _ in !chart.exists || chart.frame.minY < top - 100 }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 3), .completed)
    }

    /// After a save from the form, 明细 scrolls to the entry it wrote when it is far down the list (an older date),
    /// and lights it up
    func testTheJournalScrollsToTheEntryJustSaved() {
        let extra = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/journal-extra.bean").path
        let app = launchTab("journal", env: ["LEDGER_EXTRA": extra, "LEDGER_JUST_SAVED": "Old notebook"])
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Old notebook")).firstMatch
        let shown = NSPredicate(format: "exists == true AND hittable == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shown, object: row)], timeout: 20), .completed)
    }

    /// What a row offers on a swipe is also in its long-press menu (and so in VoiceOver's actions)
    func testARowsSwipeActionsAreInItsLongPressMenu() {
        let app = launchTab("overview", env: ["LEDGER_SYNC": "1", "LEDGER_HELD": "1"])
        // the change LEDGER_HELD kept (other tests' saves may be waiting in the queue too)
        let row = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "sync.pending", "Held cafe")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["推送"].waitForExistence(timeout: 5))
        let remove = app.buttons["移除"]
        XCTAssertTrue(remove.exists)
        // and it leaves the test ledger as it was
        remove.tap()
        app.sheets.buttons["移除"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    /// In a form of several text fields, return moves to the next one (here a new subscription: name → currency)
    func testReturnMovesToTheNextField() {
        let app = launchTab("reports")
        let subs = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "订阅管理")).firstMatch
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "年度回顾")).firstMatch.waitForExistence(timeout: 20))
        // further down the list: not built until scrolled to
        for _ in 0..<6 { if subs.exists && subs.isHittable { break }; app.swipeUp() }
        subs.tap()
        tapPoint(app.buttons["empty.add"], timeout: 5)
        let name = app.textFields["如 iCloud+、Netflix"]
        tapPoint(name, timeout: 5)
        name.typeText("Demo\n")
        let currency = app.textFields["CNY"]
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: focused, object: currency)], timeout: 3), .completed)
    }
}
