import Foundation

/// what one reading of a folder's ledger went by: its main file, the bytes of every file it read (nil: it couldn't be
/// read), and the folder's files when an include wildcard or option "documents" asked for them
struct FolderReads: Equatable {
    var root: String
    /// the language its messages are in
    var chinese = KitLocale.chinese
    var files: [String: Data?] = [:]
    var listing: [String]?

    /// the folder still holds exactly this, byte for byte
    func isCurrent(in folder: URL) -> Bool {
        guard folderMain(folder) == root, KitLocale.chinese == chinese else { return false }
        for (path, data) in files where (try? Data(contentsOf: folder.appendingPathComponent(path))) != data { return false }
        return listing.map { $0 == folderListing(folder, adding: []) } ?? true
    }
}

/// a ledger with what it was read from
struct FolderLoad {
    let reads: FolderReads
    let ledger: Ledger
}

/// the folder's files, with those about to be written, once each in name order
func folderListing(_ folder: URL, adding written: [String]) -> [String] {
    Set(folderFiles(folder) + written).sorted()
}

/// The ledger in `folder` read from `root`, with `written` standing in for those files. Each file's bytes are taken
/// before its text: changed in between, the bytes kept are the older ones, and the next look reads it again.
func readFolderLedger(root: String, folder: URL, written: [String: String] = [:]) -> FolderLoad {
    var reads = FolderReads(root: root)
    let ledger = loadLedger(root: root, listFiles: {
        let listing = folderListing(folder, adding: Array(written.keys))
        reads.listing = listing
        return listing
    }) { path in
        if let text = written[path] {
            reads.files[path] = Data(text.utf8)
            return text
        }
        let url = folder.appendingPathComponent(path)
        // kept as nil when it can't be read (assigning nil would drop the key): appearing later is a change
        reads.files.updateValue(try? Data(contentsOf: url), forKey: path)
        return try String(contentsOf: url, encoding: .utf8)
    }
    FolderLedgers.counted()
    return FolderLoad(reads: reads, ledger: ledger)
}

/// The last ledger read from each of the latest folders, with what it was read from: a folder that still holds the same
/// bytes gives it back without parsing again. A save's own result goes in once it is written, so the reading its write
/// sets off finds it too.
enum FolderLedgers {
    /// the window's folder and one more
    static let limit = 2
    private static let lock = NSLock()
    private static var kept: [(folder: String, load: FolderLoad)] = []
    /// how many times a folder's ledger has been parsed, for tests
    private(set) static var parses = 0

    static func current(_ folder: URL) -> Ledger? {
        lock.lock()
        let load = kept.first { $0.folder == folder.standardizedFileURL.path }?.load
        lock.unlock()
        guard let load, load.reads.isCurrent(in: folder) else { return nil }
        return load.ledger
    }

    static func keep(_ load: FolderLoad, for folder: URL) {
        let key = folder.standardizedFileURL.path
        lock.lock()
        kept.removeAll { $0.folder == key }
        kept.insert((key, load), at: 0)
        if kept.count > limit { kept.removeLast(kept.count - limit) }
        lock.unlock()
    }

    fileprivate static func counted() {
        lock.lock(); parses += 1; lock.unlock()
    }
}

/// `work` one at a time, off the caller's thread: a caller that arrives while one runs waits for it, and gets nil if it
/// is cancelled by then, so a run of changes ends in one more reading after the current one rather than one each
public actor SerialWork {
    private var running: Task<Void, Never>?
    private var turn = 0

    public init() {}

    public func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        while let current = running {
            await current.value
            if Task.isCancelled { return nil }
        }
        if Task.isCancelled { return nil }
        turn += 1
        let mine = turn
        let task = Task.detached(priority: .userInitiated) { work() }
        running = Task { _ = await task.value }
        let value = await task.value
        if turn == mine { running = nil }
        return value
    }
}
