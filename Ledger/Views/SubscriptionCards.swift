import SwiftUI
import LedgerKit

/// 订阅管理's subscriptions as a stack of cards, as Wallet keeps its passes: each card shows its top strip (the name
/// and what it costs each period), the front one in full. Active ones come in order of their next charge, the
/// soonest at the front. A card opens in place (`SubFlight`); its menu also has 记一笔 and 编辑卡面.
struct SubCardStack: View {
    @Environment(SubFlight.self) private var flight
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
                Button { flight.openCard(s.link) } label: { SubCard(s: s, today: today) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sub.card." + s.name)
                    // while one is open the stacks stay laid out under it, unseen and not read out
                    .accessibilityHidden(flight.open != nil)
                    // laid out whole whatever height it is given
                    .fixedSize(horizontal: false, vertical: true)
                    // where the whole card is, for its flight: taken before the strip cuts it short
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { flight.place(s.link, $0, open: false) }
                    // while one is open its copy flies in its place
                    .opacity(flight.phase == .closed ? 1 : 0)
                    // the ones behind take only their strip; the rest of each lies under the card in front of it
                    .frame(height: front ? nil : peek, alignment: .top)
                    .zIndex(Double(i))
            }
        }
    }
}

/// a subscription's card; `still` for a copy (in flight, or in the stack under the open one): no menu, not read out
struct SubCard: View {
    @Environment(Store.self) var store
    let s: Subscription
    let today: String
    var still = false

    var body: some View {
        let face = store.subFace(s)
        let actions = s.status == .active && !still ? [FaceAction(title: LS("记一笔"), symbol: "plus.circle") { store.recordSubscription(s) }] : []
        FaceCard(subject: face.subject, title: s.name, tint: face.tint,
                 preview: still ? store.faceStyles[face.subject.key] ?? FaceStyle() : nil,
                 actions: actions, identifier: "sub.card." + s.name) { _ in
            SubCardContent(s: s, today: today)
        }
        .grayscale(s.status == .active ? 0 : 1)
        // a card's top edge lifted off the one behind it
        .shadow(color: .black.opacity(0.14), radius: 6, y: -2)
        .accessibilityHidden(still)
    }
}

/// a card opening as Wallet's do: it rises to the top of the page, the others fold into a stack at the bottom, and its
/// subscription shows under it; closing puts every card back where it was. The cards sit in two different Lists
/// (the stacks, the open one's page), and List rows take no part in `matchedGeometryEffect`, so copies of the cards
/// fly between the frames each place reports.
@Observable final class SubFlight {
    enum Phase { case closed, opening, open, closing }
    /// the open subscription, by its link (a rename keeps it)
    private(set) var open: String?
    private(set) var phase = Phase.closed
    /// the cards have reached the other end of the flight
    private(set) var landed = false
    /// the open one's page has come in (animated with the flight)
    private(set) var shown = false
    /// where each card is in the stacks, and on the open one's page (window space)
    private(set) var from: [String: CGRect] = [:]
    private(set) var to: [String: CGRect] = [:]
    var reduceMotion = false
    private var layerShown = false

    func openCard(_ link: String) {
        guard phase == .closed else { return }
        to = [:]
        open = link
        if reduceMotion {
            withAnimation(AppMotion.standard) { phase = .open; shown = true }
        } else {
            phase = .opening
        }
    }

    func close() {
        guard phase == .open else { return }
        if reduceMotion {
            withAnimation(AppMotion.standard) { shown = false } completion: { self.reset() }
        } else {
            phase = .closing
        }
    }

    /// a card's frame in the stacks (`open` false) or on the open one's page
    func place(_ link: String, _ frame: CGRect, open: Bool) {
        if open { if to[link] != frame { to[link] = frame } } else if from[link] != frame { from[link] = frame }
        if open, link == self.open { ready() }
    }

    /// at once, no flight: its subscription is gone, or the ledger changed
    func reset() {
        open = nil; phase = .closed; landed = false; shown = false; layerShown = false
    }

    /// the copies are up (`appeared`) or the open page has laid out its card: fly when both are ready
    func ready(appeared: Bool = false) {
        if appeared { layerShown = true }
        guard layerShown, !landed, let open else { return }
        switch phase {
        case .opening:
            guard to[open] != nil else { return }
            withAnimation(Self.flight, completionCriteria: .logicallyComplete) { landed = true; shown = true } completion: {
                self.phase = .open; self.landed = false; self.layerShown = false
            }
        case .closing:
            withAnimation(Self.flight, completionCriteria: .logicallyComplete) { landed = true; shown = false } completion: {
                self.reset()
            }
        default: break
        }
    }

    static let flight = Animation.spring(duration: 0.5, bounce: 0.12)
}

/// the cards in flight: each from where it was to where it goes; one with no place at an end (off screen, or not in
/// the stack under the open one) comes from or goes to below the bottom edge
struct SubFlightLayer: View {
    @Environment(SubFlight.self) private var flight
    /// every card, back to front (`SubCards.drawn`)
    let cards: [Subscription]
    let today: String

    var body: some View {
        GeometryReader { g in
            let space = g.frame(in: .global)
            let opening = flight.phase == .opening
            let width = flight.from.values.first?.width ?? space.width - 2 * AppSpacing.content
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, s in
                let start = opening ? flight.from[s.link] : flight.to[s.link]
                let end = opening ? flight.to[s.link] : flight.from[s.link]
                let r = (flight.landed ? end : start)
                    ?? CGRect(x: space.minX + (space.width - width) / 2, y: space.maxY + 40, width: width, height: 160)
                SubCard(s: s, today: today, still: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: r.width, height: r.height, alignment: .top)
                    .position(x: r.midX - space.minX, y: r.midY - space.minY)
                    // the open one rises over the others; back down, the ones in front of it close over it on the way
                    .zIndex(opening && s.link == flight.open ? 1000 : Double(i))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { flight.ready(appeared: true) }
    }
}

/// the other cards folded at the bottom of the open one's page, as Wallet's; a tap puts them all back
struct SubFoldedStack: View {
    @Environment(SubFlight.self) private var flight
    /// back to front, as the stacks draw them (`SubCards.folded`): the soonest at the front
    let cards: [Subscription]
    let today: String
    /// how much of each shows
    @ScaledMetric(relativeTo: .subheadline) private var edge: CGFloat = 10

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, s in
                SubCard(s: s, today: today, still: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { flight.place(s.link, $0, open: true) }
                    .padding(.top, CGFloat(i) * edge)
                    .zIndex(Double(i))
            }
        }
        .opacity(flight.phase == .open ? 1 : 0)
        .padding(.horizontal, AppSpacing.content)
        // only the edges are on screen: the cards run on past the bottom
        .frame(height: CGFloat(cards.count) * edge + AppSpacing.content * 2, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { flight.close() }
        .accessibilityHidden(true)
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
