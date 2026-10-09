import Foundation
import Security

/// where a ledger lives
enum SourceKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case github, gitlab, gitea, folder, webdav
    var id: String { rawValue }
    var name: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        case .gitea: return "Gitea"
        case .folder: return LS("文件夹")
        case .webdav: return "WebDAV"
        }
    }
    var symbol: String {
        switch self {
        case .github, .gitlab, .gitea: return "arrow.triangle.branch"
        case .folder: return "folder"
        case .webdav: return "externaldrive.connected.to.line.below"
        }
    }
    var isGit: Bool { self == .github || self == .gitlab || self == .gitea }
}

/// one ledger: where it is and how to reach it
struct RepoConfig: Codable, Hashable, Identifiable {
    var id = "default"
    var kind: SourceKind = .github
    var name = ""
    var owner = ""
    var repo = ""
    var branch = "main"
    var server = ""          // GitLab / Gitea base URL, or the WebDAV folder URL
    var username = ""        // WebDAV
    var bookmark: Data?      // folder: security-scoped bookmark
    var folderName = ""
    var token = ""           // token or password; kept in the Keychain, not in UserDefaults

    init() {}
    init(owner: String, repo: String, branch: String, token: String) {
        self.owner = owner; self.repo = repo; self.branch = branch; self.token = token
    }

    enum CodingKeys: String, CodingKey { case id, kind, name, owner, repo, branch, server, username, bookmark, folderName, token }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "default"
        kind = try c.decodeIfPresent(SourceKind.self, forKey: .kind) ?? .github
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? "main"
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? ""
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
    }

    var isComplete: Bool {
        switch kind {
        case .github: return !owner.isEmpty && !repo.isEmpty && !branch.isEmpty && !token.isEmpty
        case .gitlab, .gitea: return !server.isEmpty && !owner.isEmpty && !repo.isEmpty && !branch.isEmpty && !token.isEmpty
        case .folder: return bookmark != nil
        case .webdav: return URL(string: server)?.scheme != nil
        }
    }

    /// shown in the ledger list
    var title: String {
        if !name.trimmed.isEmpty { return name.trimmed }
        switch kind {
        case .github, .gitlab, .gitea: return repo.isEmpty ? kind.name : repo
        case .folder: return folderName.isEmpty ? LS("文件夹") : folderName
        case .webdav: return URL(string: server)?.lastPathComponent.removingPercentEncoding ?? "WebDAV"
        }
    }
    var subtitle: String {
        switch kind {
        case .github: return "GitHub · \(owner)/\(repo) · \(branch)"
        case .gitlab, .gitea: return "\(kind.name) · \(URL(string: server)?.host ?? server) · \(owner)/\(repo)"
        case .folder: return LS("文件夹") + " · " + folderName
        case .webdav: return "WebDAV · " + (URL(string: server)?.host ?? server)
        }
    }
    var keychainAccount: String { id == "default" ? "token" : "token." + id }
}

struct RepoTree: Codable, Equatable {
    var sha: String
    var files: [String: String]   // path -> blob sha
    var commit: String?
}

struct GitHubError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? {
        switch status {
        case 401: return LS("凭据无效或已过期（401）")
        case 403: return LS("权限不足（403）：%@", message)
        case 404: return LS("未找到仓库、分支或路径（404）") + (message.isEmpty ? "" : LS("：") + message)
        case 409, 412, 422: return LS("远端文件已被修改（%@），稍后将自动重试", status)
        default: return "\(status) \(message)"
        }
    }
}

struct GitHub: LedgerBackend {
    let cfg: RepoConfig
    var repoPath: String { "/repos/\(cfg.owner)/\(cfg.repo)" }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, raw: Bool = false) async throws -> Data {
        guard let url = URL(string: "https://api.github.com" + path) else { throw GitHubError(status: 0, message: "bad url") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer " + cfg.token, forHTTPHeaderField: "Authorization")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue(raw ? "application/vnd.github.raw+json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let body = body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await GitHub.session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
            throw GitHubError(status: status, message: msg)
        }
        return data
    }

    private func json(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let d = try await request(path, method: method, body: body)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s }
    static func encPath(_ p: String) -> String { p.split(separator: "/", omittingEmptySubsequences: false).map { enc(String($0)) }.joined(separator: "/") }

    func fetchTree() async throws -> RepoTree {
        let t = try await json("\(repoPath)/git/trees/\(GitHub.enc(cfg.branch))?recursive=1")
        var files: [String: String] = [:]
        for n in (t["tree"] as? [[String: Any]]) ?? [] where n["type"] as? String == "blob" {
            if let p = n["path"] as? String, let s = n["sha"] as? String { files[p] = s }
        }
        let commit = try? await json("\(repoPath)/commits/\(GitHub.enc(cfg.branch))")["sha"] as? String
        return RepoTree(sha: t["sha"] as? String ?? "", files: files, commit: commit ?? nil)
    }

    func blob(_ sha: String) async throws -> String {
        let d = try await request("\(repoPath)/git/blobs/\(sha)", raw: true)
        return String(decoding: d, as: UTF8.self)
    }

    /// returns the new blob sha
    func putFile(_ path: String, text: String, sha: String?, message: String) async throws -> String {
        var body: [String: Any] = ["message": message, "content": Data(text.utf8).base64EncodedString(), "branch": cfg.branch]
        if let sha = sha { body["sha"] = sha }
        let r = try await json("\(repoPath)/contents/\(GitHub.encPath(path))", method: "PUT", body: body)
        return (r["content"] as? [String: Any])?["sha"] as? String ?? ""
    }

    func deleteFile(_ path: String, sha: String, message: String) async throws {
        _ = try await request("\(repoPath)/contents/\(GitHub.encPath(path))", method: "DELETE", body: ["message": message, "sha": sha, "branch": cfg.branch])
    }

    // LedgerBackend
    func read(_ path: String, version: String) async throws -> String { try await blob(version) }
    func write(_ path: String, text: String, version: String?, message: String) async throws -> String {
        try await putFile(path, text: text, sha: version, message: message)
    }
    func delete(_ path: String, version: String, message: String) async throws { try await deleteFile(path, sha: version, message: message) }
    func check() async -> CI? { await latestCheck() }
    func webURL(_ file: String, line: Int?) -> URL? {
        URL(string: "https://github.com/\(cfg.owner)/\(cfg.repo)/blob/\(cfg.branch)/\(GitHub.encPath(file))" + (line.map { "#L\($0)" } ?? ""))
    }
    var repoURL: URL? { URL(string: "https://github.com/\(cfg.owner)/\(cfg.repo)") }

    enum CIState: String, Codable { case ok, fail, running, empty, noperm, error }
    struct CI: Codable, Equatable { var state: CIState; var url: String?; var sha: String?; var at: String? }

    func latestCheck() async -> CI {
        do {
            let r = try await json("\(repoPath)/actions/workflows/bean-check.yml/runs?branch=\(GitHub.enc(cfg.branch))&per_page=1")
            guard let run = (r["workflow_runs"] as? [[String: Any]])?.first else { return CI(state: .empty) }
            let status = run["status"] as? String, concl = run["conclusion"] as? String
            let st: CIState = status != "completed" ? .running : concl == "success" ? .ok : .fail
            return CI(state: st, url: run["html_url"] as? String, sha: run["head_sha"] as? String, at: run["updated_at"] as? String)
        } catch let e as GitHubError {
            return CI(state: e.status == 404 ? .empty : e.status == 403 ? .noperm : .error)
        } catch { return CI(state: .error) }
    }
}

/// blobs by sha on disk (they never change)
enum BlobCache {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    /// git blob shas are used as they are; other version tokens (WebDAV ETags) are hashed into a file name
    static func name(_ key: String) -> String {
        key.count == 40 && key.allSatisfy({ $0.isHexDigit }) ? key : sha1Hex(Data(key.utf8))
    }
    static func get(_ sha: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name(sha)), encoding: .utf8) }
    static func set(_ sha: String, _ text: String) { try? Data(text.utf8).write(to: dir.appendingPathComponent(name(sha)), options: .atomic) }
    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

enum Keychain {
    static let service = "ledger.github"

    static func save(_ value: String, account: String = "token") {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(add as CFDictionary, nil)
        // sideloaded builds can lack a keychain group; fall back to app storage
        if st != errSecSuccess { UserDefaults.standard.set(value, forKey: "ledger.fallback." + account) }
        else { UserDefaults.standard.removeObject(forKey: "ledger.fallback." + account) }
    }

    static func load(account: String = "token") -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return String(decoding: d, as: UTF8.self) }
        return UserDefaults.standard.string(forKey: "ledger.fallback." + account)
    }
}
