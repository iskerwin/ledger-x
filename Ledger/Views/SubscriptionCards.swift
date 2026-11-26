import SwiftUI
import LedgerKit

/// 订阅管理's subscriptions as a stack of cards, as Wallet keeps its passes: each card shows its top strip (the name
/// and what it costs each period), the front one in full. Active ones come in order of their next charge, the
/// soonest at the front. A card opens its subscription; its menu also has 记一笔 and 编辑卡面.
struct SubCardStack: View {
    @Environment(Store.self) var store
    @Environment(\.push) private var push
    let subs: [Subscription]
    let today: String
    /// the strip each card behind the front one shows: its padding and the name's line, larger with the text
    @ScaledMetric(relativeTo: .subheadline) private var peek: CGFloat = 50

    var body: some View {
        // the soonest at the front: drawn last, so on top
        let cards = Array(subs.reversed())
        VStack(spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, s in
                let front = i == cards.count - 1
                card(s)
                    // laid out whole whatever height it is given
                    .fixedSize(horizontal: false, vertical: true)
                    // the ones behind take only their strip; the rest of each lies under the card in front of it
                    .frame(height: front ? nil : peek, alignment: .top)
                    .zIndex(Double(i))
            }
        }
    }

    private func card(_ s: Subscription) -> some View {
        let face = store.subFace(s)
        let actions = s.status == .active ? [FaceAction(title: LS("记一笔"), symbol: "plus.circle") { store.recordSubscription(s) }] : []
        return Button { push?(SubDetailDest(name: s.name)) } label: {
            FaceCard(subject: face.subject, title: s.name, tint: face.tint, actions: actions, identifier: "sub.card." + s.name) { _ in
                SubCardContent(s: s, today: today)
            }
            .grayscale(s.status == .active ? 0 : 1)
            // a card's top edge lifted off the one behind it
            .shadow(color: .black.opacity(0.14), radius: 6, y: -2)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sub.card." + s.name)
    }
}

/// a card's strip (name, price) and under it where the subscription stands
private struct SubCardContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let s: Subscription
    let today: String

    var body: some View {
        let next = s.nextCharge(onOrAfter: today)
        let alerts = subscriptionAlerts(s, today: today)
        // charged today or tomorrow: the bell rings
        let dueSoon = s.status == .active && next >= today && next <= Day.shift(today, 1)
        VStack(alignment: .leading, spacing: AppSpacing.control) {
            HStack(spacing: AppSpacing.icon) {
                Text(s.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !alerts.isEmpty { Image(systemName: "exclamationmark.circle.fill").font(.caption) }
                if dueSoon {
                    Image(systemName: "bell.fill").font(.caption)
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                }
                Spacer(minLength: AppSpacing.icon)
                Text(money(s.amount, s.currency)).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).sensitive()
            }
            HStack(alignment: .bottom, spacing: AppSpacing.control) {
                VStack(alignment: .leading, spacing: AppSpacing.detail) {
                    if s.status == .active {
                        Text(LS(s.manual ? "下次续费" : "下次扣费")).font(.caption).opacity(0.8)
                        Text(next + " · " + daysText(next, today: today)).font(.headline).monospacedDigit().lineLimit(1)
                    } else {
                        Text(s.status.name).font(.caption).opacity(0.8)
                        Text(s.until.flatMap { $0 >= today ? LS("可用至 %@", $0) : nil } ?? s.statusDate).font(.headline).monospacedDigit().lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: AppSpacing.detail) {
                    Text(s.period.name).font(.caption).opacity(0.8)
                    Text(s.period == .monthly ? " " : LS("月均 %@", money(s.monthly, s.currency))).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1).sensitive()
                        // a blank line where a monthly one has none: every card the same height, as the stack needs
                        .accessibilityHidden(s.period == .monthly)
                }
            }
            Text(LS("已扣 %@ 期 · 累计 %@", s.periodCharges.count, money(s.totalPaid, s.currency, 0)))
                .font(.caption.weight(.semibold)).monospacedDigit().opacity(0.8).lineLimit(1).sensitive()
        }
    }
}

/// a figure on a subscription's card: its label over its value, in the card's ink
struct SubFigure: View {
    let label: String
    let value: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: AppSpacing.detail) {
            Text(label).font(.caption).opacity(0.8).lineLimit(1)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().amountDigits()
                .lineLimit(1).minimumScaleFactor(0.6).sensitive()
        }
    }
}

/// the services a subscription's card knows by colour (`subServices`); kept apart from the institutions, which each
/// have a built-in icon
extension FaceLook {
    /// the services a subscription's card knows (`subServices`), in the order 编辑卡面 lists them
    static var servicesNamed: [(id: String, name: String)] { [
        ("netflix", "Netflix"), ("spotify", "Spotify"), ("youtube", "YouTube"), ("disney", "Disney+"),
        ("icloud", "iCloud"), ("applemusic", "Apple Music"), ("apple", "Apple"), ("chatgpt", "ChatGPT"), ("claude", "Claude"),
        ("github", "GitHub"), ("microsoft", "Microsoft"), ("google", "Google"), ("adobe", "Adobe"), ("notion", "Notion"),
        ("dropbox", "Dropbox"), ("bilibili", LS("哔哩哔哩")), ("iqiyi", LS("爱奇艺")), ("tencentvideo", LS("腾讯视频")),
        ("youku", LS("优酷")), ("neteasemusic", LS("网易云音乐")), ("qqmusic", LS("QQ 音乐")), ("jd", LS("京东 PLUS")),
        ("taobao", LS("淘宝 88VIP")),
    ] }

    /// a service's card: close to its own colours, with a short mark (no logos: the colours tell them apart)
    static func service(_ id: String?) -> FaceLook? { id.flatMap { services[$0] } }

    private static let services: [String: FaceLook] = [
        "netflix": look(0xE50914, 0x8F0610, .stripes(angle: 20, gap: 16), "N"),
        "spotify": look(0x1DB954, 0x128A3E, .rings(gap: 22), "S", ink: 0x0B2A16),
        "youtube": look(0xFF0000, 0xB20000, .dots(gap: 16), "YT"),
        "disney": look(0x113CCF, 0x0B2A8F, .rings(gap: 22), "D+"),
        "icloud": look(0x3693F3, 0x1F6FD1, .dots(gap: 16), "iC"),
        "applemusic": look(0xFA2D48, 0xC81E36, .stripes(angle: 65, gap: 16), "♪"),
        "apple": look(0x1D1D1F, 0x3A3A3C, .grid(gap: 20), "A"),
        "chatgpt": look(0x10A37F, 0x0B7A5F, .rings(gap: 22), "GPT"),
        "claude": look(0xD97757, 0xB85C3E, .stripes(angle: 110, gap: 16), "C"),
        "github": look(0x24292F, 0x3D444D, .grid(gap: 20), "GH"),
        "microsoft": look(0x0078D4, 0x00589C, .grid(gap: 20), "MS"),
        "google": look(0x4285F4, 0x2B63C6, .dots(gap: 16), "G"),
        "adobe": look(0xFA0F00, 0xB80B00, .stripes(angle: 155, gap: 16), "Ad"),
        "notion": look(0x191919, 0x3A3A3A, .stripes(angle: 45, gap: 16), "N"),
        "dropbox": look(0x0061FF, 0x0047BB, .rings(gap: 22), "Db"),
        "bilibili": look(0xFB7299, 0xE0507C, .dots(gap: 16), "B"),
        "iqiyi": look(0x00BE06, 0x008F04, .stripes(angle: 20, gap: 16), "奇"),
        "tencentvideo": look(0xFF6A00, 0xE04F00, .rings(gap: 22), "腾"),
        "youku": look(0x2A7BFF, 0x1757C9, .stripes(angle: 65, gap: 16), "优"),
        "neteasemusic": look(0xDD001B, 0xA60014, .rings(gap: 22), "云"),
        "qqmusic": look(0x31C27C, 0x219160, .dots(gap: 16), "Q"),
        "jd": look(0xE1251B, 0xB01A12, .grid(gap: 20), "京"),
        "taobao": look(0xFF5000, 0xE03A00, .stripes(angle: 110, gap: 16), "88"),
    ]
}
