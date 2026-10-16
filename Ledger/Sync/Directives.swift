import Foundation
import LedgerKit

// Single-line directives the app writes besides transactions: a commodity declaration (check_commodity's fix),
// an account's notes, and Beancount's own events. Each goes where fileFor puts its kind, through the change review.

extension Store {
    /// `commodity <c>`, dated like the declarations already there (or the day the currency was first used)
    func declareCommodity(_ c: String, firstUsed: String?) async {
        guard let L = L else { return }
        let date = L.entries.filter { $0.type == .commodity }.map { $0.date }.min() ?? firstUsed ?? Day.today()
        guard let ops = makeOps("\(date) commodity \(c)", extra: OpExtra(label: LS("声明币种 %@", c)), single: false) else { return }
        _ = await commit(ops, word: LS("已补上 %@ 的声明", c))
    }

    /// a new note on an account; true when committed
    func addNote(account: String, date: String, comment: String) async -> Bool {
        guard let ops = makeOps(noteText(date: date, account: account, comment: comment),
                                extra: OpExtra(label: LS("添加备注：%@", account)), single: false) else { return false }
        return await commit(ops, word: LS("已添加备注"))
    }

    /// a note (or an event directive) rewritten in place, or moved when its date changes
    func replaceDirective(_ e: Entry, with text: String, summary: String, word: String) async -> Bool {
        guard let old = await entryText(e) else { show(LS("这一条所在的文件已经变了，请刷新后再试")); return false }
        guard let ops = await replaceOps(old: old, path: e.file, date: e.date, summary: summary, newText: text, transaction: false) else { return false }
        return await commit(ops, word: word, checked: true)
    }

    func deleteDirective(_ e: Entry, summary: String) async -> Bool {
        guard let old = await entryText(e) else { show(LS("这一条所在的文件已经变了，请刷新后再试")); return false }
        return await deleteEntry(path: e.file, old: old, date: e.date, summary: summary)
    }

    /// a card's bill as the bank states it (card-bill); true when committed
    func addCardBill(_ text: String, label: String) async -> Bool {
        guard let ops = makeOps(text, extra: OpExtra(label: label), single: false) else { return false }
        return await commit(ops, word: LS("已记下本期账单"))
    }

    /// a new value of one of Beancount's events (where you live, who you work for…)
    func addLifeEvent(type: String, value: String, date: String) async -> Bool {
        guard let ops = makeOps(lifeEventText(date: date, type: type, value: value),
                                extra: OpExtra(label: LS("记录变化：%@", type)), single: false) else { return false }
        return await commit(ops, word: LS("已记录"))
    }
}
