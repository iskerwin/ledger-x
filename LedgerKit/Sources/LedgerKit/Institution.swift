import Foundation

/// The banks, wallets, brokers and public funds a card face knows by name. An account is matched by the words of its own name
/// (`Assets:Bank:CMB`, `Assets:EWallet:Alipay-HK`) and of the name shown for it (招商银行一卡通): a Latin
/// alias must be a whole word, a Chinese one may be part of the name.
public struct Institution: Equatable {
    public let id: String
    /// whole words, lower case
    let words: [String]
    /// parts of a name
    let names: [String]
}

/// Most specific first: 中银香港 before 中国银行, 中信 before others with 中.
public let institutions: [Institution] = [
    Institution(id: "alipay", words: ["alipay", "zhifubao", "yuebao"], names: ["支付宝", "余额宝"]),
    Institution(id: "wechat", words: ["wechat", "wechatpay", "weixin", "wxpay", "minifund"], names: ["微信", "零钱通"]),
    Institution(id: "wise", words: ["wise", "transferwise"], names: []),
    Institution(id: "octopus", words: ["octopus"], names: ["八达通"]),
    Institution(id: "paypal", words: ["paypal"], names: []),
    Institution(id: "bochk", words: ["bochk"], names: ["中银香港"]),
    Institution(id: "cmb", words: ["cmb", "cmbchina"], names: ["招商银行", "招行"]),
    Institution(id: "ccb", words: ["ccb"], names: ["建设银行", "建行"]),
    Institution(id: "spdb", words: ["spdb"], names: ["浦发"]),
    Institution(id: "citic", words: ["citic"], names: ["中信银行"]),
    Institution(id: "cgb", words: ["cgb", "gdb"], names: ["广发银行", "广发"]),
    Institution(id: "ceb", words: ["ceb", "cebbank"], names: ["光大银行"]),
    Institution(id: "hxb", words: ["hxb", "huaxia"], names: ["华夏银行"]),
    Institution(id: "boc", words: ["boc", "bankofchina"], names: ["中国银行", "中行"]),
    Institution(id: "hsbc", words: ["hsbc"], names: ["汇丰"]),
    Institution(id: "za", words: ["za", "zabank"], names: ["众安"]),
    Institution(id: "ifast", words: ["ifast", "ifastgb"], names: []),
    Institution(id: "n26", words: ["n26"], names: []),
    Institution(id: "ibkr", words: ["ibkr", "interactivebrokers"], names: ["盈透"]),
    Institution(id: "schwab", words: ["schwab", "charlesschwab"], names: ["嘉信"]),
    Institution(id: "fsmone", words: ["fsmone"], names: []),
    Institution(id: "okx", words: ["okx", "okex"], names: []),
    Institution(id: "plasma", words: ["plasma", "plasmaone"], names: []),
    Institution(id: "housingfund", words: ["housingfund", "providentfund"], names: ["公积金"]),
    Institution(id: "medical", words: ["medical", "medicalinsurance", "medicare"], names: ["医保", "医疗保险"]),
    Institution(id: "pension", words: ["pension"], names: ["养老"]),
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
