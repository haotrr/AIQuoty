import XCTest
@testable import AIQuotyCore

final class ResetAndFreshnessTests: XCTestCase {
    func testResetMathPrefersAbsoluteTimestamp() {
        let now = Date(timeIntervalSince1970: 1_000)
        let result = ResetMath.resolveReset(resetAtUnix: 2_000, resetAfterSeconds: 5, now: now)
        XCTAssertEqual(result.date?.timeIntervalSince1970, 2_000)
        XCTAssertTrue(result.known)
    }

    func testResetMathFallsBackToRelative() {
        let now = Date(timeIntervalSince1970: 1_000)
        let result = ResetMath.resolveReset(resetAtUnix: nil, resetAfterSeconds: 120, now: now)
        XCTAssertEqual(result.date?.timeIntervalSince1970, 1_120)
        XCTAssertTrue(result.known)
    }

    func testMissingResetStaysUnknown() {
        let result = ResetMath.resolveReset(resetAtUnix: nil, resetAfterSeconds: nil)
        XCTAssertNil(result.date)
        XCTAssertFalse(result.known)
        XCTAssertEqual(CountdownFormatter.format(seconds: nil), "重置未知")
    }

    func testStaleMarkingPreservesLastSuccessWindows() {
        let source = SourceAttribution(id: "t", label: "t")
        let window = QuotaWindow(
            id: "w",
            title: "5 小时",
            usedFraction: 0.2,
            remainingFraction: 0.8,
            usedDisplay: MetricValue(
                kind: .subscriptionQuota,
                precision: .reported,
                unit: .percentUsed,
                value: 20,
                display: "20%",
                source: source,
                freshness: .fresh
            ),
            remainingDisplay: MetricValue(
                kind: .subscriptionQuota,
                precision: .reported,
                unit: .percentRemaining,
                value: 80,
                display: "80%",
                source: source,
                freshness: .fresh
            ),
            resetsAt: Date().addingTimeInterval(3600),
            resetKnown: true,
            source: source,
            capturedAt: Date(),
            freshness: .fresh
        )
        let snap = AccountSnapshot(
            account: AccountIdentity(id: "a", providerID: "claude", displayName: "Claude"),
            connection: .connected,
            windows: [window],
            lastSuccessAt: Date()
        )
        let stale = snap.markingStale(error: "网络错误")
        XCTAssertEqual(stale.connection, .error)
        XCTAssertEqual(stale.windows[0].usedFraction, 0.2)
        XCTAssertEqual(stale.windows[0].freshness, .stale)
        XCTAssertEqual(stale.lastError, "网络错误")
    }

    func testRateLimitedSetsBackoffNote() {
        let snap = AccountSnapshot(
            account: AccountIdentity(id: "a", providerID: "claude", displayName: "Claude"),
            connection: .connected
        )
        let limited = snap.markingRateLimited(retryAfter: 90)
        XCTAssertEqual(limited.connection, .rateLimited)
        XCTAssertTrue(limited.notes.contains(where: { $0.contains("90") }))
    }
}
