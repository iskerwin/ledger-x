import SwiftUI
import Charts
import LedgerKit

/// one ring segment
struct DonutSlice: Identifiable, Equatable {
    static let otherID = "__other"
    let id: String
    let label: String
    let value: Double
    var color: Color = .gray

    /// largest `top` items, the rest merged into 其他; colours assigned from the palette
    static func make(_ items: [(id: String, label: String, value: Double)], top: Int = 6) -> [DonutSlice] {
        let pos = items.filter { $0.value > 0.005 }.sorted { $0.value > $1.value }
        let head = pos.count > top + 1 ? Array(pos.prefix(top)) : pos
        let pal = DonutSlice.palette
        var out = head.enumerated().map { i, x in DonutSlice(id: x.id, label: x.label, value: x.value, color: pal[i % pal.count]) }
        let rest = pos.dropFirst(head.count).reduce(0.0) { $0 + $1.value }
        if rest > 0.005 { out.append(DonutSlice(id: otherID, label: LS("其他"), value: rest, color: Color(.systemGray3))) }
        return out
    }

    /// the theme colour first, then distinct system colours
    static var palette: [Color] {
        let cur = AppTheme.current
        let rest: [AppTheme] = [.blue, .orange, .purple, .pink, .teal, .yellow, .indigo, .red, .mint].filter { $0 != cur }
        return [Color.jade] + rest.map { $0.color }
    }
}

/// a ring chart with a tappable legend; the centre shows the selected slice or the total
struct DonutChart: View {
    let slices: [DonutSlice]
    let title: String
    @Binding var selected: String?

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ring.frame(width: 150, height: 150)
            legend.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
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
        .animation(.snappy(duration: 0.2), value: selected)
    }

    private var center: some View {
        let s = slices.first { $0.id == selected }
        let v = s?.value ?? total
        return VStack(spacing: 2) {
            Text(s?.label ?? title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
            Text(money(v, "CNY", 0)).font(.subheadline.weight(.semibold)).monospacedDigit()
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
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.snappy(duration: 0.2)) { selected = id }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(slices) { s in
                Button { pick(selected == s.id ? nil : s.id) } label: {
                    HStack(spacing: 7) {
                        Circle().fill(s.color).frame(width: 8, height: 8)
                        Text(s.label).font(.caption).lineLimit(1)
                            .foregroundStyle(dim(s) ? Color.secondary : Color.primary)
                        Spacer(minLength: 4)
                        Text(total > 0 ? String(format: "%.0f%%", s.value / total * 100) : "")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
