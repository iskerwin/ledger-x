import Foundation
import SwiftUI
import LedgerKit

enum Tab: String, CaseIterable, Hashable {
    case add, overview, journal, accounts, reports
    var title: String {
        switch self {
        case .add: return LS("记一笔")
        case .overview: return LS("概览")
        case .journal: return LS("明细")
        case .accounts: return LS("账户")
        case .reports: return LS("报表")
        }
    }
    var symbol: String {
        switch self {
        case .add: return "plus.circle.fill"
        case .overview: return "chart.bar.xaxis"
        case .journal: return "list.bullet.rectangle.portrait"
        case .accounts: return "building.columns"
        case .reports: return "doc.text.magnifyingglass"
        }
    }
}
enum SyncState { case idle, syncing, offline, error }

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var action: String?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

enum Prefs {
    static let d = UserDefaults.standard
    static func get<T: Decodable>(_ k: String, _ def: T) -> T {
        guard let data = d.data(forKey: "ledger." + k), let v = try? JSONDecoder().decode(T.self, from: data) else { return def }
        return v
    }
    static func set<T: Encodable>(_ k: String, _ v: T) {
        if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: "ledger." + k) }
    }
}

@MainActor
final class DraftModel: ObservableObject {
    @Published var draft = Draft() {
        didSet { if draft.funding != oldValue.funding { fundingChanged?() } }
    }
    /// told when the paying account changes, however it is changed (pickers bind to the draft directly)
    var fundingChanged: (() -> Void)?
}

@MainActor
final class Store: ObservableObject {
    @Published var cfg: RepoConfig
    /// every ledger set up on this phone (tokens stripped; they live in the Keychain)
    @Published private(set) var sources: [RepoConfig]
    @Published private(set) var L: Ledger?
    @Published private(set) var D: Derived?
    @Published private(set) var version = 0
    @Published var pending: [Op]
    @Published var syncState: SyncState = .idle
    @Published var syncError = ""
    @Published var demoBusy = false
    /// a newer commit of ledger-demo than the demo on this phone (offered in its banner)
    @Published var demoUpdate: String?
    @Published var lastSync: Date?
    @Published var ci: GitHub.CI?
    @Published private(set) var tree: RepoTree?
    @Published var loadError: String?
    @Published var building = false

    /// the entry form lives in its own object so typing only redraws the 记一笔 page
    let drafts = DraftModel()
    var draft: Draft {
        get { drafts.draft }
        set { drafts.draft = newValue }
    }
    @Published var tab: Tab = .overview
    /// the 记一笔 card is open (it opens over any tab: the + tab, ledgerx://add, Shortcuts, 再记一笔…)
    @Published var adding = false
    /// 截图记账: what was just read off a screenshot (shown until closed)
    @Published var scanResult: ScanResult?
    /// 截图记账: the card was filled in from a screenshot; what to check, and what to remember on saving
    @Published var scanInfo: ScanInfo?
    /// the card opens on the full form (分录, 文本, 退款, AA…) instead of the quick one
    var addFull = false
    /// bumped by every request to open the card, so an open card goes back to the page asked for
    @Published var addToken = 0
    /// icons, names, order and hidden groups of the 记一笔 category grid (kept on this phone, not in the ledger)
    @Published var catStyle: CatStyle { didSet { Prefs.set("catStyle", catStyle) } }
    /// 币种与换算: which currencies the reports, overview and accounts show, and how they are valued (this phone)
    @Published var cview: CurrencyView { didSet { Prefs.set("currencyView", cview) } }
    @Published var showSettings = false
    /// 账本同步, opened from the status icon
    @Published var showSync = false
    /// the card bill being repaid: the sheet lives at the root, so a List section can't present it twice
    @Published var repaying: CardCycle?
    /// open 账本检查 on the overview tab (from Settings)
    @Published var openCheck = false
    /// 设置 → 账本检查: open the check once the settings sheet has gone
    var openCheckAfterSettings = false
    @Published var toast: Toast?
    /// bumped to pop every tab back to its root (after an edit or delete)
    @Published var popToken = 0
    /// account filter handed to the journal tab
    @Published var journalAccount: String?
    /// a search to open 明细 on (from another page): taken by the journal and cleared
    @Published var journalQuery: String?
    var toastAction: (() async -> Void)?
    /// a regular payment offered as a subscription after saving it
    @Published var subSuggestion: SubCandidate?

    // 常用交易 pinned / hidden, 记账偏好 defaults: in ledger-x.json (see Shared.swift); these are the values kept on
    // this phone before, read until they are moved there
    var localTplPinned: [String] { Prefs.get("tplPinned", [String]()) }
    var localTplHidden: [String] { Prefs.get("tplHidden", [String]()) }
    var localDefaultFunding: String? { Prefs.get("defaultFunding", String?.none) }
    var localDefaultCurrency: String? { Prefs.get("defaultCurrency", String?.none) }
    /// changes made from this device, newest first, so they can be taken back
    @Published private(set) var history: [ChangeRecord] = []
    @Published var explicitAmounts: Bool { didSet { Prefs.set("explicit", explicitAmounts) } }

    /// repository layout (settings; empty = detect from the ledger)
    @Published var mainFile: String { didSet { Prefs.set(pk("mainFile"), mainFile) } }
    @Published var journalPattern: String { didSet { Prefs.set(pk("journalPattern"), journalPattern) } }
    @Published var receivableAccount: String { didSet { Prefs.set(pk("receivable"), receivableAccount) } }
    @Published var subsFile: String { didSet { Prefs.set(pk("subsFile"), subsFile) } }
    @Published private(set) var detectedLayout = RepoLayout()
    /// ledger-x.json in the repository (shared by every device); nil = not there yet
    @Published private(set) var repoConfig: LedgerXConfig? { didSet { LinkNaming.overrides = repoConfig?.slugs ?? [:] } }

    /// BQL: queries saved on this phone, and the ones in the ledger (query directives, *.bql files)
    @Published var myQueries: [SavedQuery] { didSet { Prefs.set("queries", myQueries) } }
    @Published private(set) var ledgerQueries: [SavedQuery] = []
    /// ledger-x.json's, else the one set on this phone when connecting, else main.bean
    var main: String {
        if let m = repoConfig?.main?.trimmed, !m.isEmpty { return m }
        return mainFile.trimmed.isEmpty ? "main.bean" : mainFile.trimmed
    }
    var receivable: String {
        if let r = repoConfig?.receivable?.trimmed, !r.isEmpty { return r }
        return receivableAccount.trimmed.isEmpty ? "Assets:Receivable:Reimbursement" : receivableAccount.trimmed
    }
    /// ledger-x.json first, then the older settings on this phone, then what the ledger looks like
    var layout: RepoLayout {
        let c = repoConfig ?? LedgerXConfig()
        let journal = c.file(.transactions) ?? (journalPattern.trimmed.isEmpty ? detectedLayout.journal : journalPattern.trimmed)
        let subs = c.file(.subscriptions) ?? (subsFile.trimmed.isEmpty ? nil : subsFile.trimmed)
        var l = RepoLayout(main: main, journal: journal, subscriptions: subs)
        for k in LayoutKind.allCases { if let f = c.file(k) { l.files[k] = f } }
        l.rules = c.rules
        return l
    }
    /// the settings ledger-x.json would hold right now (the file's, or this phone's older ones)
    var effectiveConfig: LedgerXConfig {
        if let c = repoConfig { return c }
        var c = LedgerXConfig()
        if !journalPattern.trimmed.isEmpty { c.files[LayoutKind.transactions.rawValue] = journalPattern.trimmed }
        if !subsFile.trimmed.isEmpty { c.files[LayoutKind.subscriptions.rawValue] = subsFile.trimmed }
        if !receivableAccount.trimmed.isEmpty { c.receivable = receivableAccount.trimmed }
        return c
    }

    /// write ledger-x.json (one commit), then reload with it
    func saveRepoConfig(_ c: LedgerXConfig) async -> Bool {
        var op = await fileWriteOp(LedgerXConfig.path, text: c.json())
        op.label = LS("更新仓库结构（%@）", LedgerXConfig.path)
        return await commit([op], word: LS("已保存到 %@", LedgerXConfig.path), checked: true)
    }
    /// the ledger-x.json change in progress: the next one waits for it (see updateConfig)
    var configUpdate: Task<Bool, Never>?
    /// the push in progress, for others to wait on
    private var pushTask: Task<Void, Error>?
    /// bumped by every rebuild; a rebuild that finishes after a newer one started is dropped
    private var rebuildGen = 0
    private var tplCache: [Template]?

    /// per-ledger settings key ("tree", "tree@<id>", …); the first ledger keeps the original keys
    static func key(_ k: String, _ id: String) -> String { id == "default" ? k : k + "@" + id }
    func pk(_ k: String) -> String { Store.key(k, cfg.id) }

    /// the one store, shared by the app and its Shortcuts actions
    static let shared = Store()

    init() {
        // a card filled in from a screenshot follows the paying account: its rate and amount charged go on
        // when a foreign card is picked, and come off again for an account in the bill's currency
        defer { drafts.fundingChanged = { [weak self] in self?.scanFundingChanged() } }
        var list: [RepoConfig] = Prefs.get("sources", [RepoConfig]())
        if list.isEmpty {
            let old: RepoConfig = Prefs.get("cfg", RepoConfig())
            if !old.owner.isEmpty || !old.repo.isEmpty { list = [old] }
        }
        for i in list.indices { list[i].token = Keychain.load(account: list[i].keychainAccount) ?? "" }
        let active: String = Prefs.get("activeSource", "default")
        let c = list.first { $0.id == active } ?? list.first ?? RepoConfig()
        sources = list
        cfg = c
        let id = c.id
        pending = Prefs.get(Store.key("pending", id), [Op]())
        tree = Prefs.get(Store.key("tree", id), RepoTree?.none)
        lastSync = Prefs.get(Store.key("lastSync", id), Date?.none)
        ci = Prefs.get(Store.key("ci", id), GitHub.CI?.none)
        history = Prefs.get(Store.key("history", id), [ChangeRecord]())
        explicitAmounts = Prefs.get("explicit", true)
        mainFile = Prefs.get(Store.key("mainFile", id), "")
        journalPattern = Prefs.get(Store.key("journalPattern", id), "")
        receivableAccount = Prefs.get(Store.key("receivable", id), "")
        subsFile = Prefs.get(Store.key("subsFile", id), "")
        myQueries = Prefs.get("queries", [SavedQuery]())
        catStyle = Prefs.get("catStyle", CatStyle()).normalized()
        cview = Prefs.get("currencyView", CurrencyView())
    }

    var backend: LedgerBackend { makeBackend(cfg) }
    var connected: Bool { cfg.isComplete }

    private func persistSources() {
        Prefs.set("sources", sources.map { s -> RepoConfig in var x = s; x.token = ""; return x })
    }

    /// add or update a ledger in the list (token to the Keychain)
    func saveSource(_ c: RepoConfig) {
        Keychain.save(c.token, account: c.keychainAccount)
        if let i = sources.firstIndex(where: { $0.id == c.id }) { sources[i] = c } else { sources.append(c) }
        persistSources()
    }

    /// save the connection settings of a ledger and make it the active one
    func saveConfig(_ c: RepoConfig) async {
        let same = c.id == cfg.id
        let changedRepo = !same || c.kind != cfg.kind || c.owner != cfg.owner || c.repo != cfg.repo || c.branch != cfg.branch
            || c.server != cfg.server || c.bookmark != cfg.bookmark
        saveSource(c)
        if !same {
            await waitForPush()
            switchLedgerState(c)
            return
        }
        cfg = c
        Prefs.set("activeSource", c.id)
        if changedRepo {
            tree = nil; L = nil; D = nil
            Prefs.set(pk("tree"), RepoTree?.none)
        }
    }

    /// switch to another ledger: its own cached files, queue and settings
    private func switchLedgerState(_ c: RepoConfig) {
        cfg = c
        Prefs.set("activeSource", c.id)
        L = nil; D = nil; ci = nil; ledgerQueries = []; loadError = nil
        pending = Prefs.get(pk("pending"), [Op]())
        history = Prefs.get(pk("history"), [ChangeRecord]())
        tree = Prefs.get(pk("tree"), RepoTree?.none)
        lastSync = Prefs.get(pk("lastSync"), Date?.none)
        ci = Prefs.get(pk("ci"), GitHub.CI?.none)
        repoConfig = nil
        mainFile = Prefs.get(pk("mainFile"), "")
        journalPattern = Prefs.get(pk("journalPattern"), "")
        receivableAccount = Prefs.get(pk("receivable"), "")
        subsFile = Prefs.get(pk("subsFile"), "")
        tplCache = nil
        draft = Draft()
        toast = nil
        toastAction = nil
        rebuildGen += 1     // drop a rebuild of the previous ledger still in flight
        building = false
        popToken += 1
    }

    func switchLedger(_ id: String) async {
        guard id != cfg.id, let c = sources.first(where: { $0.id == id }) else { return }
        await waitForPush()
        switchLedgerState(c)
        if tree != nil { await rebuild(quietly: true) }
        await refresh()
    }

    func removeLedger(_ id: String) {
        guard id != cfg.id else { return }
        sources.removeAll { $0.id == id }
        persistSources()
        Keychain.save("", account: id == "default" ? "token" : "token." + id)
        // everything kept per ledger on this phone (see pk(_:))
        for k in ["pending", "tree", "lastSync", "ci", "history", "mainFile", "journalPattern", "receivable", "subsFile",
                  "sub.ignored", "link.ignored", "remind.cards", "alerts.dismissed", "alerts.seen", "backup.last", "config.migrated"] {
            UserDefaults.standard.removeObject(forKey: "ledger." + Store.key(k, id))
        }
        UserDefaults.standard.removeObject(forKey: PriceFetch.lastKey + "@" + id)
    }

    private func saveTree() { Prefs.set(pk("tree"), tree) }
    /// forget the cached files of this ledger (they are read again on the next refresh)
    func forgetTree() { tree = nil; saveTree() }
    func savePending() { Prefs.set(pk("pending"), pending) }
    private func saveHistory() { Prefs.set(pk("history"), history) }

    // MARK: - boot / refresh

    func start() async {
        if let dir = ProcessInfo.processInfo.environment["LEDGER_DEMO"] {
            await loadDemo(dir)
            return
        }
        if tree != nil && L == nil { await rebuild(quietly: true) }
        await refresh()
    }

    /// screenshots on CI: read a ledger from a local folder, never touch GitHub
    private(set) var demo = false
    /// the folder the screenshots' ledger is read from
    private var demoDir: URL?
    var demoEnv: [String: String] { demo ? ProcessInfo.processInfo.environment : [:] }
    private func loadDemo(_ dir: String) async {
        demo = true
        cfg = RepoConfig(owner: "demo", repo: "ledger", branch: "main", token: "demo")
        let env = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: dir)
        demoDir = base
        let result: (Ledger, Derived) = await Task.detached {
            let extra = env["LEDGER_EXTRA"]
            let list = { (try? FileManager.default.subpathsOfDirectory(atPath: base.path)) ?? [] }
            let L = loadLedger(root: "main.bean", listFiles: list) { path in
                if path == "__extra.bean", let x = extra { return try String(contentsOf: URL(fileURLWithPath: x), encoding: .utf8) }
                let t = try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
                return path == "main.bean" && extra != nil ? t + "\ninclude \"__extra.bean\"\n" : t
            }
            return (L, Derived(L))
        }.value
        detectedLayout = RepoLayout.detect(result.0)
        repoConfig = (try? String(contentsOf: base.appendingPathComponent(LedgerXConfig.path), encoding: .utf8)).flatMap(LedgerXConfig.parse)
        L = result.0
        D = result.1
        version += 1
        afterLoad()
        draft = newDraft(.expense, result.1, defaultFunding: nil)
        if env["LEDGER_REVIEW"] != nil {
            // the pre-commit check: an expense the bank account can't cover, dated before its last assertion
            let before = result.0
            let acct = "Assets:Bank:CGB"
            let date = before.balances.last { $0.account == acct }.map { Day.shift($0.date, -3) } ?? Day.today()
            let txn = "\n\(date) * \"Apple\" \"MacBook Pro\"\n  Expenses:Shopping  250000.00 CNY\n  \(acct)\n"
            let issues: [ChangeIssue] = await Task.detached {
                let after = loadLedger(root: "main.bean") { path in
                    let t = try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8)
                    return path == "main.bean" ? t + txn : t
                }
                return reviewChange(before: before, after: after)
            }.value
            Task { try? await Task.sleep(nanoseconds: 800_000_000); _ = await ChangeReview.ask(issues) }
        }
        if let k = env["LEDGER_KIND"], let kind = DraftKind(rawValue: k) {
            draft = newDraft(kind, result.1, defaultFunding: nil)
            if kind == .multi, let t = result.0.txns.last(where: { isComplex($0) }) { draft = multiDraftFromTxn(t, result.1, defaultFunding: nil) }
            if kind == .transfer { draft.amount = "2000"; draft.to = result.1.rankAccounts(["Assets:"]).dropFirst().first ?? "" }
            if kind == .refund, let t = result.0.txns.last(where: { classify($0, result.0).kind == .expense }) {
                draft = refundDraft(t, result.0, result.1, defaultFunding: nil)
            }
        }
        if env["LEDGER_FILL"] != nil, let t = templateList.first(where: { $0.kind == .expense && $0.fixed != nil }) {
            draft.payee = t.payee; draft.narration = t.narration; draft.account = t.account; draft.funding = t.funding
            draft.amount = t.fixed.map { jsNumberString($0) } ?? "23.5"
        }
        if env["LEDGER_COMBO"] != nil, let other = result.1.rankAccounts(["Assets:", "Liabilities:"]).first(where: { $0 != draft.funding && !$0.hasPrefix("Assets:Receivable") && (result.1.acctCcy[$0] ?? draft.currency) == draft.currency }) {
            draft.extraFunds = [ExtraFund(account: other, amount: "1000")]
            draft.discount = "50"
        }
        if env["LEDGER_TAB"] == "add" {
            openAdd(full: env["LEDGER_EDIT_TEXT"] != nil || env["LEDGER_ADD_FULL"] != nil ? true : nil)
        } else if let t = env["LEDGER_TAB"], let tab = Tab(rawValue: t) { self.tab = tab }
        if env["LEDGER_TAB"] == "settings" { tab = .overview; showSettings = true }
        if env["LEDGER_SYNC"] != nil { showSync = true }
        var qs: [SavedQuery] = []
        if let names = try? FileManager.default.subpathsOfDirectory(atPath: dir) {
            for n in names.sorted() where n.hasSuffix(".bql") {
                if let t = try? String(contentsOf: base.appendingPathComponent(n), encoding: .utf8) { qs += parseBQLFile(t, file: n) }
            }
        }
        ledgerQueries = Self.directiveQueries(result.0) + qs
        AppSettings.shared.privacy = env["LEDGER_PRIVACY"] != nil
        AppSettings.shared.theme = env["LEDGER_THEME"] ?? "jade"
        AppSettings.shared.language = env["LEDGER_LANG"] ?? "zh"
        if let a = env["LEDGER_ACCOUNT"] { journalAccount = a }
        // 币种与换算 for the screenshots
        var cv = CurrencyView()
        cv.modeRaw = env["LEDGER_CURRENCY_MODE"]
        if let only = env["LEDGER_CURRENCIES"]?.split(separator: ",").map(String.init) {
            cv.off = Set(ledgerCurrencies(result.0)).subtracting(only)
            cv.on = Set(only)
        }
        cview = cv
        // the journal's month calendar opened (the setting is remembered between launches, so it is set either way)
        UserDefaults.standard.set(env["LEDGER_CALENDAR"] != nil, forKey: "ledger.journal.calendar")
        lastSync = Date()
    }

    func refresh() async {
        guard connected, !demo else { return }
        syncState = .syncing
        do {
            let t = try await backend.fetchTree()
            let changed = tree == nil || t.sha != tree!.sha
            tree = t
            saveTree()
            var pushed = false
            if pending.contains(where: { $0.failed == nil }) { try await pushPending(); pushed = true }
            if changed || pushed || L == nil { await rebuild() }
            ci = await backend.check()
            Prefs.set(pk("ci"), ci)
            pruneCache()
            syncState = .idle
            syncError = ""
            lastSync = Date()
            Prefs.set(pk("lastSync"), lastSync)
        } catch {
            fail(error)
            if L == nil && tree != nil { await rebuild(quietly: true) }
        }
    }

    /// once a day, after a successful sync: drop cached file versions no ledger on this phone uses any more
    private func pruneCache() {
        let k = "ledger.cache.pruned"
        guard UserDefaults.standard.string(forKey: k) != Day.today() else { return }
        var keep = Set(tree?.files.values.map { $0 } ?? [])
        for s in sources where s.id != cfg.id {
            let t: RepoTree? = Prefs.get(Store.key("tree", s.id), RepoTree?.none)
            keep.formUnion(t?.files.values.map { $0 } ?? [])
        }
        guard !keep.isEmpty else { return }
        BlobCache.prune(keep: keep)
        UserDefaults.standard.set(Day.today(), forKey: k)
    }

    private func fail(_ error: Error) {
        let ns = error as NSError
        syncState = ns.domain == NSURLErrorDomain ? .offline : .error
        syncError = error.localizedDescription
    }

    func syncNow() async {
        guard connected, !demo else { return }
        syncState = .syncing
        do {
            try await pushPending()
            await rebuild()
            syncState = .idle
            syncError = ""
            lastSync = Date()
            Prefs.set(pk("lastSync"), lastSync)
            ci = await backend.check()
        } catch { fail(error); Haptics.error() }
    }

    // MARK: - files

    private func blobText(_ path: String, _ sha: String) async throws -> String {
        if let t = BlobCache.get(sha) { return t }
        let t = try await backend.read(path, version: sha)
        BlobCache.set(sha, t)
        return t
    }

    /// download every .bean file not cached yet
    private func ensureBlobs() async throws {
        guard let tree = tree else { return }
        let missing = tree.files.filter { isLedgerFile($0.key) && BlobCache.get($0.value) == nil }.map { ($0.key, $0.value) }
        if missing.isEmpty { return }
        let api = backend
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            for (path, sha) in missing { group.addTask { (sha, try await api.read(path, version: sha)) } }
            for try await (sha, text) in group { BlobCache.set(sha, text) }
        }
    }

    /// an op writing the whole of `path`, remembering the text it replaces: if another device changes the file
    /// before this one is pushed, the push merges (ledger-x.json) or parks it instead of overwriting their change
    func fileWriteOp(_ path: String, text: String) async -> Op {
        var op = Op(kind: .write, path: path)
        op.text = text
        op.old = try? await fileText(path)
        return op
    }

    /// file text with the pending queue applied
    func fileText(_ path: String) async throws -> String {
        var base = ""
        if let sha = tree?.files[path] { base = try await blobText(path, sha) }
        // screenshots: the files of the local folder (there is no tree)
        else if let dir = demoDir { base = (try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)) ?? "" }
        return try applyOps(base, path: path, ops: pending)
    }

    func rebuild(quietly: Bool = false) async {
        guard let tree = tree else { return }
        rebuildGen += 1
        let gen = rebuildGen
        building = true
        defer { if gen == rebuildGen { building = false } }
        do { try await ensureBlobs() } catch { if !quietly { fail(error) } }
        guard gen == rebuildGen else { return }
        let files = tree.files
        let ops = pending
        // ledger-x.json first: it may name the main file
        repoConfig = Self.readConfig(files: files, ops: ops)
        let main = self.main
        let receivable = self.receivable
        let result: (Ledger, Derived)? = await Task.detached(priority: .userInitiated) {
            let L = Store.loadWith(files: files, main: main, ops: ops)
            if L.txns.isEmpty && L.files.isEmpty { return nil }
            return (L, Derived(L, receivable: receivable))
        }.value
        // a newer rebuild started (another commit, or the ledger was switched): its result wins
        guard gen == rebuildGen else { return }
        if let r = result {
            detectedLayout = RepoLayout.detect(r.0, main: main)
            L = r.0
            D = r.1
            tplCache = nil
            var qs = Self.directiveQueries(r.0)
            let bql = Set(files.keys.filter { $0.hasSuffix(".bql") }).union(ops.map { $0.path }.filter { $0.hasSuffix(".bql") })
            for path in bql.sorted() {
                let base = files[path].flatMap { BlobCache.get($0) } ?? ""
                if let t = try? applyOps(base, path: path, ops: ops) { qs += parseBQLFile(t, file: path) }
            }
            ledgerQueries = qs
            loadError = nil
            version += 1
            afterLoad()
            if !demo { Task { await migrateLocalSettings() } }
            if draft.funding.isEmpty { draft = newDraft(.expense, r.1, defaultFunding: defaultFunding, defaultCurrency: defaultCurrency) }
        } else {
            loadError = LS("无法读取 %@", main)
        }
    }

    /// ledger-x.json from the downloaded files, with queued changes applied
    static func readConfig(files: [String: String], ops: [Op]) -> LedgerXConfig? {
        let path = LedgerXConfig.path
        let base = files[path].flatMap { BlobCache.get($0) }
        guard base != nil || ops.contains(where: { $0.path == path }) else { return nil }
        guard let text = try? applyOps(base ?? "", path: path, ops: ops), !text.trimmed.isEmpty else { return nil }
        return LedgerXConfig.parse(text)
    }

    nonisolated static func loadWith(files: [String: String], main: String, ops: [Op]) -> Ledger {
        // every file in the repository, new ones from the queue too, for include "…/*.bean"
        let all = { Array(Set(files.keys).union(ops.filter { $0.kind == .insert || $0.kind == .write }.map { $0.path })) }
        return loadLedger(root: main, listFiles: all) { path in
            var text = ""
            if let sha = files[path] {
                guard let t = BlobCache.get(sha) else { throw GitHubError(status: 0, message: LS("离线状态：%@ 尚未下载", path)) }
                text = t
            } else if path == main { throw GitHubError(status: 404, message: LS("仓库中未找到 %@", main)) }
            return try applyOps(text, path: path, ops: ops)
        }
    }

    // MARK: - pre-commit check

    /// build the ledger with `ops` applied and ask the user about anything the change would break.
    /// Returns the ops to commit (marked `held` when kept on this device), or nil to go back and edit.
    func review(_ ops: [Op]) async -> [Op]? {
        // held changes that pass together with this one go out with it, in the same commit
        let heldGroups = Set(pending.compactMap { $0.held != nil ? $0.heldGroup : nil })
        if !heldGroups.isEmpty, await issues(for: pending.filter { $0.held != nil } + ops).isEmpty {
            var out = ops
            if !out.isEmpty { out[0].releases = Array(heldGroups) }
            return out
        }
        let issues = await issues(for: ops)
        if issues.isEmpty { return ops }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        switch await ChangeReview.ask(issues) {
        case .edit: return nil
        case .force: return ops
        case .hold:
            let why = LS("已暂存在本机：") + (issues.first?.title ?? "")
            let group = UUID()
            return ops.map { var o = $0; o.held = why; o.heldGroup = group; return o }
        }
    }

    /// What the pre-commit check finds for `ops`, without asking anything. It compares the ledger as it
    /// will be on the server — pushable queue only, held and failed items left out — before and after.
    func issues(for ops: [Op]) async -> [ChangeIssue] {
        guard let tree = tree, !ops.isEmpty else { return [] }
        // renaming an account changes every key the check compares; nothing to learn from it
        if ops.allSatisfy({ $0.kind == .rename }) { return [] }
        let files = tree.files, main = self.main
        let base = pending.filter { $0.failed == nil && $0.held == nil }
        let mine = Set(ops.map { $0.id })
        let after = base.filter { !mine.contains($0.id) } + ops.map { var o = $0; o.held = nil; return o }
        return await Task.detached(priority: .userInitiated) {
            let b = Store.loadWith(files: files, main: main, ops: base)
            let a = Store.loadWith(files: files, main: main, ops: after)
            if a.txns.isEmpty && a.files.isEmpty { return [] }
            return reviewChange(before: b, after: a)
        }.value
    }

    /// load the ledger if it isn't yet (Shortcuts run the app in the background)
    func ensureLoaded() async {
        if L != nil { return }
        if tree != nil { await rebuild(quietly: true) }
        if L == nil { await refresh() }
    }

    /// push items that were kept on this device (checked again first: if they still break something, ask)
    func release(_ op: Op) async {
        let group = pending.filter { $0.held != nil && ($0.id == op.id || (op.heldGroup != nil && $0.heldGroup == op.heldGroup)) }
        let issues = await issues(for: group)
        if !issues.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            guard await ChangeReview.ask(issues) == .force else { return }
        }
        let ids = Set(group.map { $0.id })
        for i in pending.indices where ids.contains(pending[i].id) {
            pending[i].held = nil
            pending[i].heldGroup = nil
        }
        savePending()
        await rebuild()
        await syncNow()
    }

    // MARK: - queue

    /// queue operations, rebuild locally, then push
    @discardableResult
    func commit(_ ops0: [Op], word: String = LS("已入账"), undo: (() async -> Void)? = nil, checked: Bool = false) async -> Bool {
        var ops = ops0
        if !checked {
            guard let r = await review(ops) else { return false }
            ops = r
        }
        // new charges of a subscription get its link
        let (linked, subNames) = autoLinkSubscriptions(ops)
        ops = linked
        // editing or deleting something that is still held on this device stays with it
        for i in ops.indices where ops[i].held == nil && (ops[i].kind == .remove || ops[i].kind == .replace) {
            let old = (ops[i].old ?? "").trimmed
            if let h = pending.first(where: { $0.held != nil && $0.path == ops[i].path && !old.isEmpty && ($0.text ?? "").trimmed == old }) {
                ops[i].held = h.held
                ops[i].heldGroup = h.heldGroup
                if i + 1 < ops.count, ops[i + 1].silent == true { ops[i + 1].held = h.held; ops[i + 1].heldGroup = h.heldGroup }
            }
        }
        // held changes that pass together with this one: release them so everything goes in one commit
        let releases = Set(ops.flatMap { $0.releases ?? [] })
        var released = 0
        if !releases.isEmpty {
            for i in pending.indices where pending[i].heldGroup.map(releases.contains) == true {
                pending[i].held = nil; pending[i].heldGroup = nil; released += 1
            }
            for i in ops.indices { ops[i].releases = nil; if ops[i].heldGroup.map(releases.contains) == true { ops[i].held = nil; ops[i].heldGroup = nil } }
        }
        let held = ops.contains { $0.held != nil }
        // what it takes to undo this, worked out against the files as they are before it
        let record = held ? nil : await changeRecord(ops)
        noteMoved(ops)
        pending.append(contentsOf: ops)
        savePending()
        if let r = record {
            history.insert(r, at: 0)
            if history.count > 100 { history.removeLast(history.count - 100) }
            saveHistory()
        }
        if held {
            show(LS("已暂存在本机，未推送"))
            await rebuild()
            Haptics.selection()
            return true
        }
        var shown = subNames.isEmpty ? word : word + LS(" · 已关联到 %@", subNames.first ?? "")
        if released > 0 { shown = LS("检查通过，暂存的修改已一并推送") }
        if let undo = undo { show(shown, action: LS("撤销"), undo) }
        else if let r = record { show(shown, action: LS("撤销")) { [weak self] in _ = await self?.revert(r.id) } }
        else { show(shown) }
        Haptics.success()
        let shownID = toast?.id
        await rebuild()
        // the balances of the accounts the change touched, to compare with the bank app at a glance
        if let note = balanceNote(ops), let t = toast, t.id == shownID { toast?.text = t.text + "\n" + note }
        if subNames.isEmpty { suggestSubscription(after: ops) }
        await syncNow()
        return true
    }

    /// wait for a push in progress (switching ledgers mid-push would file its results under the wrong ledger)
    func waitForPush() async {
        while let t = pushTask { _ = try? await t.value; if pushTask == t { break } }
    }

    /// check first, then close the form (`close`), then commit: "go back and edit" keeps the form open
    @discardableResult
    func commit(_ ops: [Op], word: String, closing close: () -> Void) async -> Bool {
        guard let r = await review(ops) else { return false }
        close()
        return await commit(r, word: word, checked: true)
    }

    func pushPending() async throws {
        // a push already running may have missed ops queued since; wait for it, then push again
        await waitForPush()
        if pushTask != nil { return }   // someone else started the next one meanwhile
        let t = Task { try await self.pushWithRetry() }
        pushTask = t
        defer { pushTask = nil }
        try await t.value
    }

    private func pushWithRetry() async throws {
        for attempt in 0..<2 {
            do {
                try await pushOnce()
                break
            } catch let e as GitHubError where (e.status == 409 || e.status == 412 || e.status == 422) && attempt == 0 {
                tree = try await backend.fetchTree()
                saveTree()
            }
        }
    }

    /// push everything that can go, as ONE commit (one per host request where the host can't),
    /// so bean-check on the server never sees half of a change
    private func pushOnce() async throws {
        for _ in 0..<3 {   // repeat for ops queued while pushing
            let ops = pending.filter { $0.failed == nil && $0.held == nil }
            if ops.isEmpty { return }
            // every touched file as it is on the server now (nil: not there)
            var bases: [String: String?] = [:]
            for o in ops where bases[o.path] == nil {
                if let sha = tree?.files[o.path] { bases[o.path] = .some(try await blobText(o.path, sha)) }
                else { bases[o.path] = .some(nil) }
            }
            let plan = planPush(ops, bases: bases)
            for (id, why) in plan.failed { markFailed(id, why) }
            savePending()
            if plan.changes.isEmpty {
                // nothing left to write: the edits that were no-ops leave the queue
                let ids = Set(plan.included)
                pending.removeAll { ids.contains($0.id) }
                savePending()
                return
            }
            let included = pending.filter { plan.included.contains($0.id) }
            let paths = plan.changes.map { $0.path }
            let message = commitMessage(included, path: paths.count == 1 ? paths[0] : LS("%@ 个文件", paths.count))
            let changes = plan.changes.map { FileChange(path: $0.path, text: $0.text, version: tree?.files[$0.path]) }
            let versions: [String: String]
            do {
                versions = try await backend.writeMany(changes, message: message)
            } catch let e as PartialWriteError {
                // the files already written take their edits out of the queue; the rest stay and are retried
                for (path, v) in e.written {
                    if let v = v, let t = plan.changes.first(where: { $0.path == path })?.text { BlobCache.set(v, t) }
                    tree?.files[path] = v
                }
                let done = Set(e.written.keys)
                let ids = Set(included.filter { done.contains($0.path) }.map { $0.id })
                pending.removeAll { ids.contains($0.id) }
                savePending()
                saveTree()
                throw e.underlying
            }
            for c in plan.changes {
                if let t = c.text, let v = versions[c.path] {
                    BlobCache.set(v, t)
                    tree?.files[c.path] = v
                } else if c.text == nil {
                    tree?.files[c.path] = nil
                }
            }
            let ids = Set(plan.included)
            pending.removeAll { ids.contains($0.id) }
            savePending()
            tree = try await backend.fetchTree()
            saveTree()
        }
    }

    private func markFailed(_ id: UUID, _ why: String) {
        if let i = pending.firstIndex(where: { $0.id == id }) { pending[i].failed = why }
    }

    func dropPending(_ op: Op) async {
        pending.removeAll { $0.id == op.id }
        savePending()
        await rebuild()
    }

    // MARK: - after every load: reminders and prices

    func afterLoad() {
        Task {
            await Reminders.reschedule(self)
            await autoUpdatePrices()
            await Backup.runIfDue(self)
        }
    }

    // MARK: - helpers for views

    static func directiveQueries(_ L: Ledger) -> [SavedQuery] {
        L.entries.filter { $0.type == .query }.compactMap { e in
            guard let q = e.query, !q.trimmed.isEmpty else { return nil }
            return SavedQuery(id: "query:" + (e.name ?? q), name: e.name ?? "query", text: q.trimmed, source: "ledger")
        }
    }

    /// Remove one complete assertion, including metadata, from the current pending file text.
    func balanceRemoveOp(_ e: Entry) async -> Op? {
        guard let account = e.account, let old = await entryText(e) else { return nil }
        var op = Op(kind: .remove, path: e.file)
        op.old = old
        op.date = e.date
        op.account = account
        op.currency = e.currency
        op.label = LS("删除余额断言：%@ %@", account, e.date)
        op.summary = LS("删除余额断言 %@", account)
        return op
    }

    func deleteBalance(_ e: Entry) async {
        guard let op = await balanceRemoveOp(e) else { show(LS("未在 %@ 中找到该断言", e.file)); return }
        await commit([op], word: LS("已删除余额断言"))
    }

    // MARK: - saved queries live in the ledger (queries/custom.bql), so every device has them

    static let customQueries = "queries/custom.bql"

    /// a query that can be changed: one from a .bql file in the repository
    func isEditableQuery(_ q: SavedQuery) -> Bool { q.source == "mine" || bqlLocation(q.id) != nil }

    private func bqlQueries(_ path: String) async -> [SavedQuery] {
        parseBQLFile((try? await fileText(path)) ?? "", file: path)
    }

    private func writeBQL(_ path: String, _ qs: [SavedQuery], label: String, word: String) async -> Bool {
        var op = await fileWriteOp(path, text: serializeBQL(qs))
        op.label = label
        return await commit([op], word: word, checked: true)
    }

    /// save `q` under `name` with `text`: in its own .bql file if it came from one, else appended to
    /// queries/custom.bql. Returns the saved query (with its id in the file), nil when not saved.
    func saveQuery(_ q: SavedQuery, name: String, text: String, asNew: Bool) async -> SavedQuery? {
        let path: String, index: Int
        var qs: [SavedQuery]
        if !asNew, let loc = bqlLocation(q.id) {
            path = loc.path
            qs = await bqlQueries(path)
            guard loc.index < qs.count else { show(LS("查询已在别处被修改，请重新打开")); return nil }
            qs[loc.index].name = name; qs[loc.index].text = text
            index = loc.index
        } else {
            path = Store.customQueries
            qs = await bqlQueries(path)
            qs.append(SavedQuery(name: name, text: text, source: "ledger"))
            index = qs.count - 1
        }
        guard await writeBQL(path, qs, label: LS("保存查询：%@", name), word: LS("已保存「%@」", name)) else { return nil }
        if q.source == "mine" && !asNew { myQueries.removeAll { $0.id == q.id } }
        return SavedQuery(id: "file:\(path)#\(index)", name: name, text: text, source: "ledger")
    }

    func deleteQuery(_ q: SavedQuery) async {
        if q.source == "mine" { myQueries.removeAll { $0.id == q.id }; return }
        guard let loc = bqlLocation(q.id) else { return }
        var qs = await bqlQueries(loc.path)
        guard loc.index < qs.count else { return }
        let name = qs.remove(at: loc.index).name
        _ = await writeBQL(loc.path, qs, label: LS("删除查询：%@", name), word: LS("已删除「%@」", name))
    }

    /// queries kept on this phone from before: move them into queries/custom.bql (one commit)
    func moveLocalQueries() async {
        guard !myQueries.isEmpty else { return }
        var qs = await bqlQueries(Store.customQueries)
        qs += myQueries.map { SavedQuery(name: $0.name, text: $0.text, source: "ledger") }
        if await writeBQL(Store.customQueries, qs, label: LS("移入 %@ 条本机查询", myQueries.count), word: LS("已移到账本")) {
            myQueries = []
        }
    }

    // MARK: - events and unusual spending

    static let autoEventsKey = "ledger.events.auto"
    /// a single expense this large (base currency) is flagged; 0 = never (ledger-x.json)
    var largeExpense: Double { repoConfig?.largeExpense ?? (settingsMigrated ? 2000 : AppSettings.shared.largeExpense) }
    /// new entries get the tags of the events going on that day
    var autoEventTags: Bool { UserDefaults.standard.object(forKey: Store.autoEventsKey) as? Bool ?? true }
    private var anomalyCache: (version: Int, large: Double, day: String, list: [Anomaly])?
    /// bumped when an alert is dismissed, so views showing them refresh
    @Published private(set) var alertsVersion = 0

    /// alerts checked and found fine
    var confirmedAlertIDs: Set<String> {
        if let l = repoConfig?.alertsConfirmed { return Set(l) }
        return settingsMigrated ? [] : Prefs.get(pk("alerts.dismissed"), Set<String>())
    }

    /// what looks unusual in the last month, not checked yet
    var anomalyList: [Anomaly] {
        let ok = confirmedAlertIDs
        return allAnomalies.filter { !ok.contains($0.id) }
    }

    /// the ones checked and found fine (that would still come up)
    var confirmedAnomalies: [Anomaly] {
        let ok = confirmedAlertIDs
        return allAnomalies.filter { ok.contains($0.id) }
    }

    var allAnomalies: [Anomaly] {
        guard let L = L else { return [] }
        let today = Day.today(), large = largeExpense
        let all: [Anomaly]
        if let c = anomalyCache, c.version == version, c.large == large, c.day == today { all = c.list }
        else {
            all = anomalies(L, today: today, settings: AnomalySettings(large: large))
            anomalyCache = (version, large, today, all)
        }
        return all
    }

    /// checked: nothing wrong
    func confirmAlert(_ id: String) {
        // only the ones that can still come up are worth keeping
        let live = Set(anomalyCache?.list.map { $0.id } ?? [])
        alertsVersion += 1
        Task { await updateConfig(LS("核对无误")) { $0.confirmAlert(id, live: live) } }
    }

    /// alerts shown in the app aren't sent as a notification any more
    func markAlertsSeen() {
        Prefs.set(pk("alerts.seen"), Set(anomalyList.map { $0.id }).union(Prefs.get(pk("alerts.seen"), Set<String>())).filter { id in anomalyCache?.list.contains { $0.id == id } ?? true })
    }

    /// alerts not seen in the app yet
    var unseenAlerts: [Anomaly] {
        let seen = Prefs.get(pk("alerts.seen"), Set<String>())
        return anomalyList.filter { !seen.contains($0.id) }
    }

    /// back on the list to check
    func unconfirmAlert(_ id: String) {
        alertsVersion += 1
        Task { await updateConfig(LS("放回待核对")) { $0.unconfirmAlert(id) } }
    }

    /// the tags a new entry dated `date` gets on its own
    func autoEvents(on date: String) -> [String] {
        guard autoEventTags, let L = L else { return [] }
        return activeEvents(L, on: date).map { $0.tag }
    }

    var templateList: [Template] {
        if let c = tplCache { return c }
        guard let L = L else { return [] }
        let t = templates(L, pinned: tplPinned, hidden: Set(tplHidden))
        tplCache = t
        return t
    }

    func fileExists(_ path: String) -> Bool { tree?.files[path] != nil }

    func makeOps(_ text: String, extra: OpExtra = OpExtra(), single: Bool) -> [Op]? {
        guard let L = L else { return nil }
        let files = tree?.files ?? [:]
        switch LedgerKit.makeOps(text, L, layout: layout, pending: pending, fileExists: { files[$0] != nil }, extra: extra, single: single) {
        case .success(let ops): return ops
        case .failure(let e): show(e.message); return nil
        }
    }

    func show(_ text: String, action: String? = nil, _ fn: (() async -> Void)? = nil) {
        toastAction = fn
        toast = Toast(text: text, action: action)
    }

    func newDraftFor(_ kind: DraftKind) -> Draft {
        guard let D = D else { return Draft() }
        var d = newDraft(kind, D, defaultFunding: defaultFunding, defaultCurrency: defaultCurrency)
        if kind != .transfer && kind != .raw { d.events = autoEvents(on: d.date) }
        return d
    }

    /// currency for a new entry paid from / into `funding`
    func entryCurrency(_ kind: DraftKind, funding: String) -> String {
        if kind != .transfer && kind != .multi, let c = defaultCurrency { return c }
        return D?.acctCcy[funding] ?? defaultCurrency ?? L?.base ?? "CNY"
    }

    /// "中国银行 285.83 · 支付宝 5.93": balances of the asset / liability accounts that `ops` touch
    func balanceNote(_ ops: [Op]) -> String? {
        guard let L = L, let re = try? NSRegularExpression(pattern: "(?<![\\w:])(Assets|Liabilities):[\\p{L}\\p{N}:_-]+") else { return nil }
        var accts: [String] = []
        for o in ops where o.kind == .insert || o.kind == .replace || o.kind == .remove {
            for t in [o.text ?? "", o.old ?? ""] {
                let ns = t as NSString
                for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                    let a = ns.substring(with: m.range)
                    if L.accounts[a] != nil, !accts.contains(a) { accts.append(a) }
                }
            }
        }
        let parts: [String] = accts.prefix(3).compactMap { a in
            let cs = (L.final[a] ?? [:]).filter { abs($0.value) >= 0.005 }.sorted { $0.key < $1.key }
            let v = cs.isEmpty ? money(0, L.accounts[a]?.currencies.first ?? L.base) : cs.map { money($0.value, $0.key) }.joined(separator: " / ")
            return accountTitle(L, a) + " " + v
        }
        return parts.isEmpty ? nil : LS("余额：") + parts.joined(separator: " · ")
    }

    /// write the checked balances (one assertion per account, the day after its statement / check day)
    @discardableResult
    func reconcile(_ items: [(ReconcileDue, Double)]) async -> Bool {
        guard L != nil, !items.isEmpty else { return false }
        let text = items.map { balanceLine($0.0.date, $0.0.account, $0.1, $0.0.currency) }.joined(separator: "\n")
        guard var ops = makeOps(text, single: false) else { return false }
        if let i = ops.firstIndex(where: { $0.kind == .balance }) {
            ops[i].label = items.count == 1 ? LS("核对余额：%@ %@", items[0].0.account, items[0].0.day) : LS("核对 %@ 个账户的余额", items.count)
            for k in ops.indices where k != i { ops[k].silent = true }
        }
        return await commit(ops, word: LS("已写入余额断言"))
    }

    // MARK: - undo

    /// whether a file exists once the queue is applied
    private func existsLocally(_ path: String) -> Bool {
        var exists = tree?.files[path] != nil
        for o in pending where o.path == path && o.failed == nil { exists = o.kind != .deleteFile }
        return exists
    }

    /// the record of a change about to be queued: the ops that take each touched file back
    private func changeRecord(_ ops: [Op]) async -> ChangeRecord? {
        var paths: [String] = []
        for o in ops where !paths.contains(o.path) { paths.append(o.path) }
        var undo: [Op] = []
        for p in paths {
            var before: String?
            if existsLocally(p) {
                guard let t = try? await fileText(p) else { return nil }
                before = t
            }
            let after: String? = ops.contains { $0.path == p && $0.kind == .deleteFile } ? nil
                : (try? applyOps(before ?? "", path: p, ops: ops)) ?? before
            undo += revertOps(path: p, before: before, after: after)
        }
        if undo.isEmpty { return nil }
        let label = commitMessage(ops, path: paths.count == 1 ? paths[0] : LS("%@ 个文件", paths.count))
        return ChangeRecord(label: label, files: paths, undo: undo)
    }

    /// take back a change made from this device; refused when what it wrote has been edited since
    @discardableResult
    func revert(_ id: UUID) async -> Bool {
        guard let r = history.first(where: { $0.id == id }), r.undone == nil else { return false }
        var cur: [String: String] = [:]
        for p in Set(r.undo.map { $0.path }) where existsLocally(p) {
            guard let t = try? await fileText(p) else { show(LS("文件尚未下载，暂时无法撤回")); return false }
            cur[p] = t
        }
        switch undoOps(r, current: { cur[$0] }) {
        case .failure(.changedSince(let path)):
            show(LS("无法撤回：%@ 中的这部分内容之后又被修改过", path))
            return false
        case .success(var ops):
            if !ops.isEmpty {
                for k in ops.indices { ops[k].label = LS("撤回：%@", r.label); if k > 0 { ops[k].silent = true } }
                guard await commit(ops, word: LS("已撤回")) else { return false }
            }
            if let j = history.firstIndex(where: { $0.id == id }) { history[j].undone = Date(); saveHistory() }
            return true
        }
    }

    func githubURL(_ file: String, line: Int? = nil) -> URL? { backend.webURL(file, line: line) }

    func resetCache() async {
        BlobCache.clear()
        tree = nil
        saveTree()
        await refresh()
    }
}
