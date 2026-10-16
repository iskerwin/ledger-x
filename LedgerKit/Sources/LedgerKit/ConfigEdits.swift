import Foundation

// MARK: - changes to ledger-x.json, said as what changes
//
// Each is applied to the settings as they are at the moment it is written (with the changes before it), not
// to a list worked out earlier: two taps in a row (pin one template, then another; confirm two alerts) both
// stay, where writing back a whole list taken before the first one landed would drop it. Each does nothing
// when it is already so.

extension LedgerXConfig {
    // 常用交易

    public mutating func pinTemplate(_ id: String) {
        var l = templatesPinned ?? []
        if !l.contains(id) { l.append(id) }
        templatesPinned = l
    }

    public mutating func unpinTemplate(_ id: String) {
        templatesPinned = templatesPinned?.filter { $0 != id }
    }

    /// hidden from 常用交易, and so not pinned either
    public mutating func hideTemplate(_ id: String) {
        var l = templatesHidden ?? []
        if !l.contains(id) { l.append(id) }
        templatesHidden = l
        unpinTemplate(id)
    }

    public mutating func unhideAllTemplates() { templatesHidden = [] }

    // 值得留意

    /// checked and found fine; `live`: the ids that can still come up, to keep the list short (over 500)
    public mutating func confirmAlert(_ id: String, live: Set<String>? = nil) {
        var s = alertsConfirmed ?? []
        if !s.contains(id) { s.append(id) }
        if s.count > 500, let live = live { s = s.filter { live.contains($0) } }
        alertsConfirmed = s
    }

    public mutating func unconfirmAlert(_ id: String) {
        alertsConfirmed = alertsConfirmed?.filter { $0 != id }
    }

    // link problems and subscription suggestions set aside

    public mutating func ignoreLink(_ key: String) {
        var l = linksIgnored ?? []
        if !l.contains(key) { l.append(key) }
        linksIgnored = l
    }

    public mutating func clearIgnoredLinks() { linksIgnored = [] }

    public mutating func ignoreSubSuggestion(_ id: String) {
        var l = subsIgnored ?? []
        if !l.contains(id) { l.append(id) }
        subsIgnored = l
    }

    // 快速搜索: found by what they are, not by where they were when the change was made

    /// a new search, or `original` changed into `s` (where it is; appended when it is gone meanwhile)
    public mutating func saveSearch(_ s: QuickSearch, replacing original: QuickSearch? = nil) {
        var l = searches ?? []
        if let o = original, let i = l.firstIndex(of: o) { l[i] = s }
        else if !l.contains(s) { l.append(s) }
        searches = l
    }

    public mutating func removeSearch(_ s: QuickSearch) {
        searches = searches?.filter { $0 != s }
    }

    /// one place earlier (-1) or later (+1)
    public mutating func moveSearch(_ s: QuickSearch, by d: Int) {
        guard var l = searches, let i = l.firstIndex(of: s), l.indices.contains(i + d) else { return }
        l.swapAt(i, i + d)
        searches = l
    }
}
