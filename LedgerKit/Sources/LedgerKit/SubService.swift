import Foundation

/// The services a subscription card knows by name, for its colours. A subscription is matched by the words of its
/// name and its payee (Netflix, 网易云音乐会员): a Latin alias must be a whole word, a Chinese one may be part of the
/// name, as `Institution` matches an account.
public struct SubService: Equatable {
    public let id: String
    /// whole words, lower case
    let words: [String]
    /// parts of a name
    let names: [String]
}

/// Most specific first: Grok before 𝕏, Red Pocket before eBay (what each is bought through).
public let subServices: [SubService] = [
    SubService(id: "icloud", words: ["icloud"], names: []),
    SubService(id: "chatgpt", words: ["chatgpt", "openai"], names: []),
    SubService(id: "claude", words: ["claude", "anthropic"], names: []),
    SubService(id: "grok", words: ["grok", "xai"], names: []),
    SubService(id: "x", words: ["twitter", "xpremium"], names: ["𝕏"]),
    SubService(id: "cloudflare", words: ["cloudflare"], names: []),
    SubService(id: "vodafone", words: ["vodafone"], names: []),
    SubService(id: "redpocket", words: ["redpocket"], names: ["red pocket"]),
    SubService(id: "ebay", words: ["ebay"], names: []),
    SubService(id: "proxy", words: ["vpn", "proxy"], names: ["机场", "梯子"]),
]

/// The service a subscription is for: judged by its name first, then by its payee (a plan bought through a store
/// or a platform is the plan's, not the store's); nil when neither matches.
public func subService(name: String, payee: String) -> SubService? {
    match(name) ?? match(payee)
}

private func match(_ text: String) -> SubService? {
    let lower = text.lowercased()
    let words = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    let joined = lower.filter { $0.isLetter || $0.isNumber }
    for s in subServices {
        if s.words.contains(where: { words.contains($0) }) { return s }
        if s.names.contains(where: { lower.contains($0.lowercased()) }) { return s }
        // words spelled together, as in ChatGPTPlus or CloudflareWorkers
        if s.words.contains(where: { $0.count > 5 && joined.contains($0) }) { return s }
    }
    return nil
}
