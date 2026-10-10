import Foundation
import SwiftUI
import LedgerKit

enum Tab: String, CaseIterable, Hashable {
    case add, overview, journal, accounts, reports
    var title: String {
        switch self {
        case .add: return LS("记账")
        case .overview: return LS("概览")
        case .journal: return LS("明细")
        case .accounts: return LS("账户")
        case .reports: return LS("报表")
        }
    }
    var symbol: String {
        switch self {
        case .add: return "square.and.pencil"
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
    @Published var draft = Draft()
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
    @Published var tab: Tab = .add
    @Published var showSettings = false
    /// open 账本检查 on the overview tab (from Settings)
    @Published var openCheck = false
    @Published var toast: Toast?
    /// bumped to pop every tab back to its root (after an edit or delete)
    @Published var popToken = 0
    /// account filter handed to the journal tab
    @Published var journalAccount: String?
    var toastAction: (() async -> Void)?
    /// a regular payment offered as a subscription after saving it
    @Published var subSuggestion: SubCandidate?

    @Published var tplPinned: [String] { didSet { Prefs.set("tplPinned", tplPinned); tplCache = nil } }
    @Published var tplHidden: [String] { didSet { Prefs.set("tplHidden", tplHidden); tplCache = nil } }
    @Published var defaultFunding: String? { didSet { Prefs.set("defaultFunding", defaultFunding) } }
    @Published var explicitAmounts: Bool { didSet { Prefs.set("explicit", explicitAmounts) } }

    /// repository layout (settings; empty = detect from the ledger)
    @Published var mainFile: String { didSet { Prefs.set(pk("mainFile"), mainFile) } }
    @Published var journalPattern: String { didSet { Prefs.set(pk("journalPattern"), journalPattern) } }
    @Published var receivableAccount: String { didSet { Prefs.set(pk("receivable"), receivableAccount) } }
    @Published var subsFile: String { didSet { Prefs.set(pk("subsFile"), subsFile) } }
    @Published private(set) var detectedLayout = RepoLayout()
    /// ledger-x.json in the repository (shared by every device); nil = not there yet
    @Published private(set) var repoConfig: LedgerXConfig?

    /// BQL: queries saved on this phone, and the ones in the ledger (query directives, *.bql files)
    @Published var myQueries: [SavedQuery] { didSet { Prefs.set("queries", myQueries) } }
    @Published private(set) var ledgerQueries: [SavedQuery] = []
    var main: String { mainFile.trimmed.isEmpty ? "main.bean" : mainFile.trimmed }
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
        var op = Op(kind: .write, path: LedgerXConfig.path)
        op.text = c.json()
        op.label = LS("更新仓库结构（%@）", LedgerXConfig.path)
        return await commit([op], word: LS("已保存到 %@", LedgerXConfig.path), checked: true)
    }
    private var pushing = false
    /// bumped by every rebuild; a rebuild that finishes after a newer one started is dropped
    private var rebuildGen = 0
    private var tplCache: [Template]?

    /// per-ledger settings key ("tree", "tree@<id>", …); the first ledger keeps the original keys
    static func key(_ k: String, _ id: String) -> String { id == "default" ? k : k + "@" + id }
    func pk(_ k: String) -> String { Store.key(k, cfg.id) }

    /// the one store, shared by the app and its Shortcuts actions
    static let shared = Store()

    init() {
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
        tplPinned = Prefs.get("tplPinned", [String]())
        tplHidden = Prefs.get("tplHidden", [String]())
        defaultFunding = Prefs.get("defaultFunding", String?.none)
        explicitAmounts = Prefs.get("explicit", true)
        mainFile = Prefs.get(Store.key("mainFile", id), "")
        journalPattern = Prefs.get(Store.key("journalPattern", id), "")
        receivableAccount = Prefs.get(Store.key("receivable", id), "")
        subsFile = Prefs.get(Store.key("subsFile", id), "")
        myQueries = Prefs.get("queries", [SavedQuery]())
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
        for k in ["pending", "tree", "lastSync", "ci", "mainFile", "journalPattern", "receivable", "subsFile", "sub.ignored", "remind.cards"] {
            UserDefaults.standard.removeObject(forKey: "ledger." + Store.key(k, id))
        }
    }

    private func saveTree() { Prefs.set(pk("tree"), tree) }
    func savePending() { Prefs.set(pk("pending"), pending) }

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
    var demoEnv: [String: String] { demo ? ProcessInfo.processInfo.environment : [:] }
    private func loadDemo(_ dir: String) async {
        demo = true
        cfg = RepoConfig(owner: "demo", repo: "ledger", branch: "main", token: "demo")
        let env = ProcessInfo.processInfo.environment
        let base = URL(fileURLWithPath: dir)
        let result: (Ledger, Derived) = await Task.detached {
            let extra = env["LEDGER_EXTRA"]
            let L = loadLedger(root: "main.bean") { path in
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
        if let t = env["LEDGER_TAB"], let tab = Tab(rawValue: t) { self.tab = tab }
        if env["LEDGER_TAB"] == "settings" { tab = .overview; showSettings = true }
        var qs: [SavedQuery] = []
        if let names = try? FileManager.default.subpathsOfDirectory(atPath: dir) {
            for n in names.sorted() where n.hasSuffix(".bql") {
                if let t = try? String(contentsOf: base.appendingPathComponent(n), encoding: .utf8) { qs += parseBQLFile(t, file: n) }
            }
        }
        ledgerQueries = Self.directiveQueries(result.0) + qs
        UserDefaults.standard.set(env["LEDGER_PRIVACY"] != nil, forKey: "ledger.privacy")
        UserDefaults.standard.set(env["LEDGER_THEME"] ?? "jade", forKey: "ledger.theme")
        UserDefaults.standard.set(env["LEDGER_LANG"] ?? "zh", forKey: "ledger.language")
        if let a = env["LEDGER_ACCOUNT"] { journalAccount = a }
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
            syncState = .idle
            syncError = ""
            lastSync = Date()
            Prefs.set(pk("lastSync"), lastSync)
        } catch {
            fail(error)
            if L == nil && tree != nil { await rebuild(quietly: true) }
        }
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
        } catch { fail(error) }
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

    /// file text with the pending queue applied
    func fileText(_ path: String) async throws -> String {
        var base = ""
        if let sha = tree?.files[path] { base = try await blobText(path, sha) }
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
        let main = self.main
        repoConfig = Self.readConfig(files: files, ops: ops)
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
            for path in files.keys.sorted() where path.hasSuffix(".bql") {
                if let sha = files[path], let t = BlobCache.get(sha) { qs += parseBQLFile(t, file: path) }
            }
            ledgerQueries = qs
            loadError = nil
            version += 1
            afterLoad()
            if draft.funding.isEmpty { draft = newDraft(.expense, r.1, defaultFunding: defaultFunding) }
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
        loadLedger(root: main) { path in
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
        noteMoved(ops)
        pending.append(contentsOf: ops)
        savePending()
        if held {
            show(LS("已暂存在本机，未推送"))
            await rebuild()
            return true
        }
        var shown = subNames.isEmpty ? word : word + LS(" · 已关联到 %@", subNames.first ?? "")
        if released > 0 { shown = LS("检查通过，暂存的修改已一并推送") }
        if let undo = undo { show(shown, action: LS("撤销"), undo) } else { show(shown) }
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()
        await rebuild()
        if subNames.isEmpty { suggestSubscription(after: ops) }
        await syncNow()
        return true
    }

    /// wait for a push in progress (switching ledgers mid-push would file its results under the wrong ledger)
    func waitForPush() async {
        var n = 0
        while pushing && n < 600 { try? await Task.sleep(nanoseconds: 100_000_000); n += 1 }
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
        if pushing { return }
        pushing = true
        defer { pushing = false }
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
            var paths: [String] = []
            for o in ops where !paths.contains(o.path) { paths.append(o.path) }
            var changes: [FileChange] = []
            var texts: [String: String] = [:]
            var included: [Op] = []
            for path in paths {
                let sha = tree?.files[path]
                let dels = ops.filter { $0.path == path && $0.kind == .deleteFile }
                if !dels.isEmpty {
                    changes.append(FileChange(path: path, text: nil, version: sha))
                    included += dels
                    continue
                }
                var base = ""
                if let sha = sha { base = try await blobText(path, sha) }
                // an edit/delete whose original text is gone (changed elsewhere) is parked, not pushed
                let mine = pending.filter { $0.path == path }
                for (k, o) in mine.enumerated() where (o.kind == .remove || o.kind == .replace) && o.failed == nil && o.held == nil {
                    // only what will actually be written: earlier failed or held ops are skipped by the push
                    let skipped = Set(pending.filter { $0.failed != nil || $0.held != nil }.map { $0.id })
                    let prior = mine[..<k].filter { !skipped.contains($0.id) }
                    if applyRemove((try? applyOps(base, path: path, ops: prior)) ?? base, o) == nil {
                        let why = LS("原交易已在 GitHub 上被修改，本次%@未提交", (o.label ?? "").hasPrefix(LS("删除")) ? LS("删除") : LS("修改"))
                        markFailed(o.id, why)
                        if k + 1 < mine.count, (mine[k + 1].kind == .insert || mine[k + 1].kind == .balance), mine[k + 1].silent == true { markFailed(mine[k + 1].id, why) }
                    }
                }
                savePending()
                let fileOps = pending.filter { $0.path == path && $0.failed == nil && $0.held == nil }
                if fileOps.isEmpty { continue }
                do {
                    let text = try applyOps(base, path: path, ops: fileOps, strict: true)
                    texts[path] = text
                    changes.append(FileChange(path: path, text: text, version: sha))
                    included += fileOps
                } catch let e as ConflictError {
                    // park this file's ops instead of blocking every other file in the queue
                    for o in fileOps { markFailed(o.id, e.localizedDescription) }
                    savePending()
                }
            }
            if changes.isEmpty { return }
            let message = commitMessage(included, path: paths.count == 1 ? paths[0] : LS("%@ 个文件", paths.count))
            let versions = try await backend.writeMany(changes, message: message)
            for c in changes {
                if let t = texts[c.path], let v = versions[c.path] {
                    BlobCache.set(v, t)
                    tree?.files[c.path] = v
                } else if c.text == nil {
                    tree?.files[c.path] = nil
                }
            }
            let ids = Set(included.map { $0.id })
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
        }
    }

    // MARK: - helpers for views

    static func directiveQueries(_ L: Ledger) -> [SavedQuery] {
        L.entries.filter { $0.type == .query }.compactMap { e in
            guard let q = e.query, !q.trimmed.isEmpty else { return nil }
            return SavedQuery(id: "query:" + (e.name ?? q), name: e.name ?? "query", text: q.trimmed, source: "ledger")
        }
    }

    /// an op removing one balance assertion line (found in the file as it is now, pending ops applied)
    func balanceRemoveOp(_ e: Entry) async -> Op? {
        guard let account = e.account, let text = try? await fileText(e.file) else { return nil }
        let prefix = "\(e.date) balance \(account)"
        let ccy = e.currency ?? ""
        guard let line = text.components(separatedBy: "\n").first(where: { l in
            guard l.hasPrefix(prefix), l.dropFirst(prefix.count).first?.isWhitespace == true else { return false }
            let toks = l.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return ccy.isEmpty || toks.contains(ccy)
        }) else { return nil }
        var op = Op(kind: .remove, path: e.file)
        op.line = line
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

    func saveQuery(_ q: SavedQuery) {
        if let i = myQueries.firstIndex(where: { $0.id == q.id }) { myQueries[i] = q } else { myQueries.append(q) }
    }

    func deleteQuery(_ id: String) { myQueries.removeAll { $0.id == id } }

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
        return newDraft(kind, D, defaultFunding: defaultFunding)
    }

    func githubURL(_ file: String, line: Int? = nil) -> URL? { backend.webURL(file, line: line) }

    func resetCache() async {
        BlobCache.clear()
        tree = nil
        saveTree()
        await refresh()
    }
}
