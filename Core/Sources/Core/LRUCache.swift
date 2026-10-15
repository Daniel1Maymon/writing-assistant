/// Suggestions per sentence, so unchanged or repeated sentences aren't checked again.
public struct CacheKey: Hashable, Sendable {
    public let sentenceHash: String
    /// Bumped whenever the ignore list changes, so stale results aren't reused.
    public let ignoreVersion: Int

    public init(sentenceHash: String, ignoreVersion: Int) {
        self.sentenceHash = sentenceHash
        self.ignoreVersion = ignoreVersion
    }
}

/// Small least-recently-used cache. Capacities are in the hundreds, so a linear order list is fine.
public struct LRUCache<Key: Hashable, Value> {
    public let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []  // least recently used first

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { values.count }

    public mutating func get(_ key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    public mutating func set(_ key: Key, _ value: Value) {
        values[key] = value
        touch(key)
        if order.count > capacity {
            values[order.removeFirst()] = nil
        }
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
