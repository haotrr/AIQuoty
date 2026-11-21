import XCTest
@testable import AIQuotyCore

final class ParserTests: XCTestCase {
    func testClaudeUsageParsingReportedFractionsAndResets() throws {
        let data = try fixture("claude/usage.json")
        let parsed = try ClaudeUsageParser.parse(json: data, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(parsed.fiveHour?.utilization ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(parsed.sevenDay?.utilization ?? -1, 0.67, accuracy: 0.0001)
        // 12 as percent > 1 should normalize to 0.12
        XCTAssertEqual(parsed.sonnetWeekly?.utilization ?? -1, 0.12, accuracy: 0.0001)
        XCTAssertTrue(parsed.fiveHour?.resetKnown == true)
        let windows = ClaudeUsageParser.windows(from: parsed, accountID: "a", capturedAt: Date())
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].usedDisplay.precision, .reported)
        XCTAssertEqual(windows[0].usedDisplay.kind, .subscriptionQuota)
    }

    func testClaudeMissingWindowsStayUnknownNotZero() throws {
        let data = try fixture("claude/usage_missing_windows.json")
        let parsed = try ClaudeUsageParser.parse(json: data)
        XCTAssertNil(parsed.fiveHour)
        XCTAssertNil(parsed.sevenDay)
        let windows = ClaudeUsageParser.windows(from: parsed, accountID: "a", capturedAt: Date())
        XCTAssertTrue(windows.isEmpty)
    }

    func testCodexWindowClassificationByDuration() throws {
        let data = try fixture("codex/usage.json")
        let parsed = try CodexUsageParser.parse(json: data, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(parsed.planType, "plus")
        XCTAssertEqual(parsed.windows.count, 2)
        XCTAssertEqual(parsed.windows[0].windowSeconds, 18_000)
        XCTAssertEqual(parsed.windows[0].title, "5 小时")
        XCTAssertEqual(parsed.windows[1].title, "7 天")
        XCTAssertEqual(parsed.creditsBalance, "4.20")
        let windows = CodexUsageParser.quotaWindows(from: parsed, accountID: "c", capturedAt: Date())
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.55, accuracy: 0.001)
        XCTAssertTrue(windows[0].resetKnown)
    }

    func testCursorUsageSummaryBuckets() throws {
        let data = try fixture("cursor/usage-summary.json")
        let parsed = try CursorUsageParser.parseSummary(json: data)
        XCTAssertEqual(parsed.email, "cursor@example.com")
        XCTAssertFalse(parsed.windows.isEmpty)
        let plan = parsed.windows.first { $0.id.contains("plan") }
        XCTAssertEqual(plan?.usedFraction ?? -1, 0.72, accuracy: 0.001)
        let api = parsed.windows.first { $0.id.contains("api") }
        XCTAssertEqual(api?.usedFraction ?? -1, 0.12, accuracy: 0.001)
    }

    func testGeminiCollapseByFamily() throws {
        let data = try fixture("gemini/quota.json")
        let parsed = try GeminiQuotaParser.parseQuota(json: data)
        let windows = GeminiQuotaParser.collapsedWindows(from: parsed, accountID: "g", capturedAt: Date())
        XCTAssertEqual(windows.count, 3)
        let pro = windows.first { $0.title == "Pro" }
        XCTAssertEqual(pro?.remainingFraction ?? -1, 0.35, accuracy: 0.001)
        XCTAssertEqual(pro?.usedFraction ?? -1, 0.65, accuracy: 0.001)
    }

    func testCopilotPercentRemaining() async throws {
        let data = try fixture("copilot/user.json")
        let provider = CopilotProvider(
            credentials: InMemoryCredentialStore(),
            http: FixtureHTTPClient(),
            demoFixture: data
        )
        let snaps = try await provider.fetch(request: ProviderFetchRequest(demoMode: true))
        XCTAssertEqual(snaps.count, 1)
        let premium = snaps[0].windows.first { $0.id.contains("premium") }
        XCTAssertEqual(premium?.remainingFraction ?? -1, 0.42, accuracy: 0.001)
        XCTAssertEqual(premium?.usedFraction ?? -1, 0.58, accuracy: 0.001)
        XCTAssertTrue(premium?.resetKnown == true)
    }

    func testOpenRouterIsAPISpendNotSubscription() async throws {
        let data = try fixture("openrouter/key.json")
        let provider = OpenRouterProvider(
            credentials: InMemoryCredentialStore(),
            http: FixtureHTTPClient(),
            demoFixture: data
        )
        let snaps = try await provider.fetch(request: ProviderFetchRequest(demoMode: true))
        XCTAssertTrue(snaps[0].windows.isEmpty)
        XCTAssertFalse(snaps[0].spendMetrics.isEmpty)
        XCTAssertTrue(snaps[0].spendMetrics.allSatisfy { $0.kind == .apiSpend })
    }

    func testClaudeCredentialsRejectMCPOnly() throws {
        let json = #"{"mcpOAuth":{"server":"x"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeCredentialsParser.parse(json: json))
    }

    func testCodexAuthRejectsAPIKeyOnly() throws {
        let json = #"{"OPENAI_API_KEY":"sk-test"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try CodexAuthParser.parse(json: json))
    }

    private func fixture(_ relative: String) throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let base = bundle.resourceURL!.appendingPathComponent("Fixtures")
        let file = base.appendingPathComponent(relative)
        return try Data(contentsOf: file)
    }
}
