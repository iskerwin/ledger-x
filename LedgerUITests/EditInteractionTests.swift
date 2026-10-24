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
        app.buttons["标签"].tap()
        let input = app.textFields["新标签，如 trip-shanghai"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("phase-two")
        app.buttons["添加"].tap()
        app.navigationBars.buttons["取消"].tap()
        app.buttons["标签"].tap()
        XCTAssertFalse(app.staticTexts["#phase-two"].exists)
        app.navigationBars.buttons["取消"].tap()
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.buttons["关闭"].waitForNonExistence(timeout: 5))
    }

    func testManualFundingSurvivesPayeeSuggestionInFullForm() {
        let app = launch()
        openFull(app)
        let funding = app.buttons["field.付款账户"]
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

    private func launchCardAccount(accessibility: Bool) -> XCUIApplication {
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
        var args = ["-AppleLanguages", "(zh-Hans)"]
        if accessibility {
            args += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchArguments = args
        app.launch()
        return app
    }

    /// Scroll a list until a control can be tapped. Off-screen frames are still valid for layout checks.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 { if element.isHittable { return }; app.swipeUp() }
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

    func testUntouchedFormClosesWithoutPrompt() {
        let app = launch(filled: false)
        let close = app.buttons["关闭"]
        XCTAssertTrue(close.waitForExistence(timeout: 20))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["放弃修改并关闭"].exists)
    }

    /// 今天 appears in the calendar's header away from this month. It must not make the header taller: the whole
    /// calendar grew by a few points as the month changed, and paging stuttered.
    func testCalendarKeepsItsHeightAwayFromThisMonth() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": "journal", "LEDGER_LANG": "zh"]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let calendar = app.otherElements["calendar.month"]
        if !calendar.waitForExistence(timeout: 5) { tapPoint(app.buttons["月历"], timeout: 20) }
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        // the calendar opens on the month last looked at: start from this month
        let today = app.buttons["calendar.today"]
        if today.exists { today.tap() }
        XCTAssertTrue(today.waitForNonExistence(timeout: 5))
        // the weekday names sit right under the header: a taller header pushes them, and the month, down
        let weekday = calendar.staticTexts["一"]
        XCTAssertTrue(weekday.exists)
        let before = weekday.frame.minY
        app.buttons["上个月"].tap()
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        XCTAssertEqual(weekday.frame.minY, before, accuracy: 0.5)
    }

    private func launchTab(_ tab: String, accessibility: Bool = false, env: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").path
        app.launchEnvironment = ["LEDGER_DEMO": fixture, "LEDGER_TAB": tab, "LEDGER_LANG": "zh"].merging(env) { $1 }
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
            + (accessibility ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
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
        // a second currency puts net worth on two lines: taller than the year's flows
        let app = launchTab("accounts", env: ["LEDGER_EXTRA": heightExtra])
        let flows = app.buttons["收支"]
        XCTAssertTrue(flows.waitForExistence(timeout: 20))
        // the tab is remembered: start from 全部
        app.buttons["全部"].tap()
        XCTAssertTrue(app.staticTexts["资产负债率"].waitForExistence(timeout: 5))
        // the other tab's card keeps its place unseen: VoiceOver does not read it
        XCTAssertFalse(app.staticTexts["储蓄率"].exists)
        let before = flows.frame.minY
        flows.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "年结余")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(flows.frame.minY, before, accuracy: 0.5)
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
        let funding = app.buttons["field.付款账户"]
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
        let app = launchTab("journal", env: ["LEDGER_EXTRA": heightExtra, "LEDGER_CALENDAR": "1"])
        let calendar = app.otherElements["calendar.month"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 20))
        let today = app.buttons["calendar.today"]
        if today.exists { today.tap() }
        XCTAssertTrue(today.waitForNonExistence(timeout: 5))
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
