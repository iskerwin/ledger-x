import Foundation

/// How the 记一笔 category grid and the groups' icons look, kept in ledger-x.json ("categories") so the phone and the
/// Mac show the same: an icon, a name and a colour of one's own per group, the groups' order per root, the ones left
/// out of the grid. Keys are groups (Expenses:Food, Assets:Bank). Every part is optional, so a style written before a
/// part existed reads back whole.
public struct CategoryStyle: Codable, Equatable, Sendable {
    /// SF Symbol per group
    public var icons: [String: String] = [:]
    /// a name of one's own for a group
    public var titles: [String: String] = [:]
    /// per root ("Expenses:", "Income:"): the groups in the order shown; only written when sorted by hand
    public var order: [String: [String]] = [:]
    /// groups left out of the grid (still in 完整表单 and the account picker)
    public var hidden: [String] = []
    /// a colour of one's own for a group's icon (red, orange … brown: the system colours by name)
    public var colors: [String: String] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case icons, titles, order, hidden, colors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        icons = (try? c.decodeIfPresent([String: String].self, forKey: .icons)) ?? [:]
        titles = (try? c.decodeIfPresent([String: String].self, forKey: .titles)) ?? [:]
        order = (try? c.decodeIfPresent([String: [String]].self, forKey: .order)) ?? [:]
        hidden = (try? c.decodeIfPresent([String].self, forKey: .hidden)) ?? []
        colors = (try? c.decodeIfPresent([String: String].self, forKey: .colors)) ?? [:]
    }

    /// the parts that say something (an empty one is left out of the file)
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !icons.isEmpty { try c.encode(icons, forKey: .icons) }
        if !titles.isEmpty { try c.encode(titles, forKey: .titles) }
        if !order.isEmpty { try c.encode(order, forKey: .order) }
        if !hidden.isEmpty { try c.encode(hidden, forKey: .hidden) }
        if !colors.isEmpty { try c.encode(colors, forKey: .colors) }
    }

    public var isEmpty: Bool { icons.isEmpty && titles.isEmpty && order.isEmpty && hidden.isEmpty && colors.isEmpty }

    // MARK: - changes, each said as what changes (applied to the file as it is when written)

    /// nil or blank: the built-in icon again
    public mutating func setIcon(_ group: String, _ symbol: String?) {
        let s = symbol?.trimmingCharacters(in: .whitespaces) ?? ""
        icons[group] = s.isEmpty ? nil : s
    }

    /// nil or blank: the default name again
    public mutating func setTitle(_ group: String, _ title: String?) {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        titles[group] = t.isEmpty ? nil : t
    }

    /// nil: the place's own colour again
    public mutating func setColor(_ group: String, _ name: String?) {
        colors[group] = name?.isEmpty ?? true ? nil : name
    }

    public mutating func setHidden(_ group: String, _ on: Bool) {
        hidden.removeAll { $0 == group }
        if on { hidden.append(group) }
    }

    /// the groups under `root` in the order shown
    public mutating func setOrder(_ root: String, _ groups: [String]) {
        order[root] = groups.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// these groups' own icons and names gone, and back in the grid (their order and colours stay)
    public mutating func resetIconsAndNames(_ groups: [String]) {
        for g in groups {
            icons[g] = nil
            titles[g] = nil
        }
        hidden.removeAll { groups.contains($0) }
    }

    // MARK: -

    /// icons were once kept under a lone account (Expenses:Foo:Bar for a group of one): now under its group
    public func normalized() -> CategoryStyle {
        var s = self
        for (k, v) in icons where k.components(separatedBy: ":").count > 2 {
            s.icons[k] = nil
            if s.icons[catOf(k)] == nil { s.icons[catOf(k)] = v }
        }
        return s
    }

    /// only what is about groups of `accounts` (a style kept for several ledgers, written into one of them)
    public func kept(for accounts: some Sequence<String>) -> CategoryStyle {
        let groups = Set(accounts.map(catOf))
        let has = { (g: String) in groups.contains(g) }
        var s = CategoryStyle()
        s.icons = icons.filter { has($0.key) }
        s.titles = titles.filter { has($0.key) }
        s.colors = colors.filter { has($0.key) }
        s.hidden = hidden.filter(has)
        s.order = order.mapValues { $0.filter(has) }.filter { !$0.value.isEmpty }
        return s
    }

    /// the same style with an account renamed or merged (its sub-accounts too)
    public func renaming(_ from: String, to: String) -> CategoryStyle {
        func move(_ a: String) -> String { a == from ? to : a.hasPrefix(from + ":") ? to + String(a.dropFirst(from.count)) : a }
        func unique(_ l: [String]) -> [String] { l.map(move).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
        var s = self
        s.icons = Dictionary(icons.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        s.titles = Dictionary(titles.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        s.colors = Dictionary(colors.map { (move($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
        s.order = order.mapValues(unique)
        s.hidden = unique(hidden)
        return s
    }
}
