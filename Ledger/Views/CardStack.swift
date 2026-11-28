import SwiftUI

/// Cards stacked as Wallet keeps its passes (订阅管理's subscriptions, 账户's accounts with 卡面): each card behind shows
/// its top strip, the front one is whole. A card opens in place (`CardOpening`). `items` go from the back to the
/// front: the last is drawn whole, on top.
struct CardStack<Item, Card: View>: View {
    @Environment(CardOpening.self) private var opening
    let items: [Item]
    /// what opens it (`CardOpening.key`)
    let key: (Item) -> String
    let identifier: (Item) -> String
    /// a card; `still` for one only drawn, its place kept while it is open
    @ViewBuilder let card: (Item, Bool) -> Card
    /// the strip each card behind the front one shows: its padding and the name's line, larger with the text
    @ScaledMetric(relativeTo: .subheadline) private var peek: CGFloat = 50

    var body: some View {
        let cards = items.enumerated().map { (i: $0.offset, k: key($0.element), item: $0.element) }
        VStack(spacing: 0) {
            ForEach(cards, id: \.k) { i, k, item in
                let front = i == items.count - 1
                Group {
                    if opening.key == k {
                        // gone to the top of the page: its place kept for it
                        card(item, true).hidden()
                    } else {
                        Button { opening.open(k) } label: { card(item, false) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(identifier(item))
                            .modifier(CardMatch(key: k))
                    }
                }
                // laid out whole whatever height it is given
                .fixedSize(horizontal: false, vertical: true)
                // while one is open the others are down below the screen, as Wallet's
                .modifier(CardAway(away: opening.key != nil && opening.key != k, bottom: opening.bottom))
                // the ones behind take only their strip; the rest of each lies under the card in front of it
                .frame(height: front ? nil : peek, alignment: .top)
                .zIndex(Double(i))
            }
        }
    }
}

/// the open card of a page of stacks, as Wallet opens a pass: the card moves to the top of the page and the others
/// go down below the screen, with its page under it; closing puts every card back. The stacks and the open card are
/// drawn outside any List, so one card moves between them with `matchedGeometryEffect`.
@Observable final class CardOpening {
    /// the open card, by its key (a subscription's link: a rename keeps it; an account's name)
    private(set) var key: String?
    /// the screen's bottom edge, in window space: how far a card goes to be below it
    var bottom: CGFloat = 0
    var reduceMotion = false

    func open(_ key: String) { withAnimation(motion) { self.key = key } }
    func close() { withAnimation(motion) { key = nil } }
    /// at once: what it is for is gone, or the ledger changed
    func reset() { key = nil }

    /// 减少动态效果: the open card fades in where it opens, nothing moves
    private var motion: Animation { reduceMotion ? AppMotion.quick : .spring(duration: 0.5, bounce: 0.12) }
}

/// where an open card sits at the top of its page: the page's margins
struct OpenCardPlace: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, AppSpacing.content).padding(.top, AppSpacing.control)
    }
}

/// the one card moving between its stack and the top of the open page; with 减少动态效果 it does not move
struct CardMatch: ViewModifier {
    @Environment(CardOpening.self) private var opening
    @Environment(\.cardSpace) private var ns
    let key: String
    func body(content: Content) -> some View {
        if opening.reduceMotion || ns == nil { content.transition(.opacity) } else {
            content.matchedGeometryEffect(id: key, in: ns!).transition(.identity)
        }
    }
}

extension EnvironmentValues {
    /// where a page's cards move between its stacks and the open card (`CardMatch`)
    @Entry var cardSpace: Namespace.ID? = nil
}

/// a card down below the screen while another is open; one above the screen stays there
private struct CardAway: ViewModifier {
    @Environment(CardOpening.self) private var opening
    let away: Bool
    let bottom: CGFloat
    func body(content: Content) -> some View {
        if opening.reduceMotion { content.opacity(away ? 0 : 1) } else {
            content.visualEffect { view, proxy in
                let frame = proxy.frame(in: .global)
                // past the edge by its shadow too
                return view.offset(y: away && frame.maxY > 0 ? max(0, bottom + AppSpacing.content - frame.minY) : 0)
            }
        }
    }
}

extension View {
    /// a page of stacks (`CardStack`): its open card, where its cards move, and the screen's bottom edge
    func cardStacks(_ opening: CardOpening, in space: Namespace.ID) -> some View {
        modifier(CardStacks(opening: opening, space: space))
    }
}

private struct CardStacks: ViewModifier {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let opening: CardOpening
    let space: Namespace.ID
    func body(content: Content) -> some View {
        content
            .background(Color(.systemGroupedBackground))
            // the screen's bottom edge: past the page's, under the home indicator, where the scrolled cards still show
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY + $0.safeAreaInsets.bottom } action: { opening.bottom = $0 }
            .environment(opening)
            .environment(\.cardSpace, space)
            .onChange(of: store.cfg.id) { _, _ in opening.reset() }
            .onChange(of: reduceMotion, initial: true) { _, on in opening.reduceMotion = on }
    }
}
