#if os(macOS)
import CoreServices
import Foundation

/// tells when a file anywhere under a folder changes, a burst of changes (a save, a git pull) as one; stops when released
public final class FolderWatcher {
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    public init(_ folder: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info, let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            if changed.contains(where: isWatchedChange) { Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// git's own bookkeeping isn't a change to the ledger; what a pull changes is reported for the files themselves
func isWatchedChange(_ path: String) -> Bool {
    !path.contains("/.git/") && !path.hasSuffix("/.git")
}
#endif
