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

/// the services a subscription's card knows (`subServices`): each with its colours and a built-in icon in `FaceMarks`,
/// as the institutions have
extension FaceLook {
    /// the services a subscription's card knows (`subServices`), in the order 编辑卡面 lists them
    static var servicesNamed: [(id: String, name: String)] { [
        ("icloud", "iCloud"), ("chatgpt", "ChatGPT"), ("claude", "Claude"), ("grok", "Grok"), ("x", "𝕏"),
        ("cloudflare", "Cloudflare"), ("vodafone", "Vodafone"), ("redpocket", "Red Pocket"), ("ebay", "eBay"),
        ("proxy", LS("机场订阅")),
    ] }

    /// a service's card: close to its own colours, with its built-in icon (`FaceMarks`) and a short mark behind it
    static func service(_ id: String?) -> FaceLook? { id.flatMap { services[$0] } }

    private static let services: [String: FaceLook] = [
        "icloud": look(0x3693F3, 0x1F6FD1, .dots(gap: 16), "iC"),
        "chatgpt": look(0x10A37F, 0x0B7A5F, .rings(gap: 22), "GPT"),
        "claude": look(0xD97757, 0xB85C3E, .stripes(angle: 110, gap: 16), "C"),
        "grok": look(0x1C1C1E, 0x3A3A3C, .stripes(angle: 20, gap: 16), "G"),
        "x": look(0x000000, 0x2A2A2A, .grid(gap: 20), "𝕏"),
        "cloudflare": look(0xF38020, 0xD9640A, .rings(gap: 22), "CF"),
        "vodafone": look(0xE60000, 0xA80000, .dots(gap: 16), "V"),
        "redpocket": look(0xE31B23, 0xA8131A, .stripes(angle: 65, gap: 16), "RP"),
        "ebay": look(0x0064D2, 0x0047A0, .grid(gap: 20), "e"),
        "proxy": look(0x5856D6, 0x3A38A8, .stripes(angle: 155, gap: 16), "机"),
    ]
}
