import SwiftUI
import LedgerKit

/// 账户卡片 → 卡面: the top of an account's page drawn as a card in its group's colour. Cards of one group share
/// the colour, so each also gets its own texture (picked from the account's name, the same on every launch) and
/// the first character of its name, large and faint, in the corner.
struct FaceCard<Content: View>: View {
    let account: String
    let title: String
    let tint: Color
    @ViewBuilder let content: (Color) -> Content

    var body: some View {
        let ink = tint.onFill
        content(ink)
            .foregroundStyle(ink)
            .padding(AppSpacing.content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack(alignment: .bottomTrailing) {
                    tint
                    LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    FacePattern.of(account).canvas(ink: ink)
                    Text(FacePattern.mark(title))
                        .font(.system(size: 128, weight: .heavy))
                        .foregroundStyle(ink.opacity(0.12))
                        .lineLimit(1).fixedSize()
                        .offset(x: 6, y: 34)
                        .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("card.face")
    }
}

/// a card's texture: thin lines in the card's own ink, faint enough to sit under the figures
enum FacePattern: Equatable {
    case stripes(angle: Double, gap: CGFloat)
    case rings(gap: CGFloat)
    case dots(gap: CGFloat)
    case grid(gap: CGFloat)

    /// a stable choice from the account's name (Swift's own hash changes on every launch)
    static func of(_ account: String) -> FacePattern {
        var h: UInt32 = 2166136261
        for u in account.unicodeScalars { h = (h ^ u.value) &* 16777619 }
        let gap = CGFloat(12 + Int(h >> 8 % 3) * 4)
        switch h % 4 {
        case 0: return .stripes(angle: [20, 65, 110, 155][Int(h >> 4 % 4)], gap: gap)
        case 1: return .rings(gap: gap + 6)
        case 2: return .dots(gap: gap)
        default: return .grid(gap: gap + 4)
        }
    }

    /// the watermark: the name's first character
    static func mark(_ title: String) -> String { title.first.map(String.init) ?? "" }

    func canvas(ink: Color) -> some View {
        Canvas { context, size in
            let line = ink.opacity(0.08)
            switch self {
            case .stripes(let angle, let gap):
                let reach = size.width + size.height
                context.translateBy(x: size.width / 2, y: size.height / 2)
                context.rotate(by: .degrees(angle))
                var x = -reach
                while x < reach {
                    context.fill(Path(CGRect(x: x, y: -reach, width: 2, height: reach * 2)), with: .color(line))
                    x += gap
                }
            case .rings(let gap):
                let reach = hypot(size.width, size.height)
                var r = gap
                while r < reach {
                    let ring = Path(ellipseIn: CGRect(x: size.width - r, y: -r, width: r * 2, height: r * 2))
                    context.stroke(ring, with: .color(line), lineWidth: 2)
                    r += gap
                }
            case .dots(let gap):
                var y = gap / 2
                while y < size.height {
                    var x = gap / 2
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(line))
                        x += gap
                    }
                    y += gap
                }
            case .grid(let gap):
                var x: CGFloat = 0
                while x < size.width { context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(line)); x += gap }
                var y: CGFloat = 0
                while y < size.height { context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(line)); y += gap }
            }
        }
        .accessibilityHidden(true)
    }
}

/// An asset account's card: its name, how long since its balance was checked, the balance (other currencies
/// under it), the last 30 days as a line, and this month's money in and out.
struct AccountFace: View {
    @Environment(Store.self) var store
    let account: String
    let title: String
    let tail: String?
    /// the balance in each currency, the account's main one first
    let balances: [(String, Double)]
    let glance: AccountGlance

    var body: some View {
        let main = balances.first ?? (glance.currency, 0)
        FaceCard(account: account, title: title, tint: store.groupIcon(account).color) { ink in
            VStack(alignment: .leading, spacing: AppSpacing.control) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppSpacing.icon) { name; Spacer(minLength: AppSpacing.icon); checkPill(ink) }
                    VStack(alignment: .leading, spacing: AppSpacing.icon) { name; checkPill(ink) }
                }
                HStack(alignment: .bottom, spacing: AppSpacing.control) {
                    VStack(alignment: .leading, spacing: AppSpacing.detail) {
                        Text(LS("当前余额")).font(.caption)
                        Text(money(main.1, main.0)).heroAmount().monospacedDigit()
                            .rollingNumber(main.1)
                            .lineLimit(1).minimumScaleFactor(0.6).sensitive()
                    }
                    Spacer(minLength: 0)
                    // its shape gives the amounts away: hidden with them
                    if !KitPrivacy.masked { TrendLine(values: glance.trend, ink: ink).frame(width: 96, height: 36) }
                }
                if balances.count > 1 {
                    FlowLayout(spacing: AppSpacing.detail + 2) {
                        ForEach(balances.dropFirst(), id: \.0) { b in
                            Text(money(b.1, b.0)).font(.footnote.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(ink.opacity(0.18), in: Capsule())
                                .sensitive()
                        }
                    }
                }
                Rectangle().fill(ink.opacity(0.18)).frame(height: 1).accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppSpacing.content) { inText; outText }
                    VStack(alignment: .leading, spacing: AppSpacing.detail) { inText; outText }
                }
                .font(.caption.weight(.semibold)).monospacedDigit()
            }
        }
    }

    private var name: some View {
        Text(title + (tail.map { " •••• " + $0 } ?? "")).font(.subheadline.weight(.semibold)).lineLimit(1)
    }

    private func checkPill(_ ink: Color) -> some View {
        let days = glance.lastCheck.map { daysBetween($0, Day.today()) }
        let text: String
        switch days {
        case nil: text = LS("还没核对过")
        case 0?: text = LS("已核对 · 今天")
        case let d? where d <= 14: text = LS("已核对 · %@ 天前", d)
        case let d?: text = LS("%@ 天未核对", d)
        }
        return Label(text, systemImage: (days ?? 99) <= 14 ? "checkmark" : "clock")
            .labelStyle(ControlLabelStyle())
            .font(.caption.weight(.semibold))
            .padding(.horizontal, AppSpacing.icon).padding(.vertical, 3)
            .background(ink.opacity(0.18), in: Capsule())
    }

    private var inText: some View {
        Text(LS("本月流入 %@", money(glance.inflow, glance.currency))).sensitive()
    }

    private var outText: some View {
        Text(LS("本月流出 %@", money(glance.outflow, glance.currency))).sensitive()
    }
}

/// the balance over the last days as a line, the last day marked
struct TrendLine: View {
    let values: [Double]
    let ink: Color

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
            let span = hi - lo
            let point = { (i: Int) -> CGPoint in
                let y = span < 0.005 ? size.height / 2 : size.height - 3 - CGFloat((values[i] - lo) / span) * (size.height - 6)
                return CGPoint(x: 2 + CGFloat(i) * (size.width - 4) / CGFloat(values.count - 1), y: y)
            }
            var path = Path()
            path.move(to: point(0))
            for i in 1..<values.count { path.addLine(to: point(i)) }
            context.stroke(path, with: .color(ink.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            let last = point(values.count - 1)
            context.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(ink))
        }
        .accessibilityLabel(LS("近 30 天余额走势"))
    }
}
