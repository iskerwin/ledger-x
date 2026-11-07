import SwiftUI
import LedgerKit

/// The phone's look, in the same values (`Ledger/Views/Theme.swift`, `DonutView.swift`): this target shares none of its code.
extension Color {
    /// 翡翠, the phone's default accent
    static let jade = dynamic(0x2B806A, 0x4FB598)
    /// money in and money out, whatever the accent, dark enough to read as text
    static let gain = dynamic(0x248A3D, 0x30D158)
    static let loss = dynamic(0xD70015, 0xFF453A)
    static let page = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)

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
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// a day, written as in the ledger and the journal whatever the system's language; a calendar to change it
struct DateRow: View {
    let title: String
    @Binding var day: String
    var latest: Date?
    @State private var choosing = false

    var body: some View {
        LabeledContent(title) {
            Button(day) { choosing = true }
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

    private var date: Binding<Date> {
        Binding(get: { Day.date(day) ?? Date() }, set: { day = Day.string($0) })
    }
}
