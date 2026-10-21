import Foundation

// 截图记账: what the phone's text recognition read off a screenshot, as pieces with where they are. The
// screenshot itself is never kept — only these pieces, and only until the entry is saved or dismissed.

/// one piece of recognised text; x, y, w, h are fractions of the image, y from the top
public struct OCRBox: Codable, Equatable {
    public var text: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public init(text: String, x: Double, y: Double, w: Double, h: Double) {
        self.text = text; self.x = x; self.y = y; self.w = w; self.h = h
    }
    var mid: Double { y + h / 2 }
}

/// the pieces as the screen's rows, top to bottom, each left to right: a label and its value ("付款方式" …
/// "零钱") are read as separate pieces but sit on one row. Pieces whose vertical middles fall within each
/// other's height share a row.
public func ocrRows(_ boxes: [OCRBox]) -> [[OCRBox]] {
    var rows: [[OCRBox]] = []
    for b in boxes.sorted(by: { $0.mid < $1.mid }) where !b.text.trimmingCharacters(in: .whitespaces).isEmpty {
        if var last = rows.last, let ref = last.first,
           abs(b.mid - ref.mid) < min(b.h, ref.h) * 0.6 {
            last.append(b)
            rows[rows.count - 1] = last
        } else {
            rows.append([b])
        }
    }
    return rows.map { $0.sorted { $0.x < $1.x } }
}

/// the rows as text: pieces on a row separated by a tab
public func ocrText(_ boxes: [OCRBox]) -> String {
    ocrRows(boxes).map { $0.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\t") }.joined(separator: "\n")
}
