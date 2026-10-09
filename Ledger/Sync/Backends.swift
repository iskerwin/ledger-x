import Foundation
import CryptoKit

/// Where the ledger files live. Every file has a version token (a git blob sha, or a
/// WebDAV ETag); writes and deletes pass the version they expect and fail with 409
/// when the file changed in the meantime.
protocol LedgerBackend {
    /// all files with their versions
    func fetchTree() async throws -> RepoTree
    func read(_ path: String, version: String) async throws -> String
    /// write a file (version nil = create), returning the new version
    func write(_ path: String, text: String, version: String?, message: String) async throws -> String
    func delete(_ path: String, version: String, message: String) async throws
    /// binary files (attachments), by path
    func readData(_ path: String) async throws -> Data
    func writeData(_ path: String, data: Data, message: String) async throws
    /// bean-check status, where the host has one
    func check() async -> GitHub.CI?
    /// a link to the file on the web, where there is one
    func webURL(_ file: String, line: Int?) -> URL?
    var repoURL: URL? { get }
}

func makeBackend(_ c: RepoConfig) -> LedgerBackend {
    switch c.kind {
    case .github: return GitHub(cfg: c)
    case .gitlab: return GitLab(cfg: c)
    case .gitea: return Gitea(cfg: c)
    case .folder: return FolderBackend(cfg: c)
    case .webdav: return WebDAV(cfg: c)
    }
}

/// files the app reads
func isLedgerFile(_ path: String) -> Bool {
    (path.hasSuffix(".bean") || path.hasSuffix(".beancount") || path.hasSuffix(".bql"))
        && !path.split(separator: "/").contains(where: { $0.hasPrefix(".") })
}

func sha1Hex(_ d: Data) -> String { Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// the sha git gives this content ("blob <len>\0<bytes>")
func gitBlobSHA(_ text: String) -> String {
    let body = Data(text.utf8)
    var d = Data("blob \(body.count)\0".utf8)
    d.append(body)
    return sha1Hex(d)
}

/// a stable id for a whole listing, to notice changes
func treeID(_ files: [String: String]) -> String {
    sha1Hex(Data(files.sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: "\n").utf8))
}

private let httpSession: URLSession = {
    let c = URLSessionConfiguration.default
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.urlCache = nil
    c.timeoutIntervalForRequest = 30
    return URLSession(configuration: c)
}()

private func trimSlash(_ s: String) -> String {
    var x = s.trimmingCharacters(in: .whitespaces)
    while x.hasSuffix("/") { x.removeLast() }
    return x
}

// MARK: - GitLab (gitlab.com or self-hosted, API v4)

struct GitLab: LedgerBackend {
    let cfg: RepoConfig
    private var base: String { trimSlash(cfg.server.isEmpty ? "https://gitlab.com" : cfg.server) }
    private var project: String { GitHub.enc(cfg.owner + "/" + cfg.repo).replacingOccurrences(of: "/", with: "%2F") }
    private var api: String { base + "/api/v4/projects/" + project }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: api + path) else { throw GitHubError(status: 0, message: "bad url") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(cfg.token, forHTTPHeaderField: "PRIVATE-TOKEN")
        if let body = body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await httpSession.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw GitHubError(status: 0, message: "no response") }
        guard (200..<300).contains(h.statusCode) else {
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw GitHubError(status: h.statusCode, message: (o?["message"] as? String) ?? (o?["error"] as? String) ?? "")
        }
        return (data, h)
    }

    private var ref: String { GitHub.enc(cfg.branch) }

    func fetchTree() async throws -> RepoTree {
        var files: [String: String] = [:]
        var page = "1"
        while !page.isEmpty {
            let (d, h) = try await request("/repository/tree?ref=\(ref)&recursive=true&per_page=100&page=\(page)")
            for n in (try JSONSerialization.jsonObject(with: d) as? [[String: Any]]) ?? [] where n["type"] as? String == "blob" {
                if let p = n["path"] as? String, let s = n["id"] as? String, isLedgerFile(p) { files[p] = s }
            }
            page = h.value(forHTTPHeaderField: "X-Next-Page") ?? ""
        }
        let (b, _) = try await request("/repository/branches/\(ref)")
        let commit = ((try? JSONSerialization.jsonObject(with: b) as? [String: Any])?["commit"] as? [String: Any])?["id"] as? String
        return RepoTree(sha: commit ?? treeID(files), files: files, commit: commit)
    }

    func read(_ path: String, version: String) async throws -> String {
        let (d, _) = try await request("/repository/blobs/\(version)/raw")
        return String(decoding: d, as: UTF8.self)
    }

    private func current(_ path: String) async throws -> String? {
        do {
            let (d, _) = try await request("/repository/files/\(GitHub.enc(path).replacingOccurrences(of: "/", with: "%2F"))?ref=\(ref)")
            return (try JSONSerialization.jsonObject(with: d) as? [String: Any])?["blob_id"] as? String
        } catch let e as GitHubError where e.status == 404 { return nil }
    }

    func write(_ path: String, text: String, version: String?, message: String) async throws -> String {
        let now = try await current(path)
        if now != version { throw GitHubError(status: 409, message: path) }
        let file = "/repository/files/" + GitHub.enc(path).replacingOccurrences(of: "/", with: "%2F")
        _ = try await request(file, method: version == nil ? "POST" : "PUT",
                              body: ["branch": cfg.branch, "content": text, "commit_message": message, "encoding": "text"])
        return gitBlobSHA(text)
    }

    func delete(_ path: String, version: String, message: String) async throws {
        // like write: never delete a file that changed on the server since we read it
        guard let now = try await current(path) else { return }
        if now != version { throw GitHubError(status: 409, message: path) }
        let file = "/repository/files/" + GitHub.enc(path).replacingOccurrences(of: "/", with: "%2F")
        _ = try await request(file, method: "DELETE", body: ["branch": cfg.branch, "commit_message": message])
    }

    func readData(_ path: String) async throws -> Data {
        try await request("/repository/files/\(GitHub.enc(path).replacingOccurrences(of: "/", with: "%2F"))/raw?ref=\(ref)").0
    }
    func writeData(_ path: String, data: Data, message: String) async throws {
        let file = "/repository/files/" + GitHub.enc(path).replacingOccurrences(of: "/", with: "%2F")
        _ = try await request(file, method: "POST", body: ["branch": cfg.branch, "content": data.base64EncodedString(), "commit_message": message, "encoding": "base64"])
    }

    func check() async -> GitHub.CI? { nil }
    func webURL(_ file: String, line: Int?) -> URL? {
        URL(string: "\(base)/\(cfg.owner)/\(cfg.repo)/-/blob/\(GitHub.enc(cfg.branch))/\(GitHub.encPath(file))" + (line.map { "#L\($0)" } ?? ""))
    }
    var repoURL: URL? { URL(string: "\(base)/\(cfg.owner)/\(cfg.repo)") }
}

// MARK: - Gitea / Forgejo (incl. Codeberg), API v1

struct Gitea: LedgerBackend {
    let cfg: RepoConfig
    private var base: String { trimSlash(cfg.server) }
    private var api: String { base + "/api/v1/repos/\(GitHub.enc(cfg.owner))/\(GitHub.enc(cfg.repo))" }

    private func json(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        guard let url = URL(string: api + path) else { throw GitHubError(status: 0, message: "bad url") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("token " + cfg.token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await httpSession.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw GitHubError(status: status, message: o?["message"] as? String ?? "")
        }
        return data.isEmpty ? [:] : ((try? JSONSerialization.jsonObject(with: data)) ?? [:])
    }

    func fetchTree() async throws -> RepoTree {
        let b = try await json("/branches/\(GitHub.enc(cfg.branch))") as? [String: Any]
        guard let commit = (b?["commit"] as? [String: Any])?["id"] as? String else { throw GitHubError(status: 404, message: cfg.branch) }
        var files: [String: String] = [:]
        var page = 1
        while true {
            let t = try await json("/git/trees/\(commit)?recursive=true&per_page=1000&page=\(page)") as? [String: Any] ?? [:]
            for n in (t["tree"] as? [[String: Any]]) ?? [] where n["type"] as? String == "blob" {
                if let p = n["path"] as? String, let s = n["sha"] as? String, isLedgerFile(p) { files[p] = s }
            }
            if (t["truncated"] as? Bool) == true && page < 50 { page += 1 } else { break }
        }
        return RepoTree(sha: commit, files: files, commit: commit)
    }

    func read(_ path: String, version: String) async throws -> String {
        let o = try await json("/git/blobs/\(version)") as? [String: Any]
        let b64 = ((o?["content"] as? String) ?? "").replacingOccurrences(of: "\n", with: "")
        return String(decoding: Data(base64Encoded: b64) ?? Data(), as: UTF8.self)
    }

    func write(_ path: String, text: String, version: String?, message: String) async throws -> String {
        var body: [String: Any] = ["content": Data(text.utf8).base64EncodedString(), "message": message, "branch": cfg.branch]
        if let v = version { body["sha"] = v }
        let o = try await json("/contents/\(GitHub.encPath(path))", method: version == nil ? "POST" : "PUT", body: body) as? [String: Any]
        return ((o?["content"] as? [String: Any])?["sha"] as? String) ?? gitBlobSHA(text)
    }

    func delete(_ path: String, version: String, message: String) async throws {
        _ = try await json("/contents/\(GitHub.encPath(path))", method: "DELETE", body: ["sha": version, "message": message, "branch": cfg.branch])
    }

    func readData(_ path: String) async throws -> Data {
        guard let url = URL(string: api + "/raw/\(GitHub.encPath(path))?ref=\(GitHub.enc(cfg.branch))") else { throw GitHubError(status: 0, message: path) }
        var r = URLRequest(url: url)
        r.setValue("token " + cfg.token, forHTTPHeaderField: "Authorization")
        let (data, resp) = try await httpSession.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw GitHubError(status: status, message: path) }
        return data
    }
    func writeData(_ path: String, data: Data, message: String) async throws {
        _ = try await json("/contents/\(GitHub.encPath(path))", method: "POST", body: ["content": data.base64EncodedString(), "message": message, "branch": cfg.branch])
    }

    func check() async -> GitHub.CI? { nil }
    func webURL(_ file: String, line: Int?) -> URL? {
        URL(string: "\(base)/\(cfg.owner)/\(cfg.repo)/src/branch/\(GitHub.enc(cfg.branch))/\(GitHub.encPath(file))" + (line.map { "#L\($0)" } ?? ""))
    }
    var repoURL: URL? { URL(string: "\(base)/\(cfg.owner)/\(cfg.repo)") }
}

// MARK: - a folder from the Files app (on this iPhone, iCloud Drive, other providers, Working Copy…)

struct FolderBackend: LedgerBackend {
    let cfg: RepoConfig

    /// resolve the bookmark and run `body` with access to the folder
    private func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        guard let bm = cfg.bookmark else { throw GitHubError(status: 404, message: LS("尚未选择文件夹")) }
        var stale = false
        let url = try URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    private func coordinatedRead(_ url: URL) throws -> String {
        var err: NSError?
        var out: Result<String, Error> = .failure(GitHubError(status: 0, message: url.lastPathComponent))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            out = Result { try String(contentsOf: u, encoding: .utf8) }
        }
        if let e = err { throw e }
        return try out.get()
    }

    private func coordinatedWrite(_ url: URL, _ text: String) throws {
        var err: NSError?
        var out: Error?
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            do { try Data(text.utf8).write(to: u, options: .atomic) } catch { out = error }
        }
        if let e = err ?? out { throw e }
    }

    func fetchTree() async throws -> RepoTree {
        try await Task.detached { () throws -> RepoTree in
            try withFolder { (root: URL) throws -> RepoTree in
                var files: [String: String] = [:]
                let fm = FileManager.default
                guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else {
                    return RepoTree(sha: "", files: [:], commit: nil)
                }
                let rootPath = root.standardizedFileURL.path
                for case let u as URL in en {
                    var rel = String(u.standardizedFileURL.path.dropFirst(rootPath.count))
                    while rel.hasPrefix("/") { rel.removeFirst() }
                    if rel.split(separator: "/").first.map({ $0 == ".git" }) == true { en.skipDescendants(); continue }
                    var real = u
                    // iCloud placeholders not downloaded yet: ".name.bean.icloud"
                    let n = u.lastPathComponent
                    if n.hasPrefix("."), n.hasSuffix(".icloud") {
                        let name = String(n.dropFirst().dropLast(7))
                        real = u.deletingLastPathComponent().appendingPathComponent(name)
                        rel = (rel as NSString).deletingLastPathComponent
                        rel = rel.isEmpty ? name : rel + "/" + name
                        try? fm.startDownloadingUbiquitousItem(at: real)
                    }
                    guard isLedgerFile(rel) else { continue }
                    let text = try coordinatedRead(real)
                    let sha = gitBlobSHA(text)
                    BlobCache.set(sha, text)
                    files[rel] = sha
                }
                return RepoTree(sha: treeID(files), files: files, commit: nil)
            }
        }.value
    }

    func read(_ path: String, version: String) async throws -> String {
        if let t = BlobCache.get(version) { return t }
        return try await Task.detached { () throws -> String in try withFolder { (root: URL) throws -> String in try coordinatedRead(root.appendingPathComponent(path)) } }.value
    }

    func write(_ path: String, text: String, version: String?, message: String) async throws -> String {
        try await Task.detached { () throws -> String in
            try withFolder { (root: URL) throws -> String in
                let url = root.appendingPathComponent(path)
                let exists = FileManager.default.fileExists(atPath: url.path)
                if exists || version != nil {
                    let now = exists ? gitBlobSHA(try coordinatedRead(url)) : nil
                    if now != version { throw GitHubError(status: 409, message: path) }
                }
                try coordinatedWrite(url, text)
                return gitBlobSHA(text)
            }
        }.value
    }

    func delete(_ path: String, version: String, message: String) async throws {
        try await Task.detached { () throws -> Void in
            try withFolder { (root: URL) throws -> Void in
                let url = root.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                if gitBlobSHA(try coordinatedRead(url)) != version { throw GitHubError(status: 409, message: path) }
                var err: NSError?
                var out: Error?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
                    do { try FileManager.default.removeItem(at: u) } catch { out = error }
                }
                if let e = err ?? out { throw e }
            }
        }.value
    }

    func readData(_ path: String) async throws -> Data {
        try await Task.detached { () throws -> Data in
            try withFolder { (root: URL) throws -> Data in try Data(contentsOf: root.appendingPathComponent(path)) }
        }.value
    }
    func writeData(_ path: String, data: Data, message: String) async throws {
        try await Task.detached { () throws -> Void in
            try withFolder { (root: URL) throws -> Void in
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        }.value
    }

    func check() async -> GitHub.CI? { nil }
    func webURL(_ file: String, line: Int?) -> URL? { nil }
    var repoURL: URL? { nil }
}

// MARK: - WebDAV (坚果云, Nextcloud, Synology, …)

struct WebDAV: LedgerBackend {
    let cfg: RepoConfig
    private var base: URL? { URL(string: trimSlash(cfg.server) + "/") }

    private func url(_ path: String) -> URL? { base.flatMap { URL(string: GitHub.encPath(path), relativeTo: $0)?.absoluteURL } }

    private func send(_ u: URL, method: String, depth: String? = nil, body: Data? = nil, type: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: u)
        r.httpMethod = method
        if !cfg.username.isEmpty || !cfg.token.isEmpty {
            r.setValue("Basic " + Data("\(cfg.username):\(cfg.token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        if let d = depth { r.setValue(d, forHTTPHeaderField: "Depth") }
        if let t = type { r.setValue(t, forHTTPHeaderField: "Content-Type") }
        r.httpBody = body
        let (data, resp) = try await httpSession.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw GitHubError(status: 0, message: "no response") }
        guard (200..<300).contains(h.statusCode) else { throw GitHubError(status: h.statusCode, message: u.path) }
        return (data, h)
    }

    private static let propfind = Data("""
    <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getlastmodified/><d:getcontentlength/></d:prop></d:propfind>
    """.utf8)

    struct Item { var href: String; var dir: Bool; var etag: String }

    private func list(_ u: URL, depth: String) async throws -> [Item] {
        let (d, _) = try await send(u, method: "PROPFIND", depth: depth, body: WebDAV.propfind, type: "application/xml; charset=utf-8")
        return DAVParser.parse(d)
    }

    /// version token: path + ETag (or modification time and size when the server has no ETag)
    private func version(_ path: String, _ etag: String) -> String { "dav|" + etag + "|" + path }

    private func relative(_ href: String) -> String? {
        guard let base = base else { return nil }
        let basePath = base.path.removingPercentEncoding ?? base.path
        var p = (URL(string: href, relativeTo: base)?.path ?? href).removingPercentEncoding ?? href
        guard p.hasPrefix(trimSlash(basePath)) else { return nil }
        p = String(p.dropFirst(trimSlash(basePath).count))
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    func fetchTree() async throws -> RepoTree {
        guard let root = base else { throw GitHubError(status: 0, message: "bad url") }
        var files: [String: String] = [:]
        var queue: [URL] = [root]
        var seen = Set<String>()
        while let dir = queue.popLast(), seen.count < 200 {
            if !seen.insert(dir.absoluteString).inserted { continue }
            for it in try await list(dir, depth: "1") {
                guard let rel = relative(it.href), !rel.isEmpty else { continue }
                if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                if it.dir {
                    if let u = url(rel.hasSuffix("/") ? rel : rel + "/"), u.absoluteString != dir.absoluteString { queue.append(u) }
                } else if isLedgerFile(rel) {
                    files[rel] = version(rel, it.etag)
                }
            }
        }
        return RepoTree(sha: treeID(files), files: files, commit: nil)
    }

    func read(_ path: String, version: String) async throws -> String {
        guard let u = url(path) else { throw GitHubError(status: 0, message: path) }
        let (d, _) = try await send(u, method: "GET")
        return String(decoding: d, as: UTF8.self)
    }

    private func currentEtag(_ path: String) async throws -> String? {
        guard let u = url(path) else { return nil }
        do { return try await list(u, depth: "0").first?.etag } catch let e as GitHubError where e.status == 404 { return nil }
    }

    func write(_ path: String, text: String, version: String?, message: String) async throws -> String {
        guard let u = url(path) else { throw GitHubError(status: 0, message: path) }
        let now = try await currentEtag(path).map { self.version(path, $0) }
        if now != version { throw GitHubError(status: 409, message: path) }
        do {
            _ = try await send(u, method: "PUT", body: Data(text.utf8), type: "text/plain; charset=utf-8")
        } catch let e as GitHubError where e.status == 409 || e.status == 404 {
            // parent folder missing: create it, then retry
            var dir = ""
            for part in path.split(separator: "/").dropLast() {
                dir += part + "/"
                if let du = url(dir) { _ = try? await send(du, method: "MKCOL") }
            }
            _ = try await send(u, method: "PUT", body: Data(text.utf8), type: "text/plain; charset=utf-8")
        }
        let et = try await currentEtag(path) ?? gitBlobSHA(text)
        let v = self.version(path, et)
        BlobCache.set(v, text)
        return v
    }

    func delete(_ path: String, version: String, message: String) async throws {
        guard let u = url(path) else { return }
        guard let et = try await currentEtag(path) else { return }
        if self.version(path, et) != version { throw GitHubError(status: 409, message: path) }
        _ = try await send(u, method: "DELETE")
    }

    func readData(_ path: String) async throws -> Data {
        guard let u = url(path) else { throw GitHubError(status: 0, message: path) }
        return try await send(u, method: "GET").0
    }
    func writeData(_ path: String, data: Data, message: String) async throws {
        guard let u = url(path) else { throw GitHubError(status: 0, message: path) }
        var dir = ""
        for part in path.split(separator: "/").dropLast() {
            dir += part + "/"
            if let du = url(dir) { _ = try? await send(du, method: "MKCOL") }
        }
        _ = try await send(u, method: "PUT", body: data, type: "application/octet-stream")
    }

    func check() async -> GitHub.CI? { nil }
    func webURL(_ file: String, line: Int?) -> URL? { nil }
    var repoURL: URL? { nil }
}

/// minimal PROPFIND multistatus parser
final class DAVParser: NSObject, XMLParserDelegate {
    private var items: [WebDAV.Item] = []
    private var cur: WebDAV.Item?
    private var text = ""
    private var lastmod = ""
    private var length = ""

    static func parse(_ d: Data) -> [WebDAV.Item] {
        let p = XMLParser(data: d)
        let me = DAVParser()
        p.shouldProcessNamespaces = true
        p.delegate = me
        p.parse()
        return me.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "response" { cur = WebDAV.Item(href: "", dir: false, etag: ""); lastmod = ""; length = "" }
        if name == "collection" { cur?.dir = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href": cur?.href = t
        case "getetag": cur?.etag = t.replacingOccurrences(of: "\"", with: "")
        case "getlastmodified": lastmod = t
        case "getcontentlength": length = t
        case "response":
            if var c = cur {
                if c.etag.isEmpty { c.etag = lastmod + "/" + length }
                items.append(c)
            }
            cur = nil
        default: break
        }
        text = ""
    }
}
