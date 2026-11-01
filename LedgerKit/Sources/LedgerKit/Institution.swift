import Foundation

/// The banks and wallets a card face knows by name. An account is matched by the words of its own name
/// (`Assets:Bank:CMB`, `Assets:EWallet:Alipay-HK`) and of the name shown for it (招商银行一卡通): a Latin
/// alias must be a whole word, a Chinese one may be part of the name.
public struct Institution: Equatable {
    public let id: String
    /// whole words, lower case
    let words: [String]
    /// parts of a name
    let names: [String]
}

/// Most specific first: AlipayHK before Alipay, 中银香港 before 中国银行, 中信 before 花旗, 农业银行 before 中国银行.
public let institutions: [Institution] = [
    Institution(id: "alipayhk", words: ["alipayhk"], names: ["支付宝香港"]),
    Institution(id: "alipay", words: ["alipay", "zhifubao"], names: ["支付宝"]),
    Institution(id: "wechat", words: ["wechat", "wechatpay", "weixin", "wxpay"], names: ["微信"]),
    Institution(id: "wise", words: ["wise", "transferwise"], names: []),
    Institution(id: "octopus", words: ["octopus"], names: ["八达通"]),
    Institution(id: "payme", words: ["payme"], names: []),
    Institution(id: "paypal", words: ["paypal"], names: []),
    Institution(id: "revolut", words: ["revolut"], names: []),
    Institution(id: "bochk", words: ["bochk"], names: ["中银香港"]),
    Institution(id: "abc", words: ["abc", "abchina"], names: ["农业银行", "农行"]),
    Institution(id: "cmb", words: ["cmb", "cmbchina"], names: ["招商银行", "招行"]),
    Institution(id: "icbc", words: ["icbc"], names: ["工商银行", "工行"]),
    Institution(id: "ccb", words: ["ccb"], names: ["建设银行", "建行"]),
    Institution(id: "bocom", words: ["bocom", "bankcomm"], names: ["交通银行", "交行"]),
    Institution(id: "spdb", words: ["spdb"], names: ["浦发"]),
    Institution(id: "citic", words: ["citic"], names: ["中信银行"]),
    Institution(id: "cgb", words: ["cgb", "gdb"], names: ["广发银行", "广发"]),
    Institution(id: "ceb", words: ["ceb", "cebbank"], names: ["光大银行"]),
    Institution(id: "hxb", words: ["hxb", "huaxia"], names: ["华夏银行"]),
    Institution(id: "boc", words: ["boc", "bankofchina"], names: ["中国银行", "中行"]),
    Institution(id: "hsbc", words: ["hsbc"], names: ["汇丰"]),
    Institution(id: "citi", words: ["citi", "citibank"], names: ["花旗"]),
    Institution(id: "hangseng", words: ["hangseng"], names: ["恒生"]),
    Institution(id: "sc", words: ["scb", "stanchart", "standardchartered"], names: ["渣打"]),
    Institution(id: "za", words: ["za", "zabank"], names: ["众安"]),
    Institution(id: "mox", words: ["mox", "moxbank"], names: []),
    Institution(id: "ifast", words: ["ifast", "ifastgb"], names: []),
    Institution(id: "n26", words: ["n26"], names: []),
]

/// The institution `account` belongs to, judged by its own name below the group (`Assets:Bank:…`) and the name
/// shown for it; nil when none matches.
public func institution(account: String, name: String?) -> Institution? {
    let own = account.split(separator: ":").dropFirst(2).joined(separator: " ")
    let text = own + " " + (name ?? "")
    // words split at anything but letters and digits; case is not a break, so AlipayHK stays one word
    let words = Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    let joined = text.lowercased().filter { $0.isLetter || $0.isNumber }
    for i in institutions {
        if i.words.contains(where: { words.contains($0) }) { return i }
        if i.names.contains(where: { text.contains($0) }) { return i }
        // a run of words spelled together, as in an account named BankOfChina or Standard-Chartered
        if i.words.contains(where: { $0.count > 6 && joined.contains($0) }) { return i }
    }
    return nil
}
