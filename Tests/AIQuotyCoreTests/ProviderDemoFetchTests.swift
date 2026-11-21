import XCTest
@testable import AIQuotyCore

final class ProviderDemoFetchTests: XCTestCase {
    func testDemoProvidersProduceTypedSnapshots() async throws {
        let credentials = InMemoryCredentialStore()
        let fs = MemoryFileSystem()
        let providers: [any QuotaProvider] = [
            ClaudeOAuthProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.claudeUsageJSON),
            CodexOAuthProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.codexUsageJSON),
            CursorSessionProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.cursorUsageJSON),
            GeminiCLIProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.geminiQuotaJSON),
            CopilotProvider(credentials: credentials, http: FixtureHTTPClient(), demoFixture: DemoFixtures.copilotUserJSON),
            OpenRouterProvider(credentials: credentials, http: FixtureHTTPClient(), demoFixture: DemoFixtures.openRouterKeyJSON),
        ]
        let coordinator = RefreshCoordinator(providers: providers)
        await coordinator.setDemoMode(true)
        let state = await coordinator.refreshAll(force: true)
        XCTAssertEqual(state.snapshots.count, 6)
        XCTAssertTrue(state.providerErrors.isEmpty)
        // No provider should invent subscription remaining from spend alone.
        for snap in state.snapshots where snap.account.providerID == "openrouter" {
            XCTAssertTrue(snap.windows.isEmpty)
            XCTAssertTrue(snap.spendMetrics.allSatisfy { $0.kind == .apiSpend })
        }
        for snap in state.snapshots where snap.account.providerID == "claude" {
            XCTAssertFalse(snap.windows.isEmpty)
            XCTAssertTrue(snap.windows.allSatisfy { $0.usedDisplay.kind == .subscriptionQuota })
        }
    }

    func testUnconfiguredProviderSkipped() async {
        let provider = ClaudeOAuthProvider(
            credentials: InMemoryCredentialStore(),
            http: FixtureHTTPClient(),
            fileSystem: MemoryFileSystem(),
            externalKeychain: NullExternalKeychainReader()
        )
        let coordinator = RefreshCoordinator(providers: [provider])
        let state = await coordinator.refreshAll(force: true)
        XCTAssertTrue(state.snapshots.isEmpty)
        XCTAssertTrue(state.providerErrors.isEmpty)
    }

    func testMetricKindsRemainDistinct() {
        let kinds = MetricKind.allCases
        XCTAssertTrue(kinds.contains(.subscriptionQuota))
        XCTAssertTrue(kinds.contains(.apiSpend))
        XCTAssertTrue(kinds.contains(.locallyObservedTokens))
        XCTAssertEqual(Set(kinds.map(\.rawValue)).count, kinds.count)
    }
}
