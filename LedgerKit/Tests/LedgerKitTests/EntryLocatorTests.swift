import XCTest
@testable import LedgerKit

final class EntryLocatorTests: XCTestCase {
    private let transaction = """
    2026-10-17 * "Shop" "Coffee"
      Expenses:Food  12.00 CNY
      Assets:Bank
    """

    func testFollowsSourceWhenLinesShiftButRejectsChangedOrDeletedEntry() throws {
        let original = try XCTUnwrap(parseFile(transaction, file: "journal.bean").entries.first)
        let locator = EntryLocator(original)
        XCTAssertEqual(locator.text(in: "; added above\n\n" + transaction), transaction)
        XCTAssertNil(locator.text(in: transaction.replacingOccurrences(of: "12.00", with: "20.00")))
        XCTAssertNil(locator.text(in: "2026-10-17 note Assets:Bank \"replacement\""))
        XCTAssertNil(locator.text(in: ""))
    }

    func testDuplicateSourceAndOtherFileAreNotGuessed() throws {
        let original = try XCTUnwrap(parseFile(transaction, file: "journal.bean").entries.first)
        let doubled = transaction + "\n\n" + transaction
        let both = parseFile(doubled, file: "journal.bean").entries
        XCTAssertEqual(both.count, 2)
        // each copy is the one that still starts on its own line
        let first = try XCTUnwrap(EntryLocator(original).resolve(in: both))
        XCTAssertEqual(first.startLine, original.startLine)
        let second = try XCTUnwrap(EntryLocator(both[1]).resolve(in: both))
        XCTAssertEqual(second.startLine, both[1].startLine)
        XCTAssertNotEqual(first.startLine, second.startLine)
        // a line inserted above moves every copy: the old line no longer identifies one, so don't guess
        let shifted = "\n" + doubled
        XCTAssertNil(EntryLocator(original).text(in: shifted))
        XCTAssertNil(EntryLocator(both[1]).text(in: shifted))
        XCTAssertNil(EntryLocator(original).resolve(in: parseFile(transaction, file: "other.bean").entries))
        original.synthetic = true
        XCTAssertNil(EntryLocator(original).text(in: transaction))
    }

    func testIdenticalCopiesEditAndDeleteTheOneOnThatLine() throws {
        let one = """
        2026-10-18 * "Transit" "Top-up"
          Expenses:Food  1.60 CNY
          Assets:Bank   -1.60 CNY
        """
        let file = one + "\n\n" + one + "\n"
        let entries = parseFile(file, file: "2026.bean").entries
        XCTAssertEqual(entries.map(\.narration), ["Top-up", "Top-up"])
        let second = entries[1]
        var edit = Op(kind: .replace, path: "2026.bean")
        edit.old = second.src
        edit.text = second.src.replacingOccurrences(of: "Top-up", with: "Ride")
        edit.anchorLine = second.line
        let edited = try applyOps(file, path: "2026.bean", ops: [edit])
        XCTAssertEqual(parseFile(edited, file: "2026.bean").entries.map(\.narration), ["Top-up", "Ride"])
        // a line that is not the start of either copy, with two copies left, changes neither
        edit.anchorLine = 2
        XCTAssertNil(applyRemove(file, edit))
        var remove = Op(kind: .remove, path: "2026.bean")
        remove.old = second.src
        remove.anchorLine = second.line
        let deleted = try XCTUnwrap(applyRemove(file, remove))
        XCTAssertEqual(parseFile(deleted, file: "2026.bean").entries.map(\.narration), ["Top-up"])
        // edits queued before a line was recorded still change the first copy
        var first = Op(kind: .replace, path: "2026.bean")
        first.old = entries[0].src
        first.text = entries[0].src.replacingOccurrences(of: "Top-up", with: "First")
        let editedFirst = try applyOps(file, path: "2026.bean", ops: [first])
        XCTAssertEqual(parseFile(editedFirst, file: "2026.bean").entries.map(\.narration), ["First", "Top-up"])
    }

    func testEntryOpChangesOnlyTheCopyItWasMadeFrom() throws {
        let coffee = """
        2026-10-28 * "Cafe" "Latte"
          Expenses:Food  18.00 CNY
          Assets:Bank
        """
        let file = coffee + "\n\n" + coffee + "\n"
        let entries = parseFile(file, file: "2026.bean").entries
        let second = try XCTUnwrap(entries.last)
        let tagged = try applyOps(file, path: "2026.bean", ops: [entryOp(second, text: second.src.replacingOccurrences(of: "\"Latte\"", with: "\"Latte\" #work"))])
        XCTAssertEqual(parseFile(tagged, file: "2026.bean").entries.map(\.tags), [[], ["work"]])
        let removed = try applyOps(file, path: "2026.bean", ops: [entryOp(entries[0], text: nil)])
        XCTAssertEqual(parseFile(removed, file: "2026.bean").entries.count, 1)
        XCTAssertEqual(entryOp(second, text: nil).kind, .remove)
    }

    func testBottomUpKeepsLaterAnchorsValidWhenAnEditAddsLines() throws {
        let coffee = """
        2026-10-28 * "Cafe" "Latte"
          Expenses:Food  18.00 CNY
          Assets:Bank
        """
        let file = [coffee, coffee, coffee].joined(separator: "\n\n") + "\n"
        let entries = parseFile(file, file: "2026.bean").entries
        // the first and the third copy each gain a metadata line, as a batch edit does
        let ops = [entries[0], entries[2]].map { e in
            entryOp(e, text: e.src.replacingOccurrences(of: "\"Latte\"", with: "\"Latte\"\n  note: \"batch\""))
        }
        XCTAssertNil(try? applyOps(file, path: "2026.bean", ops: ops, strict: true), "top-down, the third copy's line has moved")
        let edited = try applyOps(file, path: "2026.bean", ops: bottomUp(ops), strict: true)
        XCTAssertEqual(parseFile(edited, file: "2026.bean").entries.map { $0.meta["note"] != nil }, [true, false, true])
        var other = Op(kind: .insert, path: "other.bean")
        other.anchorLine = 99
        XCTAssertEqual(bottomUp([other] + ops).map(\.anchorLine), [99, entries[2].line, entries[0].line])
    }

    func testOldQueuedEditDecodesWithoutAnchorLine() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","kind":"remove","path":"2026.bean","old":"x"}
        """
        let op = try JSONDecoder().decode(Op.self, from: Data(json.utf8))
        XCTAssertNil(op.anchorLine)
        let replacing = """
        {"path":"2026.bean","old":"x","date":"2026-10-18","summary":"Top-up","baseline":"x"}
        """
        let saved = try JSONDecoder().decode(Replacing.self, from: Data(replacing.utf8))
        XCTAssertNil(saved.line)
    }

    func testDirectiveIncludesMetadataAndDoesNotMatchSimilarAssertion() throws {
        let assertion = "2026-10-18 balance Assets:Bank 100.00 CNY\n  note: \"bank checked\""
        let original = try XCTUnwrap(parseFile(assertion, file: "balances.bean").entries.first)
        let locator = EntryLocator(original)
        let other = "2026-10-18 balance Assets:Bank 200.00 CNY"
        XCTAssertEqual(locator.text(in: other + "\n\n" + assertion), assertion)
        XCTAssertNil(locator.text(in: other))
        XCTAssertNil(locator.text(in: assertion.replacingOccurrences(of: "bank checked", with: "changed")))
    }

    func testDocumentRemovalLeavesAttachmentAndOtherEntriesAlone() throws {
        let document = "2026-10-17 document Assets:Bank \"documents/statement.pdf\""
        let file = document + "\n\n" + transaction
        let original = try XCTUnwrap(parseFile(file, file: "journal.bean").entries.first)
        let old = try XCTUnwrap(EntryLocator(original).text(in: file))
        var op = Op(kind: .remove, path: "journal.bean")
        op.old = old
        let edited = try applyOps(file, path: "journal.bean", ops: [op])
        XCTAssertEqual(parseFile(edited, file: "journal.bean").entries.map(\.type), [.txn])
        XCTAssertTrue(edited.contains(transaction))
        XCTAssertEqual(op.kind, .remove, "Removing a document directive never creates a deleteFile operation")
    }
}
