import SwiftUI
import LedgerKit

/// The phone's look, in the same values (`Ledger/Views/Theme.swift`, `DonutView.swift`): this target shares none of its code.
extension Color {
    /// 翡翠, the phone's default accent
    static let jade = dynamic(0x2B806A, 0x4FB598)
    /// money in and money out, whatever the accent, dark enough to read as text
    static let gain = dynamic(0x248A3D, 0x30D158)
    static let loss = dynamic(0xD70015, 0xFF453A)
    static let warn = dynamic(0xC76A00, 0xFF9F0A)
    /// money in and out as bars and lines: darker and less saturated than as text, so a chart full of them doesn't glare
    static let chartGain = dynamic(0x4C9A68, 0x3E9E64)
    static let chartLoss = dynamic(0xC0504A, 0xC9564F)
    /// the phone's grouped page and the cards on it: in dark mode the system's window and control colours are one colour, and the cards vanish
    static let page = dynamic(0xF2F2F7, 0x000000)
    static let card = dynamic(0xFFFFFF, 0x1C1C1E)

    var soft: Color { opacity(0.14) }

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// a category's symbol, or the grid's when this system doesn't have it
func categorySymbol(_ account: String) -> String {
    let symbol = defaultCategoryIcon(account)
    return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? "square.grid.2x2" : symbol
}

/// the eight colours a category keeps on the phone and here
enum CategoryPalette {
    static let colors: [(UInt32, UInt32)] = [
        (0x3B7DD8, 0x6AA4F0), (0xC98A1B, 0xE6B04A), (0x8E5BC9, 0xB48BE8), (0x1E9AA8, 0x4FC7D3),
        (0xC2477F, 0xE886B3), (0x7A8A2E, 0xB3C25A), (0x5A5FC8, 0x8F93EE), (0xA0603A, 0xD49470),
    ]

    static func color(_ slot: Int) -> Color {
        let (light, dark) = colors[slot % colors.count]
        return .dynamic(light, dark)
    }
}

struct Card<Content: View>: View {
    /// a page's top card, with the phone's summary card values
    var summary = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(summary ? 20 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: summary ? 22 : 12, style: .continuous))
    }
}

/// the category of an entry on its colour, as the phone's journal with icons; a transfer has no category: arrows on grey
struct CategoryBadge: View {
    let entry: Entry
    let ledger: Ledger
    var size: CGFloat = 28

    var body: some View {
        let account = shownCategory(entry)
        let symbol = account.map { categorySymbol(catOf($0)) } ?? "arrow.left.arrow.right"
        let color = account.map { categoryColor(ledger, $0) } ?? .gray
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// a category's colour, its group's on the phone and here
func categoryColor(_ ledger: Ledger, _ account: String) -> Color {
    let group = catOf(account), count = CategoryPalette.colors.count
    return CategoryPalette.color(categoryColorSlots(ledger, count: count)[group] ?? stableColorSlot(group, count: count))
}

/// the big figure of a summary card; a long one gets smaller, not cut off
struct Headline: View {
    let label: String
    let value: String
    var color = Color.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
    }
}

/// the figures under a summary card's big one, in equal columns below a line
struct SummaryFigures: View {
    let items: [(String, String, Color)]

    var body: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(alignment: .top, spacing: 16) {
                ForEach(items, id: \.0) { item in
                    VStack(spacing: 2) {
                        Text(item.0)
                            .foregroundStyle(.secondary)
                        Text(item.1)
                            .font(.title2.weight(.semibold))
                            .fontDesign(.rounded)
                            .monospacedDigit()
                            .foregroundStyle(item.2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// cards in a row, as tall as each other and as wide as their weights, when each has room; one above the other when not; the same views either way, so what's open in them stays open
struct SideBySide: Layout {
    /// each card's share of the row, the first card first; equal when not given
    var weights: [CGFloat]
    private let spacing: CGFloat = 16
    private let narrowest: CGFloat = 280

    init(weights: [CGFloat] = []) { self.weights = weights }

    private func columns(_ proposal: ProposedViewSize, _ count: Int) -> [CGFloat]? {
        guard let width = proposal.width, count > 1 else { return nil }
        let shares = weights.count == count ? weights : Array(repeating: 1, count: count)
        let free = width - spacing * CGFloat(count - 1), total = shares.reduce(0, +)
        let widths = shares.map { free * $0 / total }
        return widths.allSatisfy { $0 >= narrowest } ? widths : nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let columns = columns(proposal, subviews.count) {
            let heights = zip(subviews, columns).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            return CGSize(width: proposal.width ?? 0, height: heights.max() ?? 0)
        }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).reduce(gaps, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if let columns = columns(proposal, subviews.count) {
            var x = bounds.minX
            for (subview, width) in zip(subviews, columns) {
                subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: bounds.height))
                x += width + spacing
            }
            return
        }
        let offered = ProposedViewSize(width: proposal.width, height: nil)
        var y = bounds.minY
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: offered)
            y += subview.sizeThatFits(offered).height + spacing
        }
    }
}

extension View {
    /// a page's content in the middle of a wide window, not stretched across it
    func pageWidth(_ width: CGFloat = 1080) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }
}

/// a day, written as in the journal; a calendar to change it
struct DateRow: View {
    let title: String
    @Binding var day: String
    var latest: Date?
    @State private var choosing = false

    var body: some View {
        LabeledContent(title) {
            Button(shown) { choosing = true }
                .monospacedDigit()
                .popover(isPresented: $choosing) {
                    DayPicker(title: title, day: $day, latest: latest).padding(12)
                }
        }
        .onChange(of: day) { choosing = false }
    }

    private var shown: String {
        let today = Day.today()
        if day == today { return "今天 · " + Day.dayLabel(day) }
        return Day.dayLabel(day) + (day.prefix(4) != today.prefix(4) ? " " + day.prefix(4) : "")
    }
}

/// the calendar a day is picked on
struct DayPicker: View {
    let title: String
    @Binding var day: String
    var latest: Date?

    var body: some View {
        DatePicker(title, selection: Binding(get: { Day.date(day) ?? Date() }, set: { day = Day.string($0) }),
                   in: Date.distantPast...(latest ?? Date.distantFuture), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
    }
}
