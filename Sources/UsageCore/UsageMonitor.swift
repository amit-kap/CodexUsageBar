import Foundation
import Combine

@MainActor
public protocol UsageService: AnyObject {
    var onUsageUpdate: ((UsageSnapshot) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    func readUsage() async throws -> UsageSnapshot
    func stop()
}
extension CodexClient: UsageService {}

@MainActor
public final class UsageMonitor: ObservableObject {
    @Published public private(set) var snapshot: UsageSnapshot?
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var refreshCount = 0
    private let service: UsageService
    private var poller: Task<Void, Never>?
    private let interval: TimeInterval
    private var stopped = false

    public init(service: UsageService? = nil, interval: TimeInterval = 60) {
        let service = service ?? CodexClient()
        self.service = service
        self.interval = interval
        service.onUsageUpdate = { [weak self] update in
            guard let self, !self.stopped else { return }
            self.snapshot = self.snapshot?.merging(update) ?? update
            // Partial model notifications do not prove the main bucket is fresh.
            if update.mainBucket != nil {
                self.lastUpdated = Date()
                self.errorMessage = nil
            }
        }
        service.onDisconnect = { [weak self] in
            guard let self, !self.stopped else { return }
            self.errorMessage = UsageFailure.disconnected.localizedDescription
        }
    }

    public func start() {
        guard poller == nil else { return }
        stopped = false
        poller = Task { [weak self, interval] in
            await self?.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
                catch { break }
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    public func refresh() async {
        guard !isRefreshing, !stopped else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let result = try await service.readUsage()
            guard !stopped else { return }
            snapshot = result
            lastUpdated = Date()
            errorMessage = nil
            refreshCount += 1
        } catch {
            guard !stopped else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func isStale(at now: Date = Date()) -> Bool {
        if errorMessage != nil { return true }
        guard let lastUpdated else { return false }
        return now.timeIntervalSince(lastUpdated) > max(150, interval * 2.5)
    }
    public func freshness(at now: Date = Date()) -> String {
        guard let lastUpdated else { return isRefreshing ? "Connecting to Codex…" : "Waiting for usage" }
        let age = max(0, Int(now.timeIntervalSince(lastUpdated)))
        if age < 10 { return "Updated just now" }
        if age < 60 { return "Updated \(age)s ago" }
        if age < 3600 { return "Updated \(age / 60)m ago" }
        return "Updated \(age / 3600)h ago"
    }
    public func stop() {
        stopped = true
        poller?.cancel()
        poller = nil
        service.stop()
    }
}
