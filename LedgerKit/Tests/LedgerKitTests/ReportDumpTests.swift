import XCTest
@testable import LedgerKit

/// The figures behind the statements for the realistic sample ledger, written out (SAMPLE_OUT) so that CI can
/// work them out again with Beancount itself (tools/check_reports.py) and compare: balances as booked, at cost,
/// at market value and converted, the conversions, income and expenses by month, net worth by month.
final class ReportDumpTests: XCTestCase {
    func testDumpForBeancount() throws {
        guard let dir = ProcessInfo.processInfo.environment["SAMPLE_OUT"] else { return }
        let L = loadSet("realistic")
        let date = "2026-09-30"
        func json(_ b: [String: Inventory]) -> [String: [String: Double]] {
            var out: [String: [String: Double]] = [:]
            for (a, inv) in b { let x = inv.nonZero; if !x.isEmpty { out[a] = Dictionary(x.map { ($0.0, $0.1) }, uniquingKeysWith: +) } }
            return out
        }
        func inv(_ i: Inventory) -> [String: Double] { Dictionary(i.nonZero.map { ($0.0, $0.1) }, uniquingKeysWith: +) }
        var modes: [String: Any] = [:]
        for (name, mode) in [("units", ReportMode.units), ("cost", .cost), ("market", .market), ("convert_CNY", .convert("CNY")), ("convert_USD", .convert("USD"))] {
            let b = valuedBalances(L, to: date, mode: mode)
            let bs = balanceSheet(L, at: date, mode: mode)
            modes[name] = ["accounts": json(b), "conversions": inv(bs.conversions),
                           "net_worth": inv(bs.netWorthShown), "earnings": inv(bs.earningsByCurrency)]
        }
        // income and expenses of this year, by account, as booked
        let year = periodBalances(L, from: "2026-01-01", to: date).filter { $0.key.hasPrefix("Income:") || $0.key.hasPrefix("Expenses:") }
        let months = (1...9).map { String(format: "2026-%02d", $0) }
        let flows = monthlyFlows(L, months: months, mode: .units)
        var fl: [String: Any] = [:]
        for (m, f) in flows { fl[m] = ["income": inv(f.income), "expenses": inv(f.expenses)] }
        var worth: [String: Any] = [:]
        for s in worthSeries(L, today: date, mode: .units) where s.month >= "2025-01" { worth[s.month] = inv(s.total) }
        // only HKD, converted to CNY: the filter comes before the valuation
        let hkd = balanceSheet(L, at: date, mode: .convert("CNY"), only: ["HKD"])
        let out: [String: Any] = ["date": date, "modes": modes, "year": json(year), "flows": fl, "worth": worth,
                                  "hkd_in_cny": inv(hkd.netWorthShown)]
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("reports.json"))
    }
}
