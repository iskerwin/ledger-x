import SwiftUI
import Charts
import UIKit
import LedgerKit

/// An identity keeps its colour when ranks, periods, labels or the accent theme change: a category its ledger's
/// (`categoryColorSlots`), anything else the one its name points to.
func categoryColor(_ id: String, _ L: Ledger? = nil) -> Color {
    let n = CategoryPalette.colors.count
    return CategoryPalette.color(L.flatMap { categoryColorSlots($0, count: n)[id] } ?? stableColorSlot(id, count: n))
}

/// The eight colours charts tell categories apart by (and 明细's category icons): hues kept apart, none of them
/// the green of money in or the red of money out
enum CategoryPalette {
    /// light, dark
    static let colors: [(UInt32, UInt32)] = [
        (0x3B7DD8, 0x6AA4F0), (0xC98A1B, 0xE6B04A), (0x8E5BC9, 0xB48BE8), (0x1E9AA8, 0x4FC7D3),
        (0xC2477F, 0xE886B3), (0x7A8A2E, 0xB3C25A), (0x5A5FC8, 0x8F93EE), (0xA0603A, 0xD49470),
    ]

    static func color(_ slot: Int) -> Color {
        let (light, dark) = colors[slot % colors.count]
        func ui(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) }).readableInk
    }
}

/// one ring segment
struct DonutSlice: Identifiable, Equatable {
    static let otherID = "__other"
    let id: String
    let label: String
    let value: Double
    var color: Color = .gray

    /// largest `top` items, the rest merged into 其他; colours belong to identities, not ranks
    /// With the ledger, categories take its colours (`categoryColor`); the rest (payees, accounts) are told apart
    /// among themselves, in name order, so the same ones shown again get the same colours.
    static func make(_ items: [(id: String, label: String, value: Double)], top: Int = 6, L: Ledger? = nil) -> [DonutSlice] {
        let pos = items.filter { $0.value > 0.005 }.sorted { $0.value > $1.value }
        let head = pos.count > top + 1 ? Array(pos.prefix(top)) : pos
        let n = CategoryPalette.colors.count
        let ledger = L.map { categoryColorSlots($0, count: n) } ?? [:]
        let local = colorSlots(head.map(\.id).filter { ledger[$0] == nil }.sorted(), count: n)
        var out = head.map { x in
            DonutSlice(id: x.id, label: x.label, value: x.value, color: CategoryPalette.color(ledger[x.id] ?? local[x.id] ?? 0))
        }
        let rest = pos.dropFirst(head.count).reduce(0.0) { $0 + $1.value }
        if rest > 0.005 { out.append(DonutSlice(id: otherID, label: LS("其他"), value: rest, color: Color(.systemGray3))) }
        return out
    }

}

/// a ring chart with a tappable legend; the centre shows the selected slice or the total
struct DonutChart: View {
    let slices: [DonutSlice]
    let title: String
    @Binding var selected: String?
    @Environment(\.displayCurrency) private var cur
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                HStack(alignment: .center, spacing: AppSpacing.content) {
                    ring.frame(width: 150, height: 150)
                    legend.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                }
            }
            VStack(alignment: .center, spacing: AppSpacing.content) {
                ring.frame(width: 170, height: 170)
                legend.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, AppSpacing.icon)
    }

    private func dim(_ s: DonutSlice) -> Bool { selected != nil && selected != s.id }

    private var ring: some View {
        Chart(slices) { s in
            SectorMark(angle: .value("v", s.value),
                       innerRadius: .ratio(0.64),
                       outerRadius: .ratio(selected == s.id ? 1 : 0.9),
                       angularInset: 1.2)
                .cornerRadius(3)
                .foregroundStyle(s.color.opacity(dim(s) ? 0.3 : 1))
        }
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geo in
                if let f = proxy.plotFrame {
                    let r = geo[f]
                    center.frame(width: r.width * 0.58).position(x: r.midX, y: r.midY)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { p in
                        guard let f = proxy.plotFrame else { return }
                        let r = geo[f]
                        tap(dx: p.x - r.midX, dy: p.y - r.midY, radius: min(r.width, r.height) / 2)
                    }
            }
        }
        .animation(reduceMotion ? nil : AppMotion.quick, value: selected)
        .sensitive()
    }

    private var center: some View {
        let s = slices.first { $0.id == selected }
        let v = s?.value ?? total
        return VStack(spacing: AppSpacing.detail) {
            Text(s?.label ?? title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            Text(money(v, cur, 0)).font(.subheadline.weight(.semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).sensitive()
            if s != nil, total > 0 {
                Text(String(format: "%.0f%%", v / total * 100)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// angle measured clockwise from 12 o'clock, like SectorMark draws
    private func tap(dx: Double, dy: Double, radius: Double) {
        let d = (dx * dx + dy * dy).squareRoot()
        if d < radius * 0.5 || d > radius * 1.05 || total <= 0 { pick(nil); return }
        var a = atan2(dx, -dy)
        if a < 0 { a += 2 * .pi }
        let target = a / (2 * .pi) * total
        var acc = 0.0
        for s in slices {
            acc += s.value
            if target <= acc { pick(selected == s.id ? nil : s.id); return }
        }
    }

    private func pick(_ id: String?) {
        Haptics.selection()
        withAnimation(reduceMotion ? nil : AppMotion.quick) { selected = id }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: AppSpacing.icon) {
            ForEach(slices) { s in
                Button { pick(selected == s.id ? nil : s.id) } label: {
                    HStack(spacing: AppSpacing.icon) {
                        Circle().fill(s.color).frame(width: 8, height: 8)
                        Text(s.label).font(.caption).lineLimit(2)
                            .foregroundStyle(dim(s) ? Color.secondary : Color.primary)
                        Spacer(minLength: 4)
                        Text(total > 0 ? String(format: "%.0f%%", s.value / total * 100) : "")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(s.label)
                .accessibilityValue(KitPrivacy.masked ? LS("金额已隐藏") : money(s.value, cur))
                .accessibilityAddTraits(selected == s.id ? .isSelected : [])
            }
        }
    }
}
