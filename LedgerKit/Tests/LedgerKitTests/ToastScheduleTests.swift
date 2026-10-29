import XCTest
@testable import LedgerKit

final class ToastScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testPlainToastLastsThreeSecondsFromTheMomentItIsVisible() {
        var schedule = ToastSchedule()
        schedule.enqueue(ToastNotice(text: "已入账"), now: start, settle: true)
        schedule.advance(now: start.addingTimeInterval(0.49))
        XCTAssertNil(schedule.visible)
        schedule.advance(now: start.addingTimeInterval(0.5))
        XCTAssertEqual(schedule.visible?.text, "已入账")
        schedule.advance(now: start.addingTimeInterval(3.49))
        XCTAssertEqual(schedule.visible?.text, "已入账")
        schedule.advance(now: start.addingTimeInterval(3.5))
        XCTAssertNil(schedule.visible)
        XCTAssertTrue(schedule.isQuiescent)
    }

    /// The tap after a save is felt when 已入账 appears, after the card has closed, not while it is still closing.
    func testFeedbackComesWithTheNoticeOnScreenOnce() {
        var schedule = ToastSchedule()
        schedule.enqueue(ToastNotice(text: "已入账", feedback: .success), now: start, settle: true)
        XCTAssertNil(schedule.announce(), "the card is still closing")
        schedule.advance(now: start.addingTimeInterval(0.49))
        XCTAssertNil(schedule.announce())
        schedule.advance(now: start.addingTimeInterval(0.5))
        XCTAssertEqual(schedule.announce()?.feedback, .success)
        XCTAssertNil(schedule.announce(), "felt once")
        schedule.enqueue(ToastNotice(text: "已复制"), now: start.addingTimeInterval(1), settle: false)
        XCTAssertNil(schedule.announce(), "waits behind the notice on screen")
        schedule.dismissVisible(now: start.addingTimeInterval(1))
        XCTAssertEqual(schedule.announce()?.text, "已复制")
    }

    func testUndoToastLastsSixSecondsAndBusyTimeDoesNotCount() {
        var schedule = ToastSchedule()
        schedule.enqueue(ToastNotice(text: "已入账", action: "撤销"), now: start, settle: false)
        XCTAssertEqual(schedule.visible?.action, "撤销")
        schedule.advance(now: start.addingTimeInterval(1))
        schedule.setBusy(true, now: start.addingTimeInterval(1))
        schedule.advance(now: start.addingTimeInterval(8))
        XCTAssertEqual(schedule.visible?.text, "已入账")
        schedule.setBusy(false, now: start.addingTimeInterval(8))
        schedule.advance(now: start.addingTimeInterval(12.9))
        XCTAssertEqual(schedule.visible?.text, "已入账")
        schedule.advance(now: start.addingTimeInterval(13))
        XCTAssertNil(schedule.visible)
    }

    func testRebuildHoldsTheSaveToastUntilThePageIsIdle() {
        var schedule = ToastSchedule()
        schedule.setBusy(true, now: start)
        schedule.enqueue(ToastNotice(text: "已入账"), now: start, settle: true)
        schedule.advance(now: start.addingTimeInterval(2))
        XCTAssertNil(schedule.visible)
        schedule.setBusy(false, now: start.addingTimeInterval(2))
        XCTAssertEqual(schedule.visible?.text, "已入账")
        schedule.advance(now: start.addingTimeInterval(4.9))
        XCTAssertNotNil(schedule.visible)
        schedule.advance(now: start.addingTimeInterval(5))
        XCTAssertNil(schedule.visible)
    }

    func testNoticingARebuildLateDoesNotEatTheVisibleTime() {
        var schedule = ToastSchedule()
        schedule.enqueue(ToastNotice(text: "已入账"), now: start, settle: false)
        schedule.advance(now: start.addingTimeInterval(1))
        schedule.setBusy(true, now: start.addingTimeInterval(5))
        schedule.setBusy(false, now: start.addingTimeInterval(5))
        schedule.advance(now: start.addingTimeInterval(6.9))
        XCTAssertEqual(schedule.visible?.text, "已入账")
        schedule.advance(now: start.addingTimeInterval(7))
        XCTAssertNil(schedule.visible)
    }

    func testLaterHintWaitsUntilTheSaveToastFinishes() {
        var schedule = ToastSchedule()
        schedule.enqueue(ToastNotice(text: "已入账", action: "撤销"), now: start, settle: false)
        schedule.enqueue(ToastNotice(text: "看起来是每月扣费", action: "加入订阅"), now: start.addingTimeInterval(2.5), settle: false)
        schedule.advance(now: start.addingTimeInterval(2.5))
        XCTAssertEqual(schedule.visible?.text, "已入账")
        XCTAssertEqual(schedule.queued.map(\.text), ["看起来是每月扣费"])
        schedule.advance(now: start.addingTimeInterval(5.9))
        XCTAssertEqual(schedule.visible?.text, "已入账")
        schedule.advance(now: start.addingTimeInterval(6))
        XCTAssertEqual(schedule.visible?.text, "看起来是每月扣费")
        XCTAssertTrue(schedule.queued.isEmpty)
    }

    /// a failure stays a little longer than plain text, and an undo longer still
    func testAFailureStaysLongerThanPlainText() {
        XCTAssertEqual(ToastNotice(text: "已保存").duration, ToastSchedule.plain)
        XCTAssertEqual(ToastNotice(text: "备份失败", feedback: .failure).duration, ToastSchedule.failure)
        XCTAssertGreaterThan(ToastSchedule.failure, ToastSchedule.plain)
        XCTAssertEqual(ToastNotice(text: "已删除", action: "撤销", feedback: .failure).duration, ToastSchedule.undo)
    }
}
