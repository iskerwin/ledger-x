import SwiftUI
import LedgerKit

struct JournalPage: View {
    let ledger: Ledger
    @State private var text = ""

    var body: some View {
        let query = TxQuery(text)
        let rows = ledger.txns.reversed().filter { query.matches($0, ledger) }
        Group {
            if rows.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: text)
            } else {
                List(rows.indices, id: \.self) { index in
                    JournalRow(entry: rows[index], ledger: ledger)
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $text, placement: .toolbar)
    }
}

private struct JournalRow: View {
    let entry: Entry
    let ledger: Ledger

    var body: some View {
        HStack(spacing: 16) {
            Text(entry.date)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(entry.payee.isEmpty ? entry.narration : entry.payee)
                .lineLimit(1)
            if !entry.payee.isEmpty && !entry.narration.isEmpty {
                Text(entry.narration)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing) {
                ForEach(amounts, id: \.self) { Text($0).monospacedDigit() }
            }
            .foregroundStyle(isTransfer ? .secondary : .primary)
        }
        .padding(.vertical, 2)
    }

    private var isTransfer: Bool { classify(entry, ledger).kind == .transfer }

    /// as in the phone's journal: a transfer's amount, else what was spent or earned in each currency as booked
    private var amounts: [String] {
        let shown = classify(entry, ledger)
        if shown.kind == .transfer { return [money(shown.amount, shown.currency ?? "CNY")] }
        var order: [String] = [], sums: [String: Double] = [:]
        for posting in entry.postings where posting.account.hasPrefix("Expenses:") || posting.account.hasPrefix("Income:") {
            guard let units = posting.units, let currency = posting.currency else { continue }
            if sums[currency] == nil { order.append(currency) }
            sums[currency, default: 0] -= units
        }
        return order.map { signedMoney(sums[$0]!, $0) }
    }
}
