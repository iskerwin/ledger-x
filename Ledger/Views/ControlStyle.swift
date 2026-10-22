import SwiftUI

/// Shared rhythm for controls, supporting text and page content. Chart geometry and keypad sizes
/// are independent of these gaps; changing spacing must not change the meaning of an input.
enum AppSpacing {
    static let detail: CGFloat = 4
    static let icon: CGFloat = 8
    static let control: CGFloat = 12
    static let content: CGFloat = 16
    static let section: CGFloat = 24
    static let spacious: CGFloat = 32
}

extension View {
    /// a figure that rolls to its new value digit by digit instead of jumping (a month, a currency, a save changed it)
    func rollingNumber<V: Equatable>(_ value: V, _ motion: Animation = AppMotion.standard) -> some View {
        contentTransition(.numericText()).animation(motion, value: value)
    }
}

/// The app's three motions, so everything moves alike. 减少动态效果 turns them all off at the root.
enum AppMotion {
    /// a tap's answer: a filter, a chart's selection, a chosen category
    static let quick = Animation.easeOut(duration: 0.2)
    /// something opening, closing or moving to another place: a group, the calendar, the month, a scroll
    static let standard = Animation.spring(duration: 0.35, bounce: 0)
    /// a moment to notice: a notice coming in, something just saved
    static let emphasized = Animation.spring(duration: 0.35, bounce: 0.15)
}

/// Keep the icon beside its title, including in toolbars and wide bordered buttons.
/// The title keeps its original accessibility name; decorative symbols are not read twice.
/// The symbol sits in a square that scales with the text, so a taller glyph cannot
/// change the height of the button it lives in.
struct ControlLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var side = 20.0

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AppSpacing.icon) {
            configuration.icon
                .font(.system(size: side * 0.72))
                .frame(width: side, height: side)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}

/// The same scaled symbol square for a custom row with more than one line of text.
struct ControlIcon: View {
    let systemName: String
    @ScaledMetric(relativeTo: .body) private var side = 20.0

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: side * 0.72))
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

/// Keep action titles readable when their combined width exceeds a small screen or large font.
struct ActionGroup<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !typeSize.isAccessibilitySize {
                HStack(spacing: AppSpacing.control) { content }
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: AppSpacing.control) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One matched set of actions. In a row every button has the same height and the same
/// width, with 12 pt gaps. The row stacks, each button full width, when the labels would
/// no longer fit or when Dynamic Type reaches accessibility XXL. Text is not shrunk.
///
/// The capsule's outer height is the token below. It is not a minimum placed inside a
/// system bordered button, which would add its own padding and draw the control taller.
/// Standard rows are 44 pt. Date capsules (`containsLabel`) stay 36 pt. Text style still
/// follows `size`: large is body semibold, small is subheadline medium. Icon boxes do not change.
/// The filled jade button is the main action. Other actions are jade outlines. A destructive
/// action is a red outline, not a filled button.
struct ActionRow: View {
    enum Size {
        case large
        case small

        /// Outer capsule height at the default text size. Large rows are 44 pt.
        /// Small date capsules are 36 pt. Content can grow past this when Dynamic Type is larger.
        var minHeight: CGFloat { self == .large ? 44 : 36 }
    }

    struct Item {
        enum Emphasis {
            case primary
            case regular
            case destructive
        }

        var title: String
        var systemImage: String
        var emphasis: Emphasis = .regular
        var action: () -> Void
    }

    var size: Size
    var items: [Item]
    /// Extra horizontal padding inside the capsule. Short date titles («今天») need it
    /// so the rounded ends do not clip the label. Other rows leave this off.
    var containsLabel = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isEnabled) private var isEnabled

    private var forcesStack: Bool { typeSize >= .accessibility4 }

    /// Date capsules keep the 36 pt small token. Every other row uses the 44 pt tier
    /// so side-by-side actions match, including rows whose text stays on the small style.
    private var actionHeight: CGFloat { containsLabel ? size.minHeight : Size.large.minHeight }

    var body: some View {
        ActionRowLayout(spacing: AppSpacing.control, minHeight: actionHeight, forcesStack: forcesStack) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                button(item)
            }
        }
        .font(size == .large ? .body.weight(.semibold) : .subheadline.weight(.medium))
    }

    private func button(_ item: Item) -> some View {
        let filled = item.emphasis == .primary
        let tint: Color = item.emphasis == .destructive ? .red : .jade
        return Button(action: item.action) {
            Label(item.title, systemImage: item.systemImage)
                .labelStyle(ControlLabelStyle())
        }
        .buttonStyle(ActionCapsuleStyle(
            filled: filled,
            tint: tint,
            minHeight: actionHeight,
            horizontalPadding: containsLabel ? AppSpacing.content : AppSpacing.icon,
            enabled: isEnabled
        ))
    }
}

/// Capsule drawn to `minHeight`, with the label padded inside the rounded ends.
/// System bordered buttons pad outside a minimum and end up taller than the token.
private struct ActionCapsuleStyle: ButtonStyle {
    var filled: Bool
    var tint: Color
    var minHeight: CGFloat
    var horizontalPadding: CGFloat
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .foregroundStyle(filled ? Color.onJade : tint)
            .background(Capsule().fill(filled ? tint : Color.clear))
            .overlay(Capsule().strokeBorder(filled ? Color.clear : tint, lineWidth: 1))
            .contentShape(Capsule())
            .opacity(!enabled ? 0.45 : (configuration.isPressed ? 0.55 : 1))
    }
}

/// Places one set of buttons, either in equal columns or in a full-width stack.
/// Both arrangements are not built together, so each action exists once.
private struct ActionRowLayout: Layout {
    var spacing: CGFloat
    var minHeight: CGFloat
    var forcesStack: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = ideals(of: subviews)
        let width = proposal.width
        let stacked = shouldStack(ideals, in: width)
        let column = columnWidth(proposed: width, count: subviews.count, stacked: stacked, ideals: ideals)
        let height = rowHeight(subviews, column: column)
        let totalWidth = width ?? naturalWidth(ideals)
        if stacked {
            let count = CGFloat(subviews.count)
            return CGSize(width: totalWidth, height: count * height + spacing * max(0, count - 1))
        }
        return CGSize(width: totalWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let ideals = ideals(of: subviews)
        let stacked = shouldStack(ideals, in: bounds.width)
        let column = columnWidth(proposed: bounds.width, count: subviews.count, stacked: stacked, ideals: ideals)
        let height = rowHeight(subviews, column: column)
        if stacked {
            var y = bounds.minY
            for subview in subviews {
                subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + spacing
            }
            return
        }
        let count = CGFloat(subviews.count)
        let slot = max(0, (bounds.width - spacing * max(0, count - 1)) / max(1, count))
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: slot, height: height))
            x += slot + spacing
        }
    }

    private func ideals(of subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    private func shouldStack(_ ideals: [CGSize], in width: CGFloat?) -> Bool {
        guard ideals.count > 1 else { return false }
        if forcesStack { return true }
        guard let width, width > 1 else { return false }
        let count = CGFloat(ideals.count)
        let slot = (width - spacing * (count - 1)) / count
        return ideals.contains { $0.width > slot + 0.5 }
    }

    private func naturalWidth(_ ideals: [CGSize]) -> CGFloat {
        let widest = ideals.map(\.width).max() ?? 0
        let count = CGFloat(ideals.count)
        return widest * count + spacing * max(0, count - 1)
    }

    private func columnWidth(proposed: CGFloat?, count: Int, stacked: Bool, ideals: [CGSize]) -> CGFloat {
        let count = CGFloat(count)
        if stacked { return proposed ?? (ideals.map(\.width).max() ?? 0) }
        if let proposed { return max(0, (proposed - spacing * max(0, count - 1)) / max(1, count)) }
        return ideals.map(\.width).max() ?? 0
    }

    private func rowHeight(_ subviews: Subviews, column: CGFloat) -> CGFloat {
        let measured = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
        return max(minHeight, measured.max() ?? minHeight)
    }
}
