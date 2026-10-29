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
    /// Changes go one after another, each applied to the file as it is then — with the changes before it, pushed
    /// or not — so two in a row both stay (the second is not worked out from settings the first hasn't reached yet).
    @discardableResult
    func updateConfig(_ label: String, word: String? = nil, _ change: @escaping (inout LedgerXConfig) -> Void) async -> Bool {
        let before = configUpdate
        let t = Task { @MainActor () -> Bool in
            _ = await before?.value
            return await self.updateConfigNow(label, word: word, change)
        }
        configUpdate = t
        return await t.value
    }

    private func updateConfigNow(_ label: String, word: String?, _ change: (inout LedgerXConfig) -> Void) async -> Bool {
        // the file with what is queued for it; the settings worked out from the phone when there is none yet
        let before = (try? await fileText(LedgerXConfig.path)).flatMap(LedgerXConfig.parse) ?? effectiveConfig
        var c = before
        change(&c)
        guard c != before || repoConfig == nil else { return true }
        guard var op = await fileWriteOp(LedgerXConfig.path, text: c.json()) else { return false }
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

    var tplPinned: [String] { repoConfig?.templatesPinned ?? (settingsMigrated ? [] : localTplPinned) }
    var tplHidden: [String] { repoConfig?.templatesHidden ?? (settingsMigrated ? [] : localTplHidden) }

    func pinTemplate(_ id: String, _ on: Bool) {
        Task { await updateConfig(on ? LS("常用交易置顶") : LS("常用交易取消置顶"), word: LS("已更新常用交易")) { on ? $0.pinTemplate(id) : $0.unpinTemplate(id) } }
    }

    func hideTemplate(_ id: String) {
        Task { await updateConfig(LS("常用交易隐藏"), word: LS("已更新常用交易")) { $0.hideTemplate(id) } }
    }

    func unhideAllTemplates() {
        Task { await updateConfig(LS("恢复隐藏的常用交易"), word: LS("已更新常用交易")) { $0.unhideAllTemplates() } }
    }

    // MARK: 值得留意

    func setLargeExpense(_ v: Double) async {
        await updateConfig(LS("大额支出：%@", money(v, L?.base ?? "CNY", 0))) { $0.largeExpense = v }
    }

    /// link problems set aside
    var ignoredLinkIDs: [String] {
        repoConfig?.linksIgnored ?? (settingsMigrated ? [] : Prefs.get(pk("link.ignored"), [String]()))
    }

    func ignoreLink(_ key: String, label: String) async {
        await updateConfig(label) { $0.ignoreLink(key) }
    }

    func clearIgnoredLinks(label: String) async {
        await updateConfig(label) { $0.clearIgnoredLinks() }
    }

    /// subscription suggestions set aside
    var ignoredSubIDs: [String] {
        repoConfig?.subsIgnored ?? (settingsMigrated ? [] : Prefs.get(pk("sub.ignored"), [String]()))
    }

    func ignoreSubSuggestion(_ id: String, label: String) async {
        await updateConfig(label) { $0.ignoreSubSuggestion(id) }
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
            guard var op = await fileWriteOp(LedgerXConfig.path, text: c.json()) else { return }
            op.label = LS("把本机的设置移入 %@", LedgerXConfig.path)
            guard await commit([op], word: LS("设置已移入 %@，各设备共用", LedgerXConfig.path), checked: true) else { return }
        }
        if !myQueries.isEmpty { await moveLocalQueries() }
        Prefs.set(pk("config.migrated"), true)
    }
}

// MARK: 快速搜索 (明细)

extension Store {
    /// searches saved for 明细, in order
    var quickSearches: [QuickSearch] { repoConfig?.searches ?? [] }

    func saveQuickSearch(_ s: QuickSearch, replacing original: QuickSearch?, label: String) async {
        await updateConfig(label, word: LS("已更新快速搜索")) { $0.saveSearch(s, replacing: original) }
    }

    func removeQuickSearch(_ s: QuickSearch) async {
        await updateConfig(LS("删除快速搜索：%@", s.name), word: LS("已更新快速搜索")) { $0.removeSearch(s) }
    }

    func moveQuickSearch(_ s: QuickSearch, by d: Int) async {
        await updateConfig(LS("调整快速搜索顺序"), word: LS("已更新快速搜索")) { $0.moveSearch(s, by: d) }
    }
}
