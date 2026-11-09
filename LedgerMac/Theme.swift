import SwiftUI
import LedgerKit

/// The phone's look, in the same values (`Ledger/Views/Theme.swift`, `DonutView.swift`): this target shares none of its code.
extension Color {
    /// 翡翠, the phone's default accent
    static let jade = dynamic(0x2B806A, 0x4FB598)
    /// money in and money out, whatever the accent, dark enough to read as text
    static let gain = dynamic(0x248A3D, 0x30D158)
    static let loss = dynamic(0xD70015, 0xFF453A)
    /// the phone's paper page and the cards on it (`Color.ledgerPage` / `ledgerCard` / `ledgerLine`)
    static let page = dynamic(0xF3EFE6, 0x000000)
    static let card = dynamic(0xFFFCF8, 0x1C1C1E)
    static let line = dynamic(0xE4DDD0, 0x3A3A3C)

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: summary ? 22 : 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: summary ? 22 : 12, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
    }
}

extension View {
    /// the system list background is hidden, so the paper colour shows between rows
    func ledgerCanvas() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.page)
    }
}

/// the category of an entry on its colour, as the phone's journal with icons; a transfer has no category: arrows on grey
struct CategoryBadge: View {
    let entry: Entry
    let ledger: Ledger
    var size: CGFloat = 28

    var body: some View {
        let account = entry.postings.first { $0.account.hasPrefix("Expenses:") || $0.account.hasPrefix("Income:") }?.account
        let symbol = account.map { defaultCategoryIcon(catOf($0)) } ?? "arrow.left.arrow.right"
        let color = account.map { categoryColor($0) } ?? .gray
        Image(systemName: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? "square.grid.2x2" : symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }

    private func categoryColor(_ account: String) -> Color {
        let group = catOf(account), count = CategoryPalette.colors.count
        return CategoryPalette.color(categoryColorSlots(ledger, count: count)[group] ?? stableColorSlot(group, count: count))
    }
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

/// two cards side by side when each has room, one above the other when not; the same views either way, so what's open in them stays open
struct SideBySide: Layout {
    private let spacing: CGFloat = 16
    private let narrowest: CGFloat = 320

    private func columnWidth(_ proposal: ProposedViewSize) -> CGFloat? {
        guard let width = proposal.width, width >= narrowest * 2 + spacing else { return nil }
        return (width - spacing) / 2
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let column = columnWidth(proposal) {
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
            return CGSize(width: proposal.width ?? 0, height: heights.max() ?? 0)
        }
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let gaps = spacing * CGFloat(max(subviews.count - 1, 0))
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).reduce(gaps, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(proposal)
        let offered = ProposedViewSize(width: column ?? proposal.width, height: nil)
        var x = bounds.minX, y = bounds.minY
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: offered)
            if let column {
                x += column + spacing
            } else {
                y += subview.sizeThatFits(offered).height + spacing
            }
        }
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
                    DatePicker(title, selection: date, in: Date.distantPast...(latest ?? Date.distantFuture), displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                }
        }
        .onChange(of: day) { choosing = false }
    }

    private var shown: String {
        let today = Day.today()
        if day == today { return "今天 · " + Day.dayLabel(day) }
        return Day.dayLabel(day) + (day.prefix(4) != today.prefix(4) ? " " + day.prefix(4) : "")
    }

    private var date: Binding<Date> {
        Binding(get: { Day.date(day) ?? Date() }, set: { day = Day.string($0) })
    }
}
