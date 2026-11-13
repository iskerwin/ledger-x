import Foundation
import LedgerKit

/// what the pages show, worked out once for a ledger and what else it depends on (a period, today, a setting). A
/// ledger doesn't change once loaded, so a page drawn again, as the pointer moves or a row opens, reads its figures back
/// instead of going through every entry again; a change in the folder loads a new ledger, and with it new figures
extension Ledger {
    private func kept<T>(_ key: String, _ make: () -> T) -> T { memoized("mac|" + key, make) }

    func incomeStatementKept(from: String, to: String) -> IncomeStatement {
        kept("incomeStatement|\(from)|\(to)") { incomeStatement(self, from: from, to: to) }
    }

    func netWorthKept(exclude: [String]) -> (assets: Double, liabilities: Double) {
        kept("netWorth|\(Day.today())|\(exclude.joined(separator: ","))") { netWorthNow(self, exclude: exclude) }
    }

    func monthlyFlowsKept(_ months: [String], mode: ReportMode) -> [String: MonthFlow] {
        kept("monthlyFlows|\(mode.raw)|\(months.joined(separator: ","))") { monthlyFlows(self, months: months, mode: mode) }
    }

    /// every month with an entry, in operating units
    func allMonthlyFlowsKept() -> [String: MonthFlow] {
        kept("allMonthlyFlows") { monthlyFlows(self, months: txns.map { Day.ym($0.date) }, mode: .units) }
    }

    func cardCyclesKept() -> [CardCycle] {
        kept("cardCycles|\(Day.today())") { cardCycles(self) }
    }

    func reconcileDueKept() -> [ReconcileDue] {
        kept("reconcileDue|\(Day.today())") { reconcileDue(self) }
    }

    func budgetProgressKept(_ key: String) -> [BudgetProgress] {
        kept("budgetProgress|\(key)|\(Day.today())") { budgetProgress(self, key: key) }
    }

    func budgetsKept() -> [Budget] {
        kept("budgets") { budgets(self) }
    }

    func forecastKept(days: Int, payslips: [PayslipTemplate], largeExpense: Double) -> Forecast {
        let slips = payslips.map { "\($0)" }.joined(separator: ";")
        return kept("forecast|\(Day.today())|\(days)|\(largeExpense)|\(slips)") {
            forecast(self, days: days, payslips: payslips, largeExpense: largeExpense)
        }
    }

    func subscriptionsKept() -> [Subscription] {
        kept("subscriptions") { subscriptions(self) }
    }

    func subscriptionsDueKept() -> [SubDue] {
        kept("subscriptionsDue|\(Day.today())") { subscriptionsDue(self, subs: subscriptionsKept()) }
    }

    func subscriptionCandidatesKept() -> [SubCandidate] {
        kept("subscriptionCandidates|\(Day.today())") { subscriptionCandidates(self, subs: subscriptionsKept()) }
    }

    func reimbBatchesKept() -> [ReimbBatch] {
        kept("reimbBatches") { reimbBatches(self) }
    }

    func eventsKept() -> [LedgerEvent] {
        kept("events|\(Day.today())") { ledgerEvents(self) }
    }

    func eventSummaryKept(_ tag: String, reimbursement: String) -> EventSummary {
        kept("eventSummary|\(tag)|\(reimbursement)") { eventSummary(self, tag, reimbursement: reimbursement) }
    }

    /// the payslips, oldest first
    func payslipsKept() -> [Entry] {
        kept("payslips") { txns.filter { $0.links.contains { $0.hasPrefix("salary-") } && payslipFigures($0, self) != nil } }
    }

    func balanceSheetKept(at date: String?, exclude: [String]) -> BalanceSheet {
        kept("balanceSheet|\(date ?? Day.today())|\(exclude.joined(separator: ","))") { balanceSheet(self, at: date, exclude: exclude) }
    }

    func periodBalancesKept(to end: String) -> [String: Inventory] {
        kept("periodBalances|\(end)") { periodBalances(self, to: end) }
    }

    /// what `account` and those under it hold after each entry that moves them
    func runningBalancesKept(_ account: String) -> [ObjectIdentifier: Inventory] {
        kept("runningBalances|" + account) { runningBalances(self, account: account) }
    }

    /// what `account` held at the end of each of the last twelve months, in one currency
    func monthlyBalancesKept(_ account: String, currency: String) -> [BalancePoint] {
        kept("monthlyBalances|\(account)|\(currency)|\(Day.today())") { monthlyBalances(self, account: account, currency: currency) }
    }

    func monthColumnsKept(_ months: [String], roots: [String], held: Bool) -> MonthColumns {
        monthColumns(self, months: months, roots: roots, held: held)
    }

    func netWorthSeriesKept(exclude: [String]) -> [NetWorthPoint] {
        kept("netWorthSeries|\(Day.today())|\(exclude.joined(separator: ","))") { netWorthSeries(self, exclude: exclude) }
    }

    /// the entries with this payee, oldest first
    func payeeEntriesKept(_ name: String) -> [Entry] {
        kept("payeeEntries|\(name)") { txns.filter { !$0.synthetic && $0.payee == name } }
    }
}
