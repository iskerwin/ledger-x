import Foundation
import LedgerKit

// Settings that belong to the ledger rather than the phone live in ledger-x.json, so every device follows them:
// the main file, 记账偏好 defaults, the 大额支出 threshold, 值得留意 checked, link problems and subscription
// suggestions set aside, 常用交易 pinned / hidden. (Saved queries are .bql files in the repository.)
// Before they were moved there, they were kept on this phone; those values are read until the one-time move.

extension Store {
    /// the move is under way (its own commit reloads the ledger, which would start it again)
    static var migratingSettings = false

    /// this ledger's phone-only settings have been moved into ledger-x.json
    var settingsMigrated: Bool { Prefs.get(pk("config.migrated"), false) }

    /// Change ledger-x.json (one commit). Nothing is written when the change makes no difference.
    @discardableResult
    func updateConfig(_ label: String, word: String? = nil, _ change: (inout LedgerXConfig) -> Void) async -> Bool {
        let before = effectiveConfig
        var c = before
        change(&c)
        guard c != before || repoConfig == nil else { return true }
        var op = Op(kind: .write, path: LedgerXConfig.path)
        op.text = c.json()
        op.label = label
        return await commit([op], word: word ?? LS("已保存到 %@", LedgerXConfig.path), checked: true)
    }

    // MARK: 记账偏好

    /// the paying account of a new entry; nil = the most used one
    var defaultFunding: String? {
        get { repoConfig?.defaultFunding ?? (settingsMigrated ? nil : localDefaultFunding) }
        set { let v = newValue; Task { await updateConfig(LS("默认付款账户：%@", v ?? LS("自动"))) { $0.defaultFunding = v } } }
    }

    /// currency of new expenses / income / refunds; nil = the paying account's own currency
    var defaultCurrency: String? {
        get { repoConfig?.defaultCurrency ?? (settingsMigrated ? nil : localDefaultCurrency) }
        set { let v = newValue; Task { await updateConfig(LS("默认币种：%@", v ?? LS("跟随付款账户"))) { $0.defaultCurrency = v } } }
    }

    // MARK: 常用交易

    var tplPinned: [String] {
        get { repoConfig?.templatesPinned ?? (settingsMigrated ? [] : localTplPinned) }
        set { let v = newValue; Task { await updateConfig(LS("常用交易置顶"), word: LS("已更新常用交易")) { $0.templatesPinned = v } } }
    }

    var tplHidden: [String] {
        get { repoConfig?.templatesHidden ?? (settingsMigrated ? [] : localTplHidden) }
        set { let v = newValue; Task { await updateConfig(LS("常用交易隐藏"), word: LS("已更新常用交易")) { $0.templatesHidden = v } } }
    }

    // MARK: 值得留意

    func setLargeExpense(_ v: Double) async {
        await updateConfig(LS("大额支出：%@", money(v, L?.base ?? "CNY", 0))) { $0.largeExpense = v }
    }

    /// link problems set aside
    var ignoredLinkIDs: [String] {
        repoConfig?.linksIgnored ?? (settingsMigrated ? [] : Prefs.get(pk("link.ignored"), [String]()))
    }

    func setIgnoredLinks(_ l: [String], label: String) async {
        await updateConfig(label) { $0.linksIgnored = l }
    }

    /// subscription suggestions set aside
    var ignoredSubIDs: [String] {
        repoConfig?.subsIgnored ?? (settingsMigrated ? [] : Prefs.get(pk("sub.ignored"), [String]()))
    }

    func setIgnoredSubs(_ l: [String], label: String) async {
        await updateConfig(label) { $0.subsIgnored = l }
    }

    // MARK: the one-time move

    /// Move what this phone kept for the ledger into ledger-x.json (one commit), and saved queries into
    /// queries/custom.bql. Values already in ledger-x.json win; accounts the ledger doesn't have are left out.
    func migrateLocalSettings() async {
        guard !settingsMigrated, !Store.migratingSettings, connected, let L = L else { return }
        Store.migratingSettings = true
        defer { Store.migratingSettings = false }
        // wait for anything not pushed yet to settle: the move goes on top of the file as it is
        guard !pending.contains(where: { $0.failed != nil || $0.held != nil }) else { return }
        var c = effectiveConfig
        let before = c
        let has = { (a: String) in L.accounts[a] != nil }
        if c.main == nil, !mainFile.trimmed.isEmpty, mainFile.trimmed != "main.bean" { c.main = mainFile.trimmed }
        if c.defaultFunding == nil, let f = localDefaultFunding, has(f) { c.defaultFunding = f }
        if c.defaultCurrency == nil, let cur = localDefaultCurrency { c.defaultCurrency = cur }
        if c.largeExpense == nil, UserDefaults.standard.object(forKey: "ledger.alerts.large") != nil { c.largeExpense = AppSettings.shared.largeExpense }
        let alerts = Prefs.get(pk("alerts.dismissed"), Set<String>())
        if c.alertsConfirmed == nil, !alerts.isEmpty { c.alertsConfirmed = Array(alerts) }
        let links = Prefs.get(pk("link.ignored"), [String]())
        if c.linksIgnored == nil, !links.isEmpty { c.linksIgnored = links }
        let subs = Prefs.get(pk("sub.ignored"), [String]())
        if c.subsIgnored == nil, !subs.isEmpty { c.subsIgnored = subs }
        if c.templatesPinned == nil, !localTplPinned.isEmpty { c.templatesPinned = localTplPinned }
        if c.templatesHidden == nil, !localTplHidden.isEmpty { c.templatesHidden = localTplHidden }
        if c != before || (repoConfig == nil && c != LedgerXConfig()) {
            var op = Op(kind: .write, path: LedgerXConfig.path)
            op.text = c.json()
            op.label = LS("把本机的设置移入 %@", LedgerXConfig.path)
            guard await commit([op], word: LS("设置已移入 %@，各设备共用", LedgerXConfig.path), checked: true) else { return }
        }
        if !myQueries.isEmpty { await moveLocalQueries() }
        Prefs.set(pk("config.migrated"), true)
    }
}
