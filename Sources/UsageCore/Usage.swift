import Foundation

public struct UsageWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public var percentage: Double? {
        guard let value = usedPercent, value.isFinite else { return nil }
        return min(100, max(0, value))
    }
    public var label: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "Usage window" }
        if minutes == 10080 { return "Weekly" }
        if minutes == 1440 { return "Daily" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
    public var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
    public func resetDescription(now: Date = Date()) -> String {
        guard let date = resetDate else { return "Reset time unavailable" }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "Reset due · awaiting update" }
        if seconds < 60 { return "Resets in less than a minute" }
        let minutes = seconds / 60
        if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes)m"
    }
}

public struct CreditBalance: Codable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: String?
}

public struct UsageBucket: Codable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let credits: CreditBalance?
    public let planType: String?
    public let rateLimitReachedType: String?
    public let spendControlReached: Bool?

    public var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }
    public var mostUsedWindow: UsageWindow? {
        windows.filter { $0.percentage != nil }.max { ($0.percentage ?? 0) < ($1.percentage ?? 0) }
    }
    public var displayName: String {
        if limitId == "codex" { return "Codex" }
        return limitName ?? limitId ?? "Codex"
    }
}

public struct ResetCredits: Codable, Equatable, Sendable {
    public let availableCount: Int?
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let rateLimits: UsageBucket?
    public let rateLimitsByLimitId: [String: UsageBucket]?
    public let rateLimitResetCredits: ResetCredits?

    public var buckets: [(id: String, bucket: UsageBucket)] {
        if let map = rateLimitsByLimitId, !map.isEmpty {
            return map.map { (id: $0.key, bucket: $0.value) }.sorted {
                if $0.id == "codex" { return $1.id != "codex" }
                if $1.id == "codex" { return false }
                return $0.id < $1.id
            }
        }
        return rateLimits.map { [(id: $0.limitId ?? "codex", bucket: $0)] } ?? []
    }
    public var mainBucket: UsageBucket? {
        if let map = rateLimitsByLimitId, !map.isEmpty {
            // Never accidentally show Spark/reserve as the main Codex allowance.
            return map["codex"]
        }
        guard rateLimits?.limitId == nil || rateLimits?.limitId == "codex" else { return nil }
        return rateLimits
    }
    public var mainWindow: UsageWindow? { mainBucket?.mostUsedWindow }

    /// Notifications may contain only one bucket. Preserve all other known limits.
    public func merging(_ update: UsageSnapshot) -> UsageSnapshot {
        var map = Dictionary(uniqueKeysWithValues: buckets.map { ($0.id, $0.bucket) })
        if let changes = update.rateLimitsByLimitId {
            map.merge(changes, uniquingKeysWith: { _, new in new })
        }
        if let bucket = update.rateLimits {
            let id = bucket.limitId ?? "codex"
            if update.rateLimitsByLimitId?[id] == nil { map[id] = bucket }
        }
        return UsageSnapshot(rateLimits: update.rateLimits ?? rateLimits,
                             rateLimitsByLimitId: map,
                             rateLimitResetCredits: update.rateLimitResetCredits ?? rateLimitResetCredits)
    }
}

public struct LineBuffer: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        // A corrupted peer should not grow memory without a bound.
        if buffer.count > 8 * 1024 * 1024 { buffer.removeAll() }
        return lines
    }
}

public enum UsageFailure: LocalizedError {
    case cliMissing, disconnected, timeout, invalidResponse, remote(String)
    public var errorDescription: String? {
        switch self {
        case .cliMissing: return "Codex could not be found. Install Codex, then refresh."
        case .disconnected: return "Codex disconnected. Refresh to reconnect."
        case .timeout: return "Codex did not respond in time. Check your connection and refresh."
        case .invalidResponse: return "Codex returned an unreadable usage response. Try updating Codex."
        case .remote(let message): return message
        }
    }
}
