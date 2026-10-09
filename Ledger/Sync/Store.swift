import Foundation
import SwiftUI
import LedgerKit

enum Tab: String { case add, overview, journal, accounts, reports }
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
    @Published var toast: Toast?
    /// bumped to pop every tab back to its root (after an edit or delete)
    @Published var popToken = 0
    /// account filter handed to the journal tab
    @Published var journalAccount: String?
    var toastAction: (() async -> Void)?

    @Published var tplPinned: [String] { didSet { Prefs.set("tplPinned", tplPinned); tplCache = nil } }
    @Published var tplHidden: [String] { didSet { Prefs.set("tplHidden", tplHidden); tplCache = nil } }
    @Published var defaultFunding: String? { didSet { Prefs.set("defaultFunding", defaultFunding) } }
    @Published var explicitAmounts: Bool { didSet { Prefs.set("explicit", explicitAmounts) } }

    /// repository layout (settings; empty = detect from the ledger)
    @Published var mainFile: String { didSet { Prefs.set("mainFile", mainFile) } }
    @Published var journalPattern: String { didSet { Prefs.set("journalPattern", journalPattern) } }
    @Published var receivableAccount: String { didSet { Prefs.set("receivable", receivableAccount) } }
    @Published private(set) var detectedLayout = RepoLayout()

    /// BQL: queries saved on this phone, and the ones in the ledger (query directives, *.bql files)
    @Published var myQueries: [SavedQuery] { didSet { Prefs.set("queries", myQueries) } }
    @Published private(set) var ledgerQueries: [SavedQuery] = []
    var main: String { mainFile.trimmed.isEmpty ? "main.bean" : mainFile.trimmed }
    var receivable: String { receivableAccount.trimmed.isEmpty ? "Assets:Receivable:Reimbursement" : receivableAccount.trimmed }
    var layout: RepoLayout {
        RepoLayout(main: main, journal: journalPattern.trimmed.isEmpty ? detectedLayout.journal : journalPattern.trimmed)
    }
    private var pushing = false
    private var tplCache: [Template]?

    init() {
        var c: RepoConfig = Prefs.get("cfg", RepoConfig())
        c.token = Keychain.load() ?? ""
        cfg = c
        pending = Prefs.get("pending", [Op]())
        tree = Prefs.get("tree", RepoTree?.none)
        lastSync = Prefs.get("lastSync", Date?.none)
        ci = Prefs.get("ci", GitHub.CI?.none)
        tplPinned = Prefs.get("tplPinned", [String]())
        tplHidden = Prefs.get("tplHidden", [String]())
        defaultFunding = Prefs.get("defaultFunding", String?.none)
        explicitAmounts = Prefs.get("explicit", true)
        mainFile = Prefs.get("mainFile", "")
        journalPattern = Prefs.get("journalPattern", "")
        receivableAccount = Prefs.get("receivable", "")
        myQueries = Prefs.get("queries", [SavedQuery]())
    }

    var gh: GitHub { GitHub(cfg: cfg) }
    var connected: Bool { cfg.isComplete }

    func saveConfig(_ c: RepoConfig) {
        let changedRepo = c.owner != cfg.owner || c.repo != cfg.repo || c.branch != cfg.branch
        cfg = c
        Keychain.save(c.token)
        var stored = c
        stored.token = ""
        Prefs.set("cfg", stored)
        if changedRepo {
            tree = nil; L = nil; D = nil
            Prefs.set("tree", RepoTree?.none)
        }
    }

    private func saveTree() { Prefs.set("tree", tree) }
    func savePending() { Prefs.set("pending", pending) }

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
            let L = loadLedger(root: "main.bean") { path in try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8) }
            return (L, Derived(L))
        }.value
        detectedLayout = RepoLayout.detect(result.0)
        L = result.0
        D = result.1
        version += 1
        draft = newDraft(.expense, result.1, defaultFunding: nil)
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
        if let a = env["LEDGER_ACCOUNT"] { journalAccount = a }
        lastSync = Date()
    }

    func refresh() async {
        guard connected, !demo else { return }
        syncState = .syncing
        do {
            let t = try await gh.fetchTree()
            let changed = tree == nil || t.sha != tree!.sha
            tree = t
            saveTree()
            var pushed = false
            if pending.contains(where: { $0.failed == nil }) { try await pushPending(); pushed = true }
            if changed || pushed || L == nil { await rebuild() }
            ci = await gh.latestCheck()
            Prefs.set("ci", ci)
            syncState = .idle
            syncError = ""
            lastSync = Date()
            Prefs.set("lastSync", lastSync)
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
            Prefs.set("lastSync", lastSync)
            ci = await gh.latestCheck()
        } catch { fail(error) }
    }

    // MARK: - files

    private func blobText(_ sha: String) async throws -> String {
        if let t = BlobCache.get(sha) { return t }
        let t = try await gh.blob(sha)
        BlobCache.set(sha, t)
        return t
    }

    /// download every .bean file not cached yet
    private func ensureBlobs() async throws {
        guard let tree = tree else { return }
        let missing = tree.files.filter { ($0.key.hasSuffix(".bean") || $0.key.hasSuffix(".bql")) && BlobCache.get($0.value) == nil }.map { $0.value }
        if missing.isEmpty { return }
        let api = gh
        try await withThrowingTaskGroup(of: (String, String).self) { group in
            for sha in missing { group.addTask { (sha, try await api.blob(sha)) } }
            for try await (sha, text) in group { BlobCache.set(sha, text) }
        }
    }

    /// file text with the pending queue applied
    func fileText(_ path: String) async throws -> String {
        var base = ""
        if let sha = tree?.files[path] { base = try await blobText(sha) }
        return try applyOps(base, path: path, ops: pending)
    }

    func rebuild(quietly: Bool = false) async {
        guard let tree = tree else { return }
        building = true
        defer { building = false }
        do { try await ensureBlobs() } catch { if !quietly { fail(error) } }
        let files = tree.files
        let ops = pending
        let main = self.main
        let receivable = self.receivable
        let result: (Ledger, Derived)? = await Task.detached(priority: .userInitiated) {
            let L = loadLedger(root: main) { path in
                var text = ""
                if let sha = files[path] {
                    guard let t = BlobCache.get(sha) else { throw GitHubError(status: 0, message: "离线状态：\(path) 尚未下载") }
                    text = t
                } else if path == main { throw GitHubError(status: 404, message: "仓库中未找到 \(main)") }
                return try applyOps(text, path: path, ops: ops)
            }
            if L.txns.isEmpty && L.files.isEmpty { return nil }
            return (L, Derived(L, receivable: receivable))
        }.value
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
            if draft.funding.isEmpty { draft = newDraft(.expense, r.1, defaultFunding: defaultFunding) }
        } else {
            loadError = "无法读取 \(main)"
        }
    }

    // MARK: - queue

    /// queue operations, rebuild locally, then push
    func commit(_ ops: [Op], word: String = "已入账", undo: (() async -> Void)? = nil) async {
        pending.append(contentsOf: ops)
        savePending()
        if let undo = undo { show(word, action: "撤销", undo) } else { show(word) }
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()
        await rebuild()
        await syncNow()
    }

    func pushPending() async throws {
        if pushing { return }
        pushing = true
        defer { pushing = false }
        for attempt in 0..<2 {
            do {
                try await pushOnce()
                break
            } catch let e as GitHubError where (e.status == 409 || e.status == 422) && attempt == 0 {
                tree = try await gh.fetchTree()
                saveTree()
            }
        }
    }

    private func pushOnce() async throws {
        for _ in 0..<3 {   // repeat for ops queued while pushing
            let ops = pending.filter { $0.failed == nil }
            if ops.isEmpty { return }
            var paths: [String] = []
            for o in ops where !paths.contains(o.path) { paths.append(o.path) }
            for path in paths {
                let sha = tree?.files[path]
                let dels = ops.filter { $0.path == path && $0.kind == .deleteFile }
                if !dels.isEmpty {
                    if let sha = sha { try await gh.deleteFile(path, sha: sha, message: dels[0].label ?? "删除 \(path)") }
                    tree?.files[path] = nil
                    pending.removeAll { o in dels.contains { $0.id == o.id } }
                    savePending()
                    continue
                }
                var base = ""
                if let sha = sha { base = try await blobText(sha) }
                // an edit/delete whose original text is gone (changed elsewhere) is parked, not pushed
                let mine = pending.filter { $0.path == path }
                for (k, o) in mine.enumerated() where o.kind == .remove && o.failed == nil {
                    let prior = Array(mine[..<k])
                    if removeBlock((try? applyOps(base, path: path, ops: prior)) ?? base, o.old ?? "") == nil {
                        let why = "原交易已在 GitHub 上被修改，本次\((o.label ?? "").hasPrefix("删除") ? "删除" : "修改")未提交"
                        markFailed(o.id, why)
                        if k + 1 < mine.count, mine[k + 1].kind == .insert, mine[k + 1].silent == true { markFailed(mine[k + 1].id, why) }
                    }
                }
                savePending()
                let fileOps = pending.filter { $0.path == path && $0.failed == nil }
                if fileOps.isEmpty { continue }
                let text = try applyOps(base, path: path, ops: fileOps, strict: true)
                let newSha = try await gh.putFile(path, text: text, sha: sha, message: commitMessage(fileOps, path: path))
                BlobCache.set(newSha, text)
                tree?.files[path] = newSha
                pending.removeAll { o in fileOps.contains { $0.id == o.id } }
                savePending()
            }
            tree = try await gh.fetchTree()
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

    // MARK: - helpers for views

    static func directiveQueries(_ L: Ledger) -> [SavedQuery] {
        L.entries.filter { $0.type == .query }.compactMap { e in
            guard let q = e.query, !q.trimmed.isEmpty else { return nil }
            return SavedQuery(id: "query:" + (e.name ?? q), name: e.name ?? "query", text: q.trimmed, source: "ledger")
        }
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

    func githubURL(_ file: String, line: Int? = nil) -> URL? {
        URL(string: "https://github.com/\(cfg.owner)/\(cfg.repo)/blob/\(cfg.branch)/\(GitHub.encPath(file))" + (line.map { "#L\($0)" } ?? ""))
    }

    func resetCache() async {
        BlobCache.clear()
        tree = nil
        saveTree()
        await refresh()
    }
}
