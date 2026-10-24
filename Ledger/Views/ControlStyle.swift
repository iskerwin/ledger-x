import SwiftUI
import Charts
import LedgerKit

/// Shared rhythm for controls, supporting text and page content. Chart geometry and keypad sizes
/// are independent of these gaps; changing spacing must not change the meaning of an input.
enum AppSpacing {
    static let detail: CGFloat = 4
    static let icon: CGFloat = 8
    static let control: CGFloat = 12
    static let content: CGFloat = 16
}

/// Corner radii: a card 22, a panel inside one 14, a key or a control 12, a tile 8, a tiny mark 4
enum AppRadius {
    static let card: CGFloat = 22
    static let panel: CGFloat = 14
    static let control: CGFloat = 12
    static let tile: CGFloat = 8
    static let mini: CGFloat = 4
}

extension View {
    /// a figure that rolls to its new value digit by digit instead of jumping (a month, a currency, a save changed it)
    func rollingNumber<V: Equatable>(_ value: V, _ motion: Animation = AppMotion.standard) -> some View {
        contentTransition(.numericText()).animation(motion, value: value)
    }
}

/// The big amount at the top of a page (本月支出, 净资产, a card's balance): rounded bold, one size everywhere, and it
/// grows with the text size like the rest of the page. Only when a long amount would not fit on one line does it
/// shrink, down to half.
struct HeroAmount: ViewModifier {
    @ScaledMetric private var size: CGFloat

    init(_ base: CGFloat) { _size = ScaledMetric(wrappedValue: base, relativeTo: .largeTitle) }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
    }
}

/// Picking an x value (a month, a day) on a chart by finger. A tap picks it, or lets it go when it is the one picked;
/// a finger drawn sideways follows it, with a light tick at each new value, and the last one stays picked. An
/// up-and-down drag is left to the page, so the chart never takes the scroll.
struct ChartPick<X: Plottable & Equatable>: ViewModifier {
    let tap: (X) -> Void
    let slide: (X) -> Void
    /// two values that are the same point (dates within one month): no new tick between them
    var same: (X, X) -> Bool = { $0 == $1 }
    @State private var last: X?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                let layer = Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        if let x = value(proxy, geo, location) { tap(x); Learned.chart.mark() }
                    }
                if #available(iOS 18, *) {
                    layer.gesture(SidePan(slide: { follow(proxy, geo, $0) }, ended: { _, _ in last = nil }))
                } else {
                    layer.simultaneousGesture(DragGesture(minimumDistance: 8)
                        .onChanged { g in
                            guard abs(g.translation.width) > abs(g.translation.height) else { return }
                            follow(proxy, geo, g.location)
                        }
                        .onEnded { _ in last = nil })
                }
            }
        }
    }

    private func follow(_ proxy: ChartProxy, _ geo: GeometryProxy, _ location: CGPoint) {
        guard let x = value(proxy, geo, location), !(last.map { same($0, x) } ?? false) else { return }
        last = x
        slide(x)
        Learned.chart.mark()
        Haptics.selection()
    }

    private func value(_ proxy: ChartProxy, _ geo: GeometryProxy, _ location: CGPoint) -> X? {
        guard let plot = proxy.plotFrame else { return nil }
        return proxy.value(atX: location.x - geo[plot].origin.x)
    }
}

/// A sideways drag on a chart, in UIKit (iOS 18): a SwiftUI DragGesture there takes every drag that starts on it,
/// so the page under it no longer scrolls. This pan starts only when the finger moves more sideways than up or
/// down; otherwise it never begins and the page scrolls.
/// A month swipe uses it too: under load the list's own pan could take a SwiftUI drag's sideways swipe first.
@available(iOS 18, *)
private struct SidePan: UIGestureRecognizerRepresentable {
    var slide: (CGPoint) -> Void = { _ in }
    /// how far the finger went, and how fast it was moving sideways when it lifted
    let ended: (CGSize, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed: slide(context.converter.localLocation)
        case .ended, .cancelled, .failed:
            // from where the finger came down: a quick flick only begins the pan near its end
            let a = context.coordinator.start ?? pan.location(in: nil), b = pan.location(in: nil)
            ended(pan.state == .ended ? CGSize(width: b.x - a.x, height: b.y - a.y) : .zero, pan.velocity(in: nil).x)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start: CGPoint?

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            start = touch.location(in: nil)
            return true
        }

        /// alongside whatever else the touch starts (the page's scrolling, the list row's own gestures): when one of
        /// them was first, a quick sideways flick was taken from this and the month or chart did not move. This
        /// begins only for a sideways drag, so the page still has every up-and-down one to itself.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let v = pan.velocity(in: pan.view)
            return abs(v.x) > abs(v.y)
        }
    }
}

extension View {
    func chartPick<X: Plottable & Equatable>(_ type: X.Type, tap: @escaping (X) -> Void, slide: @escaping (X) -> Void) -> some View {
        modifier(ChartPick(tap: tap, slide: slide))
    }
    /// dates picked by the month they fall in
    func chartPickMonth(tap: @escaping (Date) -> Void, slide: @escaping (Date) -> Void) -> some View {
        modifier(ChartPick<Date>(tap: tap, slide: slide, same: { Day.ym(Day.string($0)) == Day.ym(Day.string($1)) }))
    }
}

extension View {
    /// every list's search: always shown under the title, like the journal's; floats as glass while scrolling (iOS 26)
    func appSearchable(text: Binding<String>, prompt: String) -> some View {
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
    }

    /// the page's main action at the bottom: the filled theme button, large, semibold — one look everywhere
    func primaryButton(tint: Color = .jade) -> some View {
        buttonStyle(.borderedProminent).tint(tint).controlSize(.large).fontWeight(.semibold)
    }
}

/// What is wrong with a form, under what it would write: an error (red, ✕) blocks saving, a warning (orange, △)
/// only tells. One look in every form.
struct ValidationRow: View {
    let message: String
    var warning = false

    var body: some View {
        Label(message, systemImage: warning ? "exclamationmark.triangle" : "xmark.octagon").labelStyle(ControlLabelStyle())
            .font(.footnote).foregroundStyle(warning ? Color.warn : Color.loss)
    }
}

extension View {
    /// A row's actions: on a swipe from `edge` (never a full swipe that runs one by itself) and in the long-press
    /// menu, the same buttons — so a long press and VoiceOver's actions reach them too. Colours: delete red (its
    /// role), change orange (`Color.warn`), confirm the theme colour, set aside grey.
    func rowActions<A: View>(edge: HorizontalEdge = .trailing, @ViewBuilder _ actions: () -> A) -> some View {
        let a = actions()
        // the actions coming into sight: a row has been swiped (or pressed), so its hints have done their work
        return swipeActions(edge: edge, allowsFullSwipe: false) { a.onAppear { Learned.swipe.mark() } }
            .contextMenu { a.onAppear { Learned.swipe.mark() } }
    }
}

/// A page waiting for the ledger to load: one view, so a better placeholder later changes every page at once
struct PageLoading: View {
    var body: some View { ProgressView() }
}

/// A page's shape in grey while the ledger loads (概览: the card, then rows; 明细: rows), in place of a spinner on
/// an empty page. It breathes softly; 减少动态效果 keeps it still.
struct PageSkeleton: View {
    var card = true
    var rows = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        List {
            if card {
                Section {
                    VStack(alignment: .leading, spacing: AppSpacing.control) {
                        bar(70, 12)
                        bar(180, 34)
                        bar(220, 10)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
                }
            }
            Section {
                ForEach(0..<rows, id: \.self) { i in
                    HStack(spacing: AppSpacing.icon) {
                        RoundedRectangle(cornerRadius: AppRadius.tile, style: .continuous).fill(.quaternary).frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: AppSpacing.detail) {
                            bar(i.isMultiple(of: 2) ? 140 : 110, 12)
                            bar(80, 10)
                        }
                        Spacer()
                        bar(60, 12)
                    }
                    .padding(.vertical, AppSpacing.detail)
                }
            }
        }
        .scrollDisabled(true)
        .opacity(dim ? 0.45 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LS("正在加载账本…"))
        .accessibilityIdentifier("page.skeleton")
    }

    private func bar(_ w: CGFloat, _ h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: AppRadius.mini, style: .continuous).fill(.quaternary).frame(width: w, height: h)
    }
}

/// A button's title while its work runs: the spinner in its place, the same size, so the button doesn't jump
struct BusyLabel: View {
    let busy: Bool
    let title: String
    let systemImage: String

    var body: some View {
        if busy { ProgressView() } else { Label(title, systemImage: systemImage).labelStyle(ControlLabelStyle()) }
    }
}

/// 保存 in a sheet's bar: the one title, symbol and weight everywhere
struct SaveLabel: View {
    var title = LS("保存")
    var body: some View { Label(title, systemImage: "checkmark").labelStyle(ControlLabelStyle()).fontWeight(.semibold) }
}

/// Sheets come in three sizes. A picker (an account, a currency, a day, a tag, an icon, a quick look) opens at half
/// the screen with its grabber showing, and drags up to full; a form to fill in, and content to read, take the whole
/// screen (the system's own default, said where a sheet once chose otherwise).
extension View {
    func pickerSheet() -> some View { presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
    /// a picker with a search field: `detent` goes to full when typing starts, so the keyboard doesn't cover the results
    func pickerSheet(_ detent: Binding<PresentationDetent>) -> some View {
        presentationDetents([.medium, .large], selection: detent).presentationDragIndicator(.visible)
    }
    func formSheet() -> some View { presentationDetents([.large]) }
}

extension View {
    /// a page's headline amount; 40 for the overview's, 22 for one line among several currencies
    func heroAmount(_ base: CGFloat = 34) -> some View { modifier(HeroAmount(base)) }
}

/// A month's (or year's) name that slides in from the side it was moved towards: › brings it in from the right,
/// ‹ from the left. The old name only fades, so turning round never sends it out the wrong way.
struct SlidingTitle: View {
    let text: String
    let forward: Bool

    var body: some View {
        ZStack {
            // one line: a large text size shrinks the name a little rather than breaking "2026年" in two
            Text(text).lineLimit(1).minimumScaleFactor(0.5).id(text)
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity), removal: .opacity))
        }
        .clipped()
        .animation(AppMotion.standard, value: text)
    }
}

/// The gestures a hint teaches. Each is learned the first time it is used anywhere on this phone, and from then on
/// its hints are not shown (使用指南 → 手势 keeps them all)
enum Learned: String {
    case chart, expand, swipe, hold
    var key: String { "ledger.learned." + rawValue }
    func mark() { if !UserDefaults.standard.bool(forKey: key) { UserDefaults.standard.set(true, forKey: key) } }
    /// the tests start from nothing learned
    static func forget() { for g in [chart, expand, swipe, hold] { UserDefaults.standard.removeObject(forKey: g.key) } }
}

/// A footer's explanation, then how it is done (左滑…, 长按…) until that gesture has been used
struct HintFooter: View {
    let text: String
    let tip: String
    @AppStorage private var learned: Bool
    init(_ text: String, tip: String, _ gesture: Learned) {
        self.text = text; self.tip = tip
        _learned = AppStorage(wrappedValue: false, gesture.key)
    }
    var body: some View { Text(learned ? text : text + tip) }
}

/// ‹ title ›, one look for every month (or year) switcher: 概览, 报表 and the calendars. The title sits in the
/// middle; beside it, while away from now, the way back (本月, 今年, 今天), whose coming and going moves nothing.
struct PeriodBar: View {
    let title: String
    /// sortable ("2026-10", "2026"): a later one slides in from the right
    let key: String
    /// the way back's name, and whether it is shown (away from now, and now can be reached)
    let backTitle: String
    let away: Bool
    var previousLabel = LS("上个月"), nextLabel = LS("下个月")
    var canGoBack = true, canGoOn = true
    /// on a light capsule of its own (a bar in a list); in a card, without
    var capsule = true
    var backID: String? = nil
    var titleID: String? = nil
    /// the widest title this bar will show (the year's longest month name): the title's room, and so the layout
    /// chosen, are the same from one month to the next. Sized to the title itself, a wider month (2026年10月) could
    /// get another layout than a narrower one (2026年9月) and the title jumped as the way back came and went.
    var widest: String? = nil
    let step: (Int) -> Void
    let toNow: () -> Void
    /// the key shown before: the direction a new title slides in from
    @State private var shown: String?

    var body: some View {
        // the first that fits: the title in the middle (the way back's room kept on the other side too), the title
        // moved over for it, the way back as an icon with the title shrinking a little if it must
        ViewThatFits(in: .horizontal) {
            row(back(Text(backTitle)), even: true)
            row(back(Text(backTitle)), even: false)
            row(back(Image(systemName: "calendar")), even: false, squeeze: true)
        }
        .buttonStyle(.borderless)
        .tint(Color.jade)
        .padding(.horizontal, capsule ? AppSpacing.control : 0).padding(.vertical, capsule ? AppSpacing.icon : 0)
        .background(capsule ? Color(.secondarySystemGroupedBackground) : .clear, in: Capsule())
        .onAppear { shown = key }
        .onChange(of: key) { _, k in shown = k }
    }

    /// shown away from now only, its room always kept, so its coming and going moves nothing
    /// squeeze: the last one, where the title shrinks a little to fit (a large text size, a narrow bar)
    private func row(_ way: some View, even: Bool, squeeze: Bool = false) -> some View {
        HStack(spacing: AppSpacing.detail) {
            arrow("chevron.left", previousLabel, enabled: canGoBack) { step(-1) }
            Spacer(minLength: 0)
            if even { way.hidden().accessibilityHidden(true) }
            ZStack {
                Text(widest ?? title).font(.headline).lineLimit(1).minimumScaleFactor(0.5).hidden().accessibilityHidden(true)
                SlidingTitle(text: title, forward: key >= (shown ?? key)).font(.headline)
                    .accessibilityIdentifier(titleID ?? "period.title")
            }
            .fixedSize(horizontal: !squeeze, vertical: false)
            ZStack {
                way.hidden().accessibilityHidden(true)
                if away { way.transition(.opacity) }
            }
            .animation(AppMotion.quick, value: away)
            Spacer(minLength: 0)
            arrow("chevron.right", nextLabel, enabled: canGoOn) { step(1) }
        }
    }

    /// the longest of `month`'s year's month names
    static func widestMonth(_ month: String) -> String {
        let year = month.prefix(4)
        return (1...12).map { Day.monthLabel(String(format: "%@-%02d", String(year), $0)) }.max { $0.count < $1.count } ?? Day.monthLabel(month)
    }

    private func arrow(_ symbol: String, _ label: String, enabled: Bool, _ go: @escaping () -> Void) -> some View {
        Button(action: go) { Image(systemName: symbol).font(.body.weight(.semibold)).frame(minWidth: 24, minHeight: 28) }
            .disabled(!enabled)
            .accessibilityLabel(label)
    }

    private func back(_ label: some View) -> some View {
        Button(action: toNow) {
            label.font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, AppSpacing.control).padding(.vertical, AppSpacing.detail)
                .foregroundStyle(Color.jade)
                .background(Color.jade.soft, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(backTitle)
        .accessibilityIdentifier(backID ?? "period.now")
    }
}

/// A month bar swiped sideways steps the month, like its arrows: a finger drawn to the left goes on to the next one,
/// to the right back to the one before, with a light tick. An up-and-down drag is left to the page.
struct MonthSwipe: ViewModifier {
    let back: () -> Void
    let forward: (() -> Void)?

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.contentShape(Rectangle()).gesture(SidePan(ended: swiped))
        } else {
            content.contentShape(Rectangle()).gesture(
                DragGesture(minimumDistance: 20).onEnded { v in swiped(v.translation, v.velocity.width) }
            )
        }
    }

    /// far enough, or a short quick flick
    private func swiped(_ t: CGSize, _ speed: CGFloat) {
        let dx = t.width
        guard abs(dx) > 40 || (abs(dx) > 16 && abs(speed) > 500), abs(dx) > abs(t.height) * 1.5 else { return }
        if dx > 0 { back(); Haptics.selection() } else if let forward { forward(); Haptics.selection() }
    }
}

extension View {
    /// `forward` nil when there is no later month to go to
    func monthSwipe(back: @escaping () -> Void, forward: (() -> Void)?) -> some View {
        modifier(MonthSwipe(back: back, forward: forward))
    }
}

/// A short side-to-side shake each time `trigger` goes up: a save that was turned back points at why.
/// 减少动态效果 keeps it still.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat { get { travel } set { travel = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(travel * .pi * 4), y: 0))
    }
}

private struct Shake: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.modifier(ShakeEffect(travel: reduceMotion ? 0 : CGFloat(trigger)))
            .animation(reduceMotion ? nil : .linear(duration: 0.4), value: trigger)
    }
}

extension View {
    func shake(_ trigger: Int) -> some View { modifier(Shake(trigger: trigger)) }
}

extension View {
    /// a row whose page opens out of it (iOS 18's zoom; before that, the usual push)
    @ViewBuilder func zoomSource(_ id: some Hashable, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { matchedTransitionSource(id: id, in: ns) } else { self }
    }

    /// the page opened from a `zoomSource` row; 减少动态效果 makes the system fade it in instead
    @ViewBuilder func zoomed(from id: some Hashable, in ns: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { navigationTransition(.zoom(sourceID: id, in: ns)) } else { self }
    }
}

/// Rows coming into or leaving a list (a change saved, removed, synced) slide in and out in step, the same on
/// every list, instead of the list jumping; 减少动态效果 changes it at once
private struct ListChanges<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : AppMotion.standard, value: value)
    }
}

extension View {
    func listChanges(_ value: some Equatable) -> some View { modifier(ListChanges(value: value)) }
}

/// The ˅ of 显示全部 / 收起: one arrow turning where it is, with the rows it opens, instead of two arrows swapped
struct TurningChevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
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

/// A light answer to a finger on a drawn control (a card, a chip, a category): it shrinks a little and dims while
/// held, and settles back on release. The scale is drawing only; the layout and the place that takes the tap stay
/// put. 减少动态效果 keeps the dimming without the scale.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PressedLook(pressed: configuration.isPressed))
    }
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
            .opacity(enabled ? 1 : 0.45)
            .modifier(PressedLook(pressed: configuration.isPressed))
    }
}

/// `PressStyle`'s look, also for a style that draws its own button
private struct PressedLook: ViewModifier {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .opacity(pressed ? 0.8 : 1)
            .animation(AppMotion.quick, value: pressed)
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
