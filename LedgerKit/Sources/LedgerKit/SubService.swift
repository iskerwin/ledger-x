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

/// Most specific first: YouTube before Google, iCloud and Apple TV before Apple, Claude before Anthropic's others.
public let subServices: [SubService] = [
    SubService(id: "netflix", words: ["netflix"], names: ["奈飞", "网飞"]),
    SubService(id: "spotify", words: ["spotify"], names: []),
    SubService(id: "youtube", words: ["youtube"], names: []),
    SubService(id: "disney", words: ["disney", "disneyplus"], names: ["迪士尼"]),
    SubService(id: "icloud", words: ["icloud"], names: []),
    SubService(id: "applemusic", words: ["applemusic"], names: []),
    SubService(id: "apple", words: ["apple", "appleone", "appletv"], names: ["苹果"]),
    SubService(id: "chatgpt", words: ["chatgpt", "openai"], names: []),
    SubService(id: "claude", words: ["claude", "anthropic"], names: []),
    SubService(id: "github", words: ["github", "copilot"], names: []),
    SubService(id: "microsoft", words: ["microsoft", "office365", "m365", "xbox"], names: ["微软"]),
    SubService(id: "google", words: ["google", "googleone", "gemini"], names: ["谷歌"]),
    SubService(id: "adobe", words: ["adobe"], names: []),
    SubService(id: "notion", words: ["notion"], names: []),
    SubService(id: "dropbox", words: ["dropbox"], names: []),
    SubService(id: "bilibili", words: ["bilibili"], names: ["哔哩哔哩", "大会员", "B站"]),
    SubService(id: "iqiyi", words: ["iqiyi"], names: ["爱奇艺"]),
    SubService(id: "tencentvideo", words: ["tencentvideo"], names: ["腾讯视频"]),
    SubService(id: "youku", words: ["youku"], names: ["优酷"]),
    SubService(id: "neteasemusic", words: ["neteasemusic", "ncm"], names: ["网易云音乐", "网易云"]),
    SubService(id: "qqmusic", words: ["qqmusic"], names: ["QQ音乐", "QQ 音乐"]),
    SubService(id: "jd", words: ["jdplus"], names: ["京东PLUS", "京东 PLUS", "京东Plus"]),
    SubService(id: "taobao", words: ["88vip"], names: ["88VIP", "淘宝"]),
]

/// The service a subscription is for, judged by its name and payee; nil when none matches.
public func subService(name: String, payee: String) -> SubService? {
    let text = name + " " + payee
    let lower = text.lowercased()
    let words = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    let joined = lower.filter { $0.isLetter || $0.isNumber }
    for s in subServices {
        if s.words.contains(where: { words.contains($0) }) { return s }
        if s.names.contains(where: { lower.contains($0.lowercased()) }) { return s }
        // words spelled together, as in AppleMusic or Disney+ written DisneyPlus
        if s.words.contains(where: { $0.count > 5 && joined.contains($0) }) { return s }
    }
    return nil
}
