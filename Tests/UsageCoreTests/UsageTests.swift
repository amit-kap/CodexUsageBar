import Foundation
import UsageCore

private func decode(_ json: String) throws -> UsageSnapshot {
    try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
}
private let fixture = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":23,"windowDurationMins":300},"secondary":{"usedPercent":67,"windowDurationMins":10080}},"spark":{"limitId":"spark","primary":{"usedPercent":98,"windowDurationMins":300}}}}"#

@MainActor final class UsageTests {
    func testDisplayWindowsPreservesBothWindows() throws {
        let weeklyFirst = try decode(fixture).mainBucket!
        expectEqual(weeklyFirst.displayWindows.map { $0.label }, ["Weekly", "5-hour"])
        expectEqual(weeklyFirst.displayWindows.map { $0.percentage }, [67, 23])
        let primaryFirst = try decode(#"{"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300},"secondary":{"usedPercent":20,"windowDurationMins":10080}}}"#).mainBucket!
        expectEqual(primaryFirst.displayWindows.map { $0.label }, ["5-hour", "Weekly"])
        let missing = try decode(#"{"rateLimits":{"primary":{},"secondary":{"usedPercent":20}}}"#).mainBucket!
        expectEqual(missing.displayWindows.map { $0.percentage }, [20, nil])
        let single = try decode(#"{"rateLimits":{"secondary":{"usedPercent":20}}}"#).mainBucket!
        expectEqual(single.displayWindows.count, 1)
        let equal = try decode(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":20,"windowDurationMins":10080}}}"#).mainBucket!
        expectEqual(equal.displayWindows.map { $0.label }, ["5-hour", "Weekly"])
    }
    func testPrefersMultiBucketAndMostConstrainedMainWindow() throws {
        let usage = try decode(fixture)
        expectEqual(usage.mainWindow?.percentage, 67)
        expectEqual(usage.mainWindow?.label, "Weekly")
        expectEqual(usage.buckets.first?.id, "codex")
    }
    func testMissingValuesAreNotZero() throws {
        let usage = try decode(#"{"rateLimits":{"primary":{"usedPercent":null}}}"#)
        expectNil(usage.mainWindow)
        expectNil(usage.mainBucket?.primary?.percentage)
        expectEqual(usage.mainBucket?.primary?.label, "Usage window")
    }
    func testDoesNotSubstituteDifferentModelBucket() throws {
        let usage = try decode(#"{"rateLimitsByLimitId":{"spark":{"primary":{"usedPercent":50}}}}"#)
        expectNil(usage.mainBucket)
    }
    func testLegacyPayloadAndClamping() throws {
        let usage = try decode(#"{"rateLimits":{"primary":{"usedPercent":130,"windowDurationMins":60},"secondary":{"usedPercent":-3}}}"#)
        expectEqual(usage.mainWindow?.percentage, 100)
        expectEqual(usage.mainBucket?.secondary?.percentage, 0)
        expectEqual(usage.mainWindow?.label, "1-hour")
    }
    func testNotificationPreservesUnrelatedBuckets() throws {
        let initial = try decode(fixture)
        let update = try decode(#"{"rateLimits":{"limitId":"spark","primary":{"usedPercent":99,"windowDurationMins":300}}}"#)
        let result = initial.merging(update)
        expectEqual(result.buckets.count, 2)
        expectEqual(result.mainWindow?.percentage, 67)
        expectEqual(result.rateLimitsByLimitId?["spark"]?.primary?.percentage, 99)
    }
    func testResetDoesNotInventUnusedCapacity() throws {
        let usage = try decode(#"{"rateLimits":{"primary":{"usedPercent":100,"resetsAt":10}}}"#)
        expectEqual(usage.mainWindow?.resetDescription(now: Date(timeIntervalSince1970: 20)), "Reset due · awaiting update")
        expectEqual(usage.mainWindow?.percentage, 100)
    }
    func testChunkedAndMultipleProtocolLines() {
        var buffer = LineBuffer()
        expectTrue(buffer.append(Data("{\"id\":1".utf8)).isEmpty)
        let lines = buffer.append(Data("}\n\n{\"id\":2}\npart".utf8))
        expectEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"id\":1}", "{\"id\":2}"])
        expectEqual(buffer.append(Data("ial\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["partial"])
    }
}

@MainActor
private final class MockService: UsageService {
    var onUsageUpdate: ((UsageSnapshot) -> Void)?
    var onDisconnect: (() -> Void)?
    var calls = 0
    var failure = false
    func readUsage() async throws -> UsageSnapshot {
        calls += 1
        try await Task.sleep(nanoseconds: 10_000_000)
        if failure { throw UsageFailure.timeout }
        return try decode(fixture)
    }
    func stop() {}
}

@MainActor final class MonitorTests {
    @MainActor func testRetainsLastReadingOnFailureAndRecovers() async {
        let service = MockService()
        let monitor = UsageMonitor(service: service)
        await monitor.refresh()
        expectEqual(monitor.snapshot?.mainWindow?.percentage, 67)
        expectFalse(monitor.isStale())
        service.failure = true
        await monitor.refresh()
        expectEqual(monitor.snapshot?.mainWindow?.percentage, 67)
        expectTrue(monitor.isStale())
        service.failure = false
        await monitor.refresh()
        expectNil(monitor.errorMessage)
        expectFalse(monitor.isStale())
    }
    @MainActor func testConcurrentRefreshesAreDeduplicated() async {
        let service = MockService()
        let monitor = UsageMonitor(service: service)
        async let first: Void = monitor.refresh()
        async let second: Void = monitor.refresh()
        _ = await (first, second)
        expectEqual(service.calls, 1)
        expectFalse(monitor.isRefreshing)
    }
    @MainActor func testAutomaticPollingAndStop() async throws {
        let service = MockService()
        let monitor = UsageMonitor(service: service, interval: 0.03)
        monitor.start()
        try await Task.sleep(nanoseconds: 180_000_000)
        expectAtLeast(monitor.refreshCount, 3)
        monitor.stop()
        let count = service.calls
        try await Task.sleep(nanoseconds: 80_000_000)
        expectEqual(service.calls, count)
    }
    @MainActor func testNotificationsUpdateMainWithoutDiscardingOtherLimits() async throws {
        let service = MockService()
        let monitor = UsageMonitor(service: service)
        await monitor.refresh()
        service.onUsageUpdate?(try decode(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":72,"windowDurationMins":10080}}}"#))
        expectEqual(monitor.snapshot?.mainWindow?.percentage, 72)
        expectEqual(monitor.snapshot?.buckets.count, 2)
        expectTrue(monitor.isStale(at: Date().addingTimeInterval(151)))
    }
}

@MainActor final class ClientTests {
    @MainActor func testRequestTimeout() async throws {
        let client = CodexClient(command: URL(fileURLWithPath: "/bin/cat"), arguments: [], timeout: 0.08)
        do { _ = try await client.readUsage(); fail("Expected invalid response") }
        catch { expectNotNil(error as? UsageFailure) }
        client.stop()
    }
    @MainActor func testSilentProcessTimesOut() async throws {
        let client = CodexClient(command: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.08)
        let start = Date()
        do { _ = try await client.readUsage(); fail("Expected timeout") }
        catch { expectEqual(error.localizedDescription, UsageFailure.timeout.localizedDescription) }
        expectLess(Date().timeIntervalSince(start), 2)
        client.stop()
    }
    @MainActor func testProcessExitFailsPromptly() async throws {
        let client = CodexClient(command: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 1)
        do { _ = try await client.readUsage(); fail("Expected disconnect") }
        catch { expectEqual(error.localizedDescription, UsageFailure.disconnected.localizedDescription) }
        client.stop()
    }
}

@MainActor private var failures = 0
@MainActor private var assertions = 0
@MainActor private func check(_ value: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
    assertions += 1
    if !value { failures += 1; print("FAIL: \(message) at \(file):\(line)") }
}
@MainActor private func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { check(a == b, "\(a) != \(b)", file: file, line: line) }
@MainActor private func expectNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { check(a == nil, "Expected nil", file: file, line: line) }
@MainActor private func expectNotNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { check(a != nil, "Expected value", file: file, line: line) }
@MainActor private func expectTrue(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { check(a, "Expected true", file: file, line: line) }
@MainActor private func expectFalse(_ a: Bool, file: StaticString = #filePath, line: UInt = #line) { check(!a, "Expected false", file: file, line: line) }
@MainActor private func expectAtLeast<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { check(a >= b, "Expected >= \(b), got \(a)", file: file, line: line) }
@MainActor private func expectLess<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { check(a < b, "Expected < \(b), got \(a)", file: file, line: line) }
@MainActor private func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { check(false, message, file: file, line: line) }

@main struct Checks {
    @MainActor static func main() async {
        do {
            let usage = UsageTests()
            try usage.testDisplayWindowsPreservesBothWindows()
            try usage.testPrefersMultiBucketAndMostConstrainedMainWindow()
            try usage.testMissingValuesAreNotZero()
            try usage.testDoesNotSubstituteDifferentModelBucket()
            try usage.testLegacyPayloadAndClamping()
            try usage.testNotificationPreservesUnrelatedBuckets()
            try usage.testResetDoesNotInventUnusedCapacity()
            usage.testChunkedAndMultipleProtocolLines()
            let monitor = MonitorTests()
            await monitor.testRetainsLastReadingOnFailureAndRecovers()
            await monitor.testConcurrentRefreshesAreDeduplicated()
            try await monitor.testAutomaticPollingAndStop()
            try await monitor.testNotificationsUpdateMainWithoutDiscardingOtherLimits()
            let client = ClientTests()
            try await client.testRequestTimeout()
            try await client.testSilentProcessTimesOut()
            try await client.testProcessExitFailsPromptly()
        } catch { fail("Unexpected error: \(error)") }
        print("15 scenarios, \(assertions) assertions, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
