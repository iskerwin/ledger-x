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
}
