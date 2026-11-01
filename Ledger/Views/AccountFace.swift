import SwiftUI
import LedgerKit

/// 账户卡片 → 卡面: the top of an account's page drawn as a card. A known bank or wallet (`FaceLook`) gets close to
/// its own colours and its built-in icon (`FaceMarks`), large and faint, in the corner; any other account its
/// group's colour, its own texture (picked from the account's name, the same on every launch) and the first
/// character of its name.
struct FaceCard<Content: View>: View {
    @Environment(Store.self) var store
    let account: String
    let title: String
    let tint: Color
    /// the style to draw instead of the saved one (编辑卡面's preview); the preview is not itself editable
    var preview: FaceStyle? = nil
    /// a bank card or a credit card: 卡片信息 is offered beside 编辑卡面
    var holdsCard = false
    @ViewBuilder let content: (Color) -> Content
    @State private var editing = false
    @State private var cardInfo = false

    var body: some View {
        let d = FaceDesign(account: account, title: title, tint: tint, style: preview ?? store.faceStyles[account] ?? FaceStyle(), ledger: store.cfg.id)
        content(d.ink)
            .foregroundStyle(d.ink)
            .padding(AppSpacing.content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack(alignment: .bottomTrailing) {
                    LinearGradient(colors: [d.fill, d.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                    LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    d.pattern.canvas(ink: d.ink)
                    // drawn, not laid out: a Text this large would reach past the card's bottom edge and with it
                    // the card's frame, over the buttons under it
                    Canvas { context, size in d.drawMark(in: &context, size: size) }
                        .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous))
            .contextMenu {
                if preview == nil {
                    Button { editing = true } label: { Label(LS("编辑卡面"), systemImage: "paintbrush") }
                    if holdsCard {
                        Button { cardInfo = true } label: { Label(LS("卡片信息"), systemImage: "creditcard") }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("card.face")
            .accessibilityAction(named: Text(LS("编辑卡面"))) { if preview == nil { editing = true } }
            .accessibilityAction(named: Text(LS("卡片信息"))) { if preview == nil && holdsCard { cardInfo = true } }
            .sheet(isPresented: $editing) {
                FaceStyleSheet(account: account, title: title, tint: tint)
                    .tint(Color.jadeInk).environment(\.locale, AppLanguage.current.locale)
            }
            .sheet(isPresented: $cardInfo) {
                CardInfoSheet(account: account, title: title)
                    .tint(Color.jadeInk).environment(\.locale, AppLanguage.current.locale)
            }
    }
}

/// What a card is drawn with once its saved style, its institution and its group's colour are settled.
struct FaceDesign {
    let fill: Color
    let accent: Color
    let ink: Color
    let pattern: FacePattern
    /// the watermark: a text, an icon, or nothing
    let mark: String?
    let icon: UIImage?
    /// a built-in icon: drawn in the card's ink like a single-colour uploaded one
    let symbol: Image?
    let iconMono: Bool
    let size: Double
    let opacity: Double

    @MainActor init(account: String, title: String, tint: Color, style: FaceStyle, ledger: String) {
        let id = style.institution.map { $0 == FaceStyle.noInstitution ? nil : $0 } ?? institution(account: account, name: title)?.id
        let look = FaceLook.of(id)
        let picked = IconTint.color(style.color)
        fill = picked ?? look?.color ?? tint
        // a colour of one's own is flat: the brand's second colour would not go with it
        accent = picked == nil ? (look?.accent ?? fill) : fill
        ink = picked == nil ? (look?.ink ?? fill.onFill) : fill.onFill
        pattern = style.pattern.flatMap(FacePatternKind.init(rawValue:)).map(FacePattern.init(kind:)) ?? look?.pattern ?? FacePattern.of(account)
        iconMono = style.iconMono ?? true
        size = min(1.5, max(0.5, style.size ?? 1))
        opacity = min(0.4, max(0.04, style.opacity ?? FaceStyle.defaultOpacity))
        switch style.mark {
        case .off?:
            mark = nil; icon = nil; symbol = nil
        case .icon?:
            mark = nil; symbol = nil
            icon = style.icon.flatMap { FaceIcons.image($0, ledger: ledger, mono: style.iconMono ?? true, strength: style.strength ?? FaceStyle.defaultStrength) }
        case .symbol(let s)?:
            mark = nil; icon = nil
            symbol = FaceMarks.image(s)
        case .text(let t)?:
            mark = t.isEmpty ? nil : t; icon = nil; symbol = nil
        case nil:
            icon = nil
            // a known institution's own icon; its short mark only while it has none
            symbol = look == nil ? nil : id.flatMap(FaceMarks.image)
            mark = symbol == nil ? look?.mark ?? FacePattern.mark(title) : nil
        }
    }

    /// a short mark large and partly off the edge, a longer one smaller and further in; an icon in the corner
    func drawMark(in context: inout GraphicsContext, size box: CGSize) {
        if let symbol {
            // square, in the same corner as an uploaded icon
            let side = 112 * size
            // the faintness on the layer: an asset's vector drops the alpha of a shading colour and drew solid ink
            var c = context
            c.opacity = opacity
            var shape = c.resolve(symbol.renderingMode(.template))
            shape.shading = .color(ink)
            c.draw(shape, in: CGRect(x: box.width - side - 12, y: box.height - side + side * 0.12, width: side, height: side))
            return
        }
        if let icon {
            let side = 112 * size
            let w = icon.size.width >= icon.size.height ? side : side * icon.size.width / icon.size.height
            let h = icon.size.height >= icon.size.width ? side : side * icon.size.height / icon.size.width
            let rect = CGRect(x: box.width - w - 12, y: box.height - h + side * 0.12, width: w, height: h)
            if iconMono {
                // the silhouette filled with the card's ink, as faint as a text mark
                var shape = context.resolve(Image(uiImage: icon).renderingMode(.template))
                shape.shading = .color(ink.opacity(opacity))
                context.draw(shape, in: rect)
            } else {
                // its own colours read stronger than the ink: the same setting a little more opaque
                var c = context
                c.opacity = min(1, opacity * 2.5)
                c.draw(Image(uiImage: icon), in: rect)
            }
            return
        }
        guard let mark, !mark.isEmpty else { return }
        let n = mark.count
        let font: CGFloat = (n <= 1 ? 128 : n == 2 ? 96 : 64) * size
        let drop: CGFloat = (n <= 1 ? 34 : n == 2 ? 22 : 12) * size
        let text = context.resolve(Text(mark).font(.system(size: font, weight: .heavy)).foregroundStyle(ink.opacity(opacity)))
        context.draw(text, at: CGPoint(x: box.width + 4, y: box.height + drop), anchor: .bottomTrailing)
    }
}

/// A known bank's or wallet's card: close to its own colours, its texture and a short mark for the watermark when it
/// has no built-in icon. Picked by `institution(account:name:)`; any other account keeps its group's colour.
struct FaceLook {
    /// the institutions in the order 编辑卡面 lists them, with their names
    static var named: [(id: String, name: String)] { [
        ("cmb", LS("招商银行")), ("icbc", LS("工商银行")), ("ccb", LS("建设银行")), ("boc", LS("中国银行")), ("abc", LS("农业银行")),
        ("bocom", LS("交通银行")), ("spdb", LS("浦发银行")), ("citic", LS("中信银行")),
        ("cgb", LS("广发银行")), ("ceb", LS("光大银行")), ("hxb", LS("华夏银行")), ("hsbc", LS("汇丰")), ("citi", LS("花旗")),
        ("hangseng", LS("恒生银行")), ("bochk", LS("中银香港")), ("sc", LS("渣打银行")), ("za", LS("众安银行")), ("mox", "Mox"),
        ("ifast", "iFAST"), ("n26", "N26"),
        ("alipay", LS("支付宝")), ("wechat", LS("微信支付")), ("wise", "Wise"), ("octopus", LS("八达通")), ("alipayhk", "AlipayHK"),
        ("payme", "PayMe"), ("paypal", "PayPal"), ("revolut", "Revolut"),
    ] }

    let color: Color
    let accent: Color
    /// set where the colour's own choice of black or white reads poorly against the brand (Wise's green)
    let ink: Color?
    let pattern: FacePattern
    let mark: String

    static func of(_ id: String?) -> FaceLook? { id.flatMap { all[$0] } }

    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    private static func look(_ color: UInt32, _ accent: UInt32, _ pattern: FacePattern, _ mark: String, ink: UInt32? = nil) -> FaceLook {
        FaceLook(color: hex(color), accent: hex(accent), ink: ink.map(hex), pattern: pattern, mark: mark)
    }

    private static let all: [String: FaceLook] = [
        "cmb": look(0xC8152D, 0x8E0E20, .rings(gap: 22), "招"),
        "icbc": look(0xC7000B, 0xE0393E, .stripes(angle: 20, gap: 16), "工"),
        "ccb": look(0x0B5BA8, 0x073C70, .grid(gap: 20), "建"),
        "boc": look(0xA71E32, 0x6E1020, .rings(gap: 22), "中"),
        "abc": look(0x0A8A6E, 0x05624E, .stripes(angle: 110, gap: 16), "农"),
        "bocom": look(0x1C3F94, 0x2E5BC4, .dots(gap: 16), "交"),
        "spdb": look(0x0B3A73, 0x1A5AA6, .stripes(angle: 65, gap: 16), "浦"),
        "citic": look(0xD6001C, 0x9A0014, .dots(gap: 16), "信"),
        "cgb": look(0xE60012, 0xA8000D, .grid(gap: 20), "广"),
        "ceb": look(0x5E2B83, 0x8A4BB4, .rings(gap: 22), "光"),
        "hxb": look(0xD7000F, 0x96000A, .stripes(angle: 110, gap: 16), "华"),
        "hsbc": look(0xDB0011, 0xA3000D, .stripes(angle: 45, gap: 16), "HSBC"),
        "citi": look(0x003B70, 0x056DAE, .stripes(angle: 20, gap: 16), "citi"),
        "hangseng": look(0x00775B, 0x00543F, .rings(gap: 22), "恒"),
        "bochk": look(0x9E1B32, 0xC23A4F, .dots(gap: 16), "中银"),
        "sc": look(0x0072AA, 0x1E9E6A, .stripes(angle: 155, gap: 16), "渣"),
        "za": look(0x12B6A8, 0x0A7F75, .grid(gap: 20), "ZA"),
        "mox": look(0x1C1C20, 0x3A3A44, .rings(gap: 22), "Mox"),
        "ifast": look(0x0B3C7D, 0x1F6FB8, .stripes(angle: 65, gap: 16), "iF"),
        "n26": look(0x36A18B, 0x24806C, .dots(gap: 16), "N26"),
        "alipay": look(0x1677FF, 0x0B4FCC, .rings(gap: 22), "支"),
        "wechat": look(0x07C160, 0x058F47, .dots(gap: 16), "微"),
        "wise": look(0x9FE870, 0x7FD44A, .stripes(angle: 155, gap: 16), "W", ink: 0x163300),
        "octopus": look(0xF08C00, 0xD06A00, .grid(gap: 20), "八"),
        "alipayhk": look(0x1677FF, 0x00A0E9, .stripes(angle: 20, gap: 16), "HK"),
        "payme": look(0xDB0011, 0xA3000D, .dots(gap: 16), "Me"),
        "paypal": look(0x003087, 0x009CDE, .rings(gap: 22), "P"),
        "revolut": look(0x191C1F, 0x3B4048, .grid(gap: 20), "R"),
    ]
}

/// a card's texture: thin lines in the card's own ink, faint enough to sit under the figures
enum FacePattern: Equatable {
    case stripes(angle: Double, gap: CGFloat)
    case rings(gap: CGFloat)
    case dots(gap: CGFloat)
    case grid(gap: CGFloat)
    case none

    /// one picked by hand (编辑卡面 → 纹理)
    init(kind: FacePatternKind) {
        switch kind {
        case .stripes: self = .stripes(angle: 45, gap: 16)
        case .rings: self = .rings(gap: 22)
        case .dots: self = .dots(gap: 16)
        case .grid: self = .grid(gap: 20)
        case .none: self = .none
        }
    }

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
            case .none:
                break
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
    /// 卡片信息's expiry (not in privacy mode)
    var expiry: String? = nil
    /// the account's full name under its title, as on the plain header (with 已于…关闭 when closed)
    let path: String
    /// the balance in each currency, the account's main one first
    let balances: [(String, Double)]
    let glance: AccountGlance

    var body: some View {
        let main = balances.first ?? (glance.currency, 0)
        FaceCard(account: account, title: title, tint: store.groupIcon(account).color, holdsCard: account.hasPrefix("Assets:Bank:")) { ink in
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
        VStack(alignment: .leading, spacing: AppSpacing.detail) {
            Text(title + (tail.map { " •••• " + $0 } ?? "")).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(path + (expiry.map { " · " + LS("有效期 %@", $0) } ?? "")).font(.caption).opacity(0.8).lineLimit(1)
        }
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

/// The built-in institution icons: one single-colour vector per `FaceLook` id in Assets.xcassets/FaceMarks, simple
/// solid shapes after each one's own mark, drawn in the card's ink. A new one is an imageset named after the id
/// (template rendering, vector kept); check_project keeps the two lists the same.
enum FaceMarks {
    static func image(_ id: String) -> Image? {
        UIImage(named: "FaceMarks/" + id) == nil ? nil : Image("FaceMarks/" + id)
    }
}
