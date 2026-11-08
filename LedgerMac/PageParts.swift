import SwiftUI
import LedgerKit

/// a list down the left and what's picked in it on the right, on one ground, as the accounts page
struct SplitPage<List: View, Detail: View>: View {
    var listWidth: CGFloat = 300
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { list }
                    .padding(10)
            }
            .frame(width: listWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color.page)
    }
}

/// a line of such a list: what it is, a line under it, an amount; picked, on the accent
struct PickRow: View {
    let title: String
    var caption = ""
    var trailing = ""
    var symbol: String?
    var tint = Color.primary
    let picked: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(picked ? Color.white : tint)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    if !caption.isEmpty {
                        Text(caption).font(.caption).foregroundStyle(picked ? Color.white.opacity(0.8) : Color.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !trailing.isEmpty {
                    Text(trailing).monospacedDigit().lineLimit(1)
                }
            }
            .foregroundStyle(picked ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(picked ? Color.jade : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

/// a card's name on its first line, with what goes at its end
struct CardTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).fontWeight(.medium)
            Spacer()
            trailing
        }
        .padding(.bottom, 8)
    }
}

extension CardTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// a line of figures on a card: what it is on the left, the amount on the right
struct FigureRow: View {
    let label: String
    var caption = ""
    let value: String
    var color = Color.primary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).lineLimit(1)
                if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            Text(value).monospacedDigit().foregroundStyle(color).lineLimit(1)
        }
        .padding(.vertical, 6)
    }
}

/// "11/08", with the year when it isn't this one
func shortDay(_ date: String) -> String {
    let short = date.dropFirst(5).replacingOccurrences(of: "-", with: "/")
    return date.prefix(4) == Day.today().prefix(4) ? short : date.replacingOccurrences(of: "-", with: "/")
}

/// an amount in the operating currency, for adding up what's in several
func inBase(_ ledger: Ledger, _ amount: Double, _ currency: String, on date: String = Day.today()) -> Double {
    toCNY(ledger, amount, currency, date) ?? 0
}
