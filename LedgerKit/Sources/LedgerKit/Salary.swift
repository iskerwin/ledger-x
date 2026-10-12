import Foundation

// MARK: - salary by payslip: every item of the payslip on its own account, one transaction a month
//
//   2026-09-24 * "柴鹿" "2026-08 工资" ^salary-chailu-202608
//     payslip_days: 21
//     Income:Salary:Base         -5000.00 CNY       应发项（负数：收入）
//     Income:Salary:Performance  -2000.00 CNY
//     Income:Salary:Deduction       100.00 CNY      扣款项（正数）
//     Assets:Receivable:Employer   1940.00 CNY      实发里还没到账的部分（公司往来）
//     Assets:Bank:BOC              4960.00 CNY      到账
//
// The templates (which items, which accounts, where the pay goes) live in ledger-x.json, shared by every device.

public struct PayslipItem: Codable, Equatable, Identifiable, Hashable {
    public var name: String
    public var account: String
    /// taken off the pay (leave, tax…) rather than part of it
    public var deduct: Bool
    public var id: String { name }
    public init(name: String, account: String, deduct: Bool = false) { self.name = name; self.account = account; self.deduct = deduct }
}

public struct PayslipTemplate: Codable, Equatable, Identifiable {
    /// the payee of the salary transactions ("柴鹿")
    public var employer: String
    public var items: [PayslipItem]
    /// where the pay goes
    public var account: String
    /// the link's middle part: ^salary-<slug>-YYYYMM (pinyin of the employer when empty)
    public var slug: String?
    public var id: String { employer }
    public init(employer: String, items: [PayslipItem] = PayslipTemplate.defaultItems, account: String = "", slug: String? = nil) {
        self.employer = employer; self.items = items; self.account = account; self.slug = slug
    }

    public var linkSlug: String {
        let s = (slug ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? LedgerKit.linkSlug(employer) : s
    }

    /// the items of a usual payslip
    public static let defaultItems: [PayslipItem] = [
        PayslipItem(name: "基本工资", account: "Income:Salary:Base"),
        PayslipItem(name: "绩效工资", account: "Income:Salary:Performance"),
        PayslipItem(name: "社保补贴", account: "Income:Salary:Allowance"),
        PayslipItem(name: "过年福利", account: "Income:Salary:Bonus"),
        PayslipItem(name: "经济补偿金", account: "Income:Salary:Severance"),
        PayslipItem(name: "请假扣除工资", account: "Income:Salary:Deduction", deduct: true),
        PayslipItem(name: "其他扣除", account: "Income:Salary:Deduction", deduct: true),
        PayslipItem(name: "代扣个税", account: "Expenses:Government:IncomeTax", deduct: true),
    ]
}

/// one month's payslip as filled in
public struct PayslipDraft: Equatable {
    public var template: PayslipTemplate
    /// the month worked: "2026-08"
    public var month: String
    /// the day the pay came in
    public var date: String
    /// amount per item name ("" = 0)
    public var values: [String: String] = [:]
    /// what actually came in (empty: all of the net pay)
    public var received = ""
    public var account: String
    public var days = ""
    public init(template: PayslipTemplate, month: String, date: String) {
        self.template = template; self.month = month; self.date = date; self.account = template.account
    }

    public func value(_ item: PayslipItem) -> Double { evalAmount(values[item.name] ?? "") ?? 0 }
    /// 应发
    public var gross: Double { roundTo(template.items.filter { !$0.deduct }.reduce(0) { $0 + value($1) }, 2) }
    public var deductions: Double { roundTo(template.items.filter { $0.deduct }.reduce(0) { $0 + value($1) }, 2) }
    /// 实发
    public var net: Double { roundTo(gross - deductions, 2) }
    public var receivedAmount: Double { evalAmount(received) ?? net }
    /// still owed by the company (negative: paid over)
    public var pending: Double { roundTo(net - receivedAmount, 2) }
    public var link: String { "salary-\(template.linkSlug)-\(month.replacingOccurrences(of: "-", with: ""))" }
}

/// the Beancount text for a payslip (accounts it needs and the ledger lacks are opened first)
public func payslipText(_ d: PayslipDraft, _ L: Ledger, currency: String = "CNY", receivable: String = "Assets:Receivable:Employer") -> String {
    guard d.gross > 0, d.net >= 0, !d.account.isEmpty, !d.date.isEmpty, d.month.count == 7 else { return "" }
    var tx = TxDraft(date: d.date)
    tx.payee = d.template.employer
    tx.narration = tr("\(d.month) 工资", "\(d.month) salary")
    tx.links = [d.link]
    if let n = Int(d.days.trimmingCharacters(in: .whitespaces)), n > 0 { tx.meta.append(("payslip_days", String(n))) }
    // one posting per account (two deductions may share one)
    var sums: [String: Double] = [:], order: [String] = []
    for i in d.template.items {
        let v = d.value(i)
        guard abs(v) > 0.004 else { continue }
        if sums[i.account] == nil { order.append(i.account) }
        sums[i.account, default: 0] += i.deduct ? v : -v
    }
    for a in order where abs(sums[a]!) > 0.004 { tx.postings.append(TxPosting(account: a, amount: roundTo(sums[a]!, 2), currency: currency)) }
    if abs(d.pending) > 0.004 { tx.postings.append(TxPosting(account: receivable, amount: d.pending, currency: currency)) }
    if d.receivedAmount > 0.004 { tx.postings.append(TxPosting(account: d.account, amount: roundTo(d.receivedAmount, 2), currency: currency)) }
    var seen = Set<String>()
    let opens = tx.postings.map { $0.account }.filter { a in (L.accounts[a] == nil || L.accounts[a]!.implicit) && seen.insert(a).inserted }
        .map { openLine($0, date: d.date, name: salaryAccountNames[$0]) }
    return (opens + [formatTxn(tx)]).joined(separator: "\n\n")
}

/// names for the accounts a payslip may open
let salaryAccountNames: [String: String] = [
    "Income:Salary:Performance": "绩效工资",
    "Income:Salary:Allowance": "补贴",
    "Income:Salary:Deduction": "工资扣款",
    "Expenses:Government:IncomeTax": "个人所得税",
]

/// the latest salary transaction of an employer, for filling in this month's form
public func lastPayslip(_ L: Ledger, employer: String) -> Entry? {
    L.txns.last { $0.payee == employer && $0.links.contains { $0.hasPrefix("salary-") } && $0.postings.contains { $0.account.hasPrefix("Income:Salary") } }
}

/// a new form for `month`, with the amounts of the latest payslip of the employer (by account)
public func payslipDraft(_ L: Ledger, template t: PayslipTemplate, month: String, date: String) -> PayslipDraft {
    var d = PayslipDraft(template: t, month: month, date: date)
    if let e = lastPayslip(L, employer: t.employer) {
        var byAccount: [String: Double] = [:]
        for p in e.postings { byAccount[p.account, default: 0] += p.units ?? 0 }
        // an account shared by several items: the whole amount on the first of them
        var used = Set<String>()
        for i in t.items where used.insert(i.account).inserted {
            if let v = byAccount[i.account], abs(v) > 0.004 { d.values[i.name] = toFixed(abs(v), 2) }
        }
        if let n = e.meta["payslip_days"] { d.days = n.display }
        if d.account.isEmpty, let to = e.postings.first(where: { ($0.units ?? 0) > 0 && !$0.account.hasPrefix("Income:") && !$0.account.hasPrefix("Expenses:") && !isSalaryClearing($0.account) }) {
            d.account = to.account
        }
    }
    return d
}

/// a year of salary: gross by account, deductions, tax and what came in
public struct SalaryYear: Equatable {
    public let year: String
    /// income accounts (positive amounts)
    public let earnings: [String: Double]
    /// deduction accounts other than tax
    public let deductions: Double
    public let tax: Double
    public let months: Int
    public var gross: Double { earnings.values.reduce(0, +) }
    public var net: Double { gross - deductions - tax }
}

public func salaryYears(_ L: Ledger) -> [SalaryYear] {
    var earn: [String: [String: Double]] = [:], ded: [String: Double] = [:], tax: [String: Double] = [:], months: [String: Set<String>] = [:]
    for t in L.txns {
        let y = String(t.date.prefix(4))
        var any = false
        for p in t.postings {
            let v = toCNY(L, p.units ?? 0, p.currency ?? L.base, t.date) ?? 0
            if p.account.hasPrefix("Income:Salary") {
                any = true
                if p.account == "Income:Salary:Deduction" { ded[y, default: 0] += v }
                else { earn[y, default: [:]][p.account, default: 0] -= v }
            } else if p.account == "Expenses:Government:IncomeTax" {
                tax[y, default: 0] += v
            }
        }
        if any { months[y, default: []].insert(String(t.date.prefix(7))) }
    }
    return Set(earn.keys).union(tax.keys).sorted(by: >).map { y in
        SalaryYear(year: y, earnings: (earn[y] ?? [:]).mapValues { roundTo($0, 2) }.filter { abs($0.value) > 0.005 },
                   deductions: roundTo(ded[y] ?? 0, 2), tax: roundTo(tax[y] ?? 0, 2), months: months[y]?.count ?? 0)
    }
}
