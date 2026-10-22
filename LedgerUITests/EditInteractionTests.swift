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
        // Anchor the drag to the visible sheet, not a background navigation bar.
        let start = app.buttons["关闭"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
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
        app.buttons["account.Assets:Cash"].firstMatch.tap()
        app.navigationBars.buttons["完成"].tap()
        let merchant = app.textFields["收付款方（如 便利店、淘宝）"]
        for _ in 0..<5 { if merchant.isHittable { break }; app.swipeDown() }
        merchant.tap()
        if !waitForSoftwareKeyboard(app, field: merchant, timeout: 3).focused {
            merchant.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        }
        assertCanType(app, into: merchant)
        merchant.typeText("Coffee\n")
        let done = app.buttons["完成"].firstMatch
        if done.exists { done.tap() }
        for _ in 0..<5 { if funding.exists { break }; app.swipeUp() }
        XCTAssertEqual(funding.value as? String, "Assets:Cash")
    }

    private func openFull(_ app: XCUIApplication) {
        app.navigationBars.buttons["更多"].firstMatch.tap(); app.buttons["完整表单"].tap()
        XCTAssertTrue(app.buttons["快捷记账"].waitForExistence(timeout: 5))
    }

    func testTransferFeeCancelCompleteAndKeyboardDismissal() {
        let app = launch()
        tapKind(app, "转账")
        let fee = app.buttons["transfer.fee"]
        tapPoint(fee, timeout: 5)
        let input = app.textFields["transfer.fee.amount"]
        tapPoint(input, timeout: 5)
        assertCanType(app, into: input)
        input.typeText("2")
        tapPoint(app.buttons["收起键盘"], timeout: 5)
        app.navigationBars.buttons["取消"].tap()
        XCTAssertEqual(fee.value as? String, "")
        fee.tap()
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
        app.buttons["币种与汇率"].tap()
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
        app.buttons["币种与汇率"].tap()
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
        let summary = app.buttons["收付款方与备注"]
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
        app.buttons["收付款方与备注"].tap()
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
        XCTAssertTrue((app.buttons["收付款方与备注"].value as? String ?? "").contains("updated"))
    }

    func testImportKeepsFundingChoiceAfterClosingAndReopening() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        app.launchEnvironment = ["LEDGER_DEMO": directory.path, "LEDGER_TAB": "add", "LEDGER_LANG": "zh", "LEDGER_IMPORT": directory.appendingPathComponent("recovery.csv").path]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let funding = app.buttons["import.funding"].firstMatch
        tapPoint(funding, timeout: 20)
        tapPoint(app.buttons["account.Assets:Cash"].firstMatch, timeout: 5)
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
        app.buttons["币种与汇率"].tap()
        let fee = app.textFields["transfer.fee.amount"]
        XCTAssertTrue(fee.waitForExistence(timeout: 5))
        fee.tap()
        assertCanType(app, into: fee)
        fee.typeText("2")
        app.buttons["收起键盘"].tap()
        app.navigationBars.buttons["取消"].tap()
        XCTAssertFalse(app.buttons["expense.fee"].exists)
        XCTAssertEqual(app.staticTexts["金额"].value as? String, "12")
        app.buttons["币种与汇率"].tap()
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
}

