import SwiftUI
import LedgerKit

// 币种与换算: one setting for the reports, the overview and the accounts (as Fava's conversion menu and its
// currency legend). The button sits in the navigation bar of each of those pages; a line at the top says when
// anything other than the default (every held currency, converted to the operating currency) is chosen.

extension Store {
    /// how amounts are valued now
    var cmode: ReportMode { L.map { cview.mode($0) } ?? .convert("CNY") }
    /// the currencies counted (nil = all)
    var conly: Set<String>? { L.flatMap { cview.only($0) } }
}

/// the currency summary figures are in (the overview's, when several currencies are chosen as booked)
private struct DisplayCurrencyKey: EnvironmentKey { static let defaultValue = "CNY" }

extension EnvironmentValues {
    var displayCurrency: String {
        get { self[DisplayCurrencyKey.self] }
        set { self[DisplayCurrencyKey.self] = newValue }
    }
}

/// a fixed colour for each currency, the same in the switches and the charts
func currencyColor(_ c: String) -> Color {
    switch c {
    case "CNY": return Color(red: 0.36, green: 0.55, blue: 0.93)
    case "HKD": return Color(red: 0.90, green: 0.42, blue: 0.45)
    case "USD": return Color(red: 0.45, green: 0.68, blue: 0.36)
    case "EUR": return Color(red: 0.66, green: 0.53, blue: 0.88)
    case "GBP": return Color(red: 0.85, green: 0.47, blue: 0.70)
    case "MOP": return Color(red: 0.93, green: 0.65, blue: 0.27)
    case "SGD": return Color(red: 0.25, green: 0.70, blue: 0.70)
    case "JPY": return Color(red: 0.80, green: 0.55, blue: 0.35)
    default:
        let palette: [Color] = [.teal, .indigo, .brown, .cyan, .mint, .orange, .pink, .purple]
        var h: UInt32 = 2166136261
        for b in c.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return palette[Int(h % UInt32(palette.count))]
    }
}

/// the button in the navigation bar
struct CurrencyButton: View {
    @Environment(Store.self) var store
    @State private var open = false
    var body: some View {
        Button { open = true } label: {
            Image(systemName: store.cview.isDefault ? "dollarsign.arrow.circlepath" : "dollarsign.circle.fill")
                .foregroundStyle(store.cview.isDefault ? Color.accentColor : Color.jade)
        }
        .accessibilityLabel(LS("币种与换算"))
        .sheet(isPresented: $open) { CurrencySheet() }
        .onAppear { if store.demoEnv["LEDGER_CURRENCY_SHEET"] != nil { open = true } }
    }
}

/// "HKD · 原币" above a page when something other than the default is chosen; tap to change
struct CurrencyBanner: View {
    @Environment(Store.self) var store
    @State private var open = false
    var body: some View {
        if let L = store.L, let label = store.cview.label(L) {
            HStack(spacing: AppSpacing.icon) {
                Button { open = true } label: {
                    HStack(spacing: AppSpacing.icon) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.jade)
                        Text(label).font(.subheadline.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                Button { store.cview = CurrencyView() } label: { Label(LS("恢复默认"), systemImage: "arrow.counterclockwise").labelStyle(ControlLabelStyle()) }.font(.subheadline).buttonStyle(.borderless)
            }
            .sheet(isPresented: $open) { CurrencySheet() }
        }
    }
}

struct CurrencySheet: View {
    @Environment(Store.self) var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let L = store.L { form(L) } else { PageLoading() }
            }
            .navigationTitle(LS("币种与换算"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Label(LS("完成"), systemImage: "checkmark").labelStyle(ControlLabelStyle()) }.fontWeight(.semibold) }
            }
        }
        .pickerSheet()
    }

    private func form(_ L: Ledger) -> some View {
        let mode = store.cview.mode(L)
        let held = heldCurrencies(L)
        let sel = store.cview.selected(L)
        return Form {
            Section {
                WrapLayout(spacing: AppSpacing.icon) {
                    ForEach(ledgerCurrencies(L), id: \.self) { c in
                        CurrencyChip(code: c, on: sel.contains(c), held: held.contains(c))
                            .onTapGesture { store.cview.toggle(c, L) }
                            .onLongPressGesture { store.cview.solo(c, L); Learned.hold.mark() }
                    }
                }
                .padding(.vertical, AppSpacing.detail)
            } header: {
                Text(LS("币种"))
            } footer: {
                HintFooter(LS("点按打开或关掉。没有持有的默认关掉。"), tip: LS("长按只看这一种（再长按恢复）。"), .hold)
            }
            Section {
                modeRow(.units, L, mode)
                modeRow(.cost, L, mode)
                modeRow(.market, L, mode)
            } header: {
                Text(LS("换算方式"))
            }
            Section {
                ForEach(reportCurrencies(L), id: \.self) { c in modeRow(.convert(c), L, mode) }
            } header: {
                Text(LS("折算为"))
            } footer: {
                Text(mode.explain(L))
            }
            if !store.cview.isDefault {
                Section {
                    Button { store.cview = CurrencyView() } label: { Label(LS("恢复默认（全部持有的币种，折算为 %@）", L.base), systemImage: "arrow.counterclockwise").labelStyle(ControlLabelStyle()) }
                }
            }
        }
    }

    private func modeRow(_ m: ReportMode, _ L: Ledger, _ now: ReportMode) -> some View {
        Button {
            store.cview.modeRaw = m == .convert(L.base) ? nil : m.raw
        } label: {
            HStack(spacing: AppSpacing.control) {
                Text(m.name).foregroundStyle(.primary)
                Spacer()
                if m == now { Image(systemName: "checkmark").foregroundStyle(Color.jade) }
            }
        }
    }
}

/// a currency switch: its colour when on, grey and struck through when off
struct CurrencyChip: View {
    let code: String
    let on: Bool
    let held: Bool
    /// choosing one of several (the overview's currency): the chosen one outlined, none struck through
    var picker = false
    var body: some View {
        HStack(spacing: AppSpacing.icon) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on || picker ? currencyColor(code) : Color(.systemGray3))
                .accessibilityHidden(true)
            Text(code).font(.subheadline.weight(.medium)).strikethrough(!on && !picker)
                .foregroundStyle(on ? Color.primary : Color.secondary)
            if !held { Text(LS("未持有")).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, AppSpacing.icon).padding(.vertical, AppSpacing.icon)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .overlay(Capsule().stroke(picker && on ? currencyColor(code) : Color.clear, lineWidth: 1.5))
        .contentShape(Capsule())
        // read as one control that is chosen or not (its tick is only a picture)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// a row of chips that wraps onto the next line
struct WrapLayout: Layout {
    var spacing: CGFloat = AppSpacing.icon

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

/// what a summary figure comes to: one amount, or one line per currency
struct InventoryFigure: View {
    let label: String
    let inv: Inventory
    let base: String
    var color: Color? = nil
    var alignment: HorizontalAlignment = .leading
    var body: some View {
        VStack(alignment: alignment, spacing: AppSpacing.detail) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            let xs = inv.byCurrency(base: base)
            ForEach(xs.isEmpty ? [CurrencyAmount(base, 0)] : xs) { x in
                Text(unitText(x.amount, x.currency)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(color ?? .primary).sensitive()
            }
        }
    }
}

/// the big figure at the top of a page: one amount, or (several currencies as booked) one line each
struct InventoryHeadline: View {
    let inv: Inventory
    let base: String
    var body: some View {
        let xs = inv.byCurrency(base: base)
        if xs.count <= 1 {
            let x = xs.first ?? CurrencyAmount(base, 0)
            Text(unitText(x.amount, x.currency)).heroAmount().monospacedDigit()
                .rollingNumber(x.amount)
                .foregroundStyle(x.amount < -0.005 ? Color.loss : Color.primary).sensitive()
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.detail) {
                ForEach(xs) { x in
                    HStack(spacing: AppSpacing.icon) {
                        Circle().fill(currencyColor(x.currency)).frame(width: 8, height: 8)
                        Text(unitText(x.amount, x.currency)).heroAmount(22).monospacedDigit()
                            .rollingNumber(x.amount)
                            .foregroundStyle(x.amount < -0.005 ? Color.loss : Color.primary).sensitive()
                    }
                }
            }
        }
    }
}
