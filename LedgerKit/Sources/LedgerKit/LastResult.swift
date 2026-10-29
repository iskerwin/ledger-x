import Foundation

/// One result kept with what it was worked out from: asked again with the same key, it is handed back instead of
/// worked out again; a different key replaces it. For a page that is drawn again and again while what it shows
/// stays the same.
public final class LastResult<Key: Equatable, Value> {
    private var last: (key: Key, value: Value)?

    public init() {}

    public func value(for key: Key, _ make: () -> Value) -> Value {
        if let last, last.key == key { return last.value }
        let value = make()
        last = (key, value)
        return value
    }
}
