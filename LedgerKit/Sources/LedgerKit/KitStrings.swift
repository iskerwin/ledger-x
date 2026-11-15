import Foundation

/// The apps' interface text: Chinese keys, their English in en.json in the app's bundle
public enum KitStrings {
    /// zh → en
    public static let en: [String: String] = {
        guard let url = Bundle.main.url(forResource: "en", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }()
    /// keys ending in "：" translate a message prefix ("账户未开立：Assets:X")
    static let prefixes: [(String, String)] = en.filter { $0.key.hasSuffix("：") }.sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }

    /// `key` in English when asked, then `%@` in it for each argument, in order; a translation may use `%1$@`, `%2$@` to
    /// reorder them
    public static func text(_ key: String, _ args: [Any], english: Bool) -> String {
        var s = key
        if english {
            if let t = en[key] {
                s = t
            } else if let p = prefixes.first(where: { key.hasPrefix($0.0) }) {
                s = p.1 + key.dropFirst(p.0.count)
            }
        }
        if args.isEmpty { return s }
        let strs = args.map { "\($0)" }
        for (i, a) in strs.enumerated() { s = s.replacingOccurrences(of: "%\(i + 1)$@", with: a) }
        var out = ""
        var idx = 0
        var rest = Substring(s)
        while let r = rest.range(of: "%@") {
            out += rest[..<r.lowerBound]
            out += idx < strs.count ? strs[idx] : ""
            idx += 1
            rest = rest[r.upperBound...]
        }
        return out + rest
    }
}
