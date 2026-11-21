import XCTest
@testable import AIQuotyCore

private struct StubCursorStateReader: CursorStateReading {
    let state: CursorLocalState?
    func readLocalState() -> CursorLocalState? { state }
}

private struct StubExternalKeychain: ExternalKeychainReading {
    let items: [String: Data]
    func readGenericPassword(service: String, account: String?) -> Data? {
        if let account, let exact = items["\(service)::\(account)"] {
            return exact
        }
        return items[service]
    }
}

final class MainstreamProvidersTests: XCTestCase {
    func testCursorJWTUserIDAndSessionCookie() {
        // Header: {"alg":"HS256"}, Payload: {"sub":"auth0|user_01TESTUSER"}
        let payloadJSON = #"{"sub":"auth0|user_01TESTUSER"}"#.data(using: .utf8)!
        let payloadB64 = payloadJSON.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.\(payloadB64).sig"
        let state = CursorLocalState(accessToken: jwt, email: "dev@cursor.sh", membershipType: "pro")
        XCTAssertEqual(state.workosUserID, "user_01TESTUSER")
        XCTAssertEqual(state.sessionCookieHeader, "WorkosCursorSessionToken=user_01TESTUSER%3A%3A\(jwt)")
        XCTAssertTrue(SQLiteCursorStateReader.isPlaintextJWT(jwt))
        XCTAssertFalse(SQLiteCursorStateReader.isPlaintextJWT("cursor-safe-storage:v1:encryptedblob"))
    }

    func testCursorDesktopSQLiteStateUsedWhenKeychainEmpty() async throws {
        let payloadJSON = #"{"sub":"auth0|user_01LOCAL"}"#.data(using: .utf8)!
        let payloadB64 = payloadJSON.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.\(payloadB64).sig"

        let http = FixtureHTTPClient(responses: [
            "cursor.com/api/usage-summary": HTTPResponse(statusCode: 200, headers: [:], body: DemoFixtures.cursorUsageJSON),
        ])
        let provider = CursorSessionProvider(
            credentials: InMemoryCredentialStore(),
            http: http,
            fileSystem: MemoryFileSystem(),
            cursorStateReader: StubCursorStateReader(state: CursorLocalState(accessToken: jwt, email: "local@cursor.sh", membershipType: "pro")),
            externalKeychain: NullExternalKeychainReader()
        )
        let accounts = await provider.configuredAccounts()
        XCTAssertEqual(accounts.first?.id, "cursor.desktop")
        let snaps = try await provider.fetch(request: ProviderFetchRequest())
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps[0].connection, .connected)
        XCTAssertFalse(snaps[0].windows.isEmpty)
    }

    func testClaudeExternalKeychainCredentials() async throws {
        let kc = StubExternalKeychain(items: [
            "Claude Code-credentials": DemoFixtures.claudeCredentialsJSON,
        ])
        let http = FixtureHTTPClient(responses: [
            "api.anthropic.com/api/oauth/usage": HTTPResponse(statusCode: 200, headers: [:], body: DemoFixtures.claudeUsageJSON),
        ])
        let provider = ClaudeOAuthProvider(
            credentials: InMemoryCredentialStore(),
            http: http,
            fileSystem: MemoryFileSystem(),
            externalKeychain: kc
        )
        let accounts = await provider.configuredAccounts()
        XCTAssertEqual(accounts.first?.id, "claude.keychain")
        let snaps = try await provider.fetch(request: ProviderFetchRequest(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps[0].account.email, "claude@example.com")
        XCTAssertFalse(snaps[0].windows.isEmpty)
    }

    func testAntigravityQuotaParsingAndFamilyCollapse() throws {
        let parsed = try AntigravityQuotaParser.parse(json: DemoFixtures.antigravityQuotaJSON)
        XCTAssertEqual(parsed.email, "agy-demo@example.com")
        XCTAssertEqual(parsed.planName, "Google AI Ultra")
        let families = parsed.buckets.map(\.family)
        XCTAssertEqual(families, ["Claude", "Gemini Flash", "Gemini Pro"])
        let windows = AntigravityQuotaParser.quotaWindows(from: parsed, accountID: "agy", capturedAt: Date())
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows.first(where: { $0.title == "Claude" })?.usedFraction ?? -1, 0.55, accuracy: 0.001)
    }

    func testOpenCodeUsageAndLocalLogScanner() throws {
        let snap = try OpenCodeUsageParser.parse(json: DemoFixtures.openCodeUsageJSON, accountID: "opencode.test")
        XCTAssertEqual(snap.account.planLabel, "OpenCode Go")
        XCTAssertEqual(snap.windows.count, 2)
        XCTAssertEqual(snap.spendMetrics.count, 1)
        XCTAssertEqual(snap.spendMetrics[0].kind, .apiSpend)

        let msgJSON = #"{"tokens":{"input":1200,"output":350,"reasoning":50,"cache":{"read":400,"write":100}}}"#.data(using: .utf8)!
        let agg = OpenCodeLocalLogScanner.scan(jsonData: msgJSON)
        XCTAssertEqual(agg.inputTokens, 1200)
        XCTAssertEqual(agg.outputTokens, 400)
        XCTAssertEqual(agg.cacheReadTokens, 400)
        XCTAssertEqual(agg.cacheCreationTokens, 100)
        XCTAssertEqual(agg.totalTokens, 2100)
    }

    func testDeepSeekBalanceIsAPISpendNotSubscription() throws {
        let snap = try DeepSeekBalanceParser.parse(json: DemoFixtures.deepSeekBalanceJSON, accountID: "deepseek.test")
        XCTAssertTrue(snap.windows.isEmpty)
        XCTAssertEqual(snap.spendMetrics.count, 3)
        XCTAssertTrue(snap.spendMetrics.allSatisfy { $0.kind == .apiSpend && $0.precision == .exact })
        XCTAssertEqual(snap.spendMetrics[0].value, 110.0)
    }

    func testDeepSeekHarnessCredentialsYAMLAutoLoaded() async throws {
        let yaml = """
        version: 1
        records:
          deepseek-account-platform/device:
            kind: grant
            payload:
              id: dev_123
          deepseek-account-platform/default:
            kind: grant
            payload:
              version: 1
              token: dsh_platform_grant_token_abc
              issuer: https://platform.deepseek.com
        refs: {}
        """
        XCTAssertEqual(DeepSeekProvider.parseDSHPlatformToken(yaml: yaml), "dsh_platform_grant_token_abc")

        let fs = MemoryFileSystem(files: [
            "~/.dsh/.credentials.yaml": Data(yaml.utf8),
        ])
        let http = FixtureHTTPClient(responses: [
            "api.deepseek.com/user/balance": HTTPResponse(statusCode: 200, headers: [:], body: DemoFixtures.deepSeekBalanceJSON),
        ])
        let provider = DeepSeekProvider(
            credentials: InMemoryCredentialStore(),
            http: http,
            fileSystem: fs
        )
        let accounts = await provider.configuredAccounts()
        XCTAssertEqual(accounts.first?.id, "deepseek.dsh")
        let snaps = try await provider.fetch(request: ProviderFetchRequest())
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps[0].account.displayName, "DeepSeek Harness")
        XCTAssertEqual(snaps[0].spendMetrics.first?.value, 110.0)
    }

    func testKimiCodeAndMoonshotRemainSeparate() throws {
        let sub = try KimiUsageParser.parseCodingUsage(json: DemoFixtures.kimiCodeUsageJSON, accountID: "kimi.code")
        XCTAssertEqual(sub.windows.count, 2)
        XCTAssertTrue(sub.spendMetrics.isEmpty)
        XCTAssertEqual(sub.windows[0].usedFraction ?? -1, 0.32, accuracy: 0.001)

        let bal = try KimiUsageParser.parseMoonshotBalance(json: DemoFixtures.moonshotBalanceJSON, accountID: "moonshot.api")
        XCTAssertTrue(bal.windows.isEmpty)
        XCTAssertEqual(bal.spendMetrics.count, 3)
        XCTAssertTrue(bal.spendMetrics.allSatisfy { $0.kind == .apiSpend })
    }

    func testMiniMaxCodingPlanRemainsParsing() throws {
        let snap = try MiniMaxQuotaParser.parse(json: DemoFixtures.miniMaxRemainsJSON, accountID: "minimax.test")
        XCTAssertEqual(snap.windows.count, 1)
        XCTAssertEqual(snap.windows[0].usedFraction ?? -1, 0.30, accuracy: 0.001)
        XCTAssertTrue(snap.windows[0].resetKnown)
    }

    func testZaiGLMLimitsParsing() throws {
        let snap = try ZaiQuotaParser.parse(json: DemoFixtures.zaiQuotaJSON, accountID: "zai.test")
        XCTAssertEqual(snap.windows.count, 2)
        XCTAssertEqual(snap.windows[0].title, "Token 配额")
        XCTAssertEqual(snap.windows[0].usedFraction ?? -1, 0.38, accuracy: 0.001)
        XCTAssertEqual(snap.windows[1].title, "MCP / 时长配额")
    }

    func testFactoryDroidAndWindsurfParsing() throws {
        let factory = try FactoryUsageParser.parse(json: DemoFixtures.factoryUsageJSON, accountID: "factory.test")
        XCTAssertEqual(factory.windows.count, 1)
        XCTAssertEqual(factory.windows[0].usedFraction ?? -1, 0.45, accuracy: 0.001)

        let windsurfJSON = """
        {
          "planStatus": {
            "planInfo": { "planName": "Pro" },
            "usedPromptCredits": 120,
            "availablePromptCredits": 500,
            "usedFlexCredits": 25,
            "availableFlexCredits": 100,
            "planEnd": "2030-02-01T00:00:00Z"
          }
        }
        """.data(using: .utf8)!
        let ws = try WindsurfStatusParser.parse(json: windsurfJSON, accountID: "ws.test")
        XCTAssertEqual(ws.windows.count, 2)
        XCTAssertEqual(ws.windows[0].usedFraction ?? -1, 0.24, accuracy: 0.001)
    }

    func testClineRooLocalLogScanner() {
        let uiMessages = """
        [
          { "say": "api_req_started", "text": "{\\"tokensIn\\": 500, \\"tokensOut\\": 200, \\"cacheWrites\\": 100, \\"cacheReads\\": 50}" },
          { "say": "text", "text": "hello" }
        ]
        """.data(using: .utf8)!
        let agg = ClineRooLocalLogScanner.scan(uiMessagesData: uiMessages)
        XCTAssertEqual(agg.inputTokens, 500)
        XCTAssertEqual(agg.outputTokens, 200)
        XCTAssertEqual(agg.cacheCreationTokens, 100)
        XCTAssertEqual(agg.cacheReadTokens, 50)
        XCTAssertEqual(agg.totalTokens, 850)
        XCTAssertEqual(agg.uniqueMessageIDs, 1)
    }

    func testLocalAgentDetectorFindsInstalledApps() {
        let fs = MemoryFileSystem(files: [
            "/Applications/Cursor.app": Data(),
            "/Applications/Antigravity.app": Data(),
            "/Applications/DeepSeek Harness.app": Data(),
            "~/.local/share/opencode": Data(),
            "~/.claude": Data(),
        ])
        let found = LocalAgentDetector.detect(fileSystem: fs)
        let ids = Set(found.map(\.providerID))
        XCTAssertTrue(ids.contains("cursor"))
        XCTAssertTrue(ids.contains("antigravity"))
        XCTAssertTrue(ids.contains("deepseek"))
        XCTAssertTrue(ids.contains("opencode"))
        XCTAssertTrue(ids.contains("claude"))
    }

    func testCursorAgentKeychainTokenAutoLoaded() async throws {
        let payloadJSON = #"{"sub":"auth0|user_01KEYCHAIN"}"#.data(using: .utf8)!
        let payloadB64 = payloadJSON.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.\(payloadB64).sig"
        let kc = StubExternalKeychain(items: [
            "cursor-access-token::cursor-user": Data(jwt.utf8),
        ])
        let http = FixtureHTTPClient(responses: [
            "cursor.com/api/usage-summary": HTTPResponse(statusCode: 200, headers: [:], body: DemoFixtures.cursorUsageJSON),
        ])
        let provider = CursorSessionProvider(
            credentials: InMemoryCredentialStore(),
            http: http,
            fileSystem: MemoryFileSystem(),
            cursorStateReader: NullCursorStateReader(),
            externalKeychain: kc
        )
        let accounts = await provider.configuredAccounts()
        XCTAssertEqual(accounts.first?.id, "cursor.agent.keychain")
        let snaps = try await provider.fetch(request: ProviderFetchRequest())
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps[0].connection, .connected)
    }

    func testCopilotCLIKeychainAndGHFallbackGraceful() async throws {
        // 1. Standalone Copilot CLI keychain works directly.
        let kc = StubExternalKeychain(items: [
            "copilot-cli": Data("gho_copilot_cli_tok".utf8),
        ])
        let okHTTP = FixtureHTTPClient(responses: [
            "api.github.com/copilot_internal/user": HTTPResponse(statusCode: 200, headers: [:], body: DemoFixtures.copilotUserJSON),
        ])
        let provider = CopilotProvider(
            credentials: InMemoryCredentialStore(),
            http: okHTTP,
            fileSystem: MemoryFileSystem(),
            externalKeychain: kc,
            ghTokenProvider: { nil }
        )
        let snaps = try await provider.fetch(request: ProviderFetchRequest())
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps[0].windows.count, 2)

        // 2. Implicit `gh auth token` returning 404 (no Copilot subscription) degrades to notConfigured silently.
        let notFoundHTTP = FixtureHTTPClient(responses: [
            "api.github.com/copilot_internal/user": HTTPResponse(statusCode: 404, headers: [:], body: Data("Not Found".utf8)),
        ])
        let ghOnlyProvider = CopilotProvider(
            credentials: InMemoryCredentialStore(),
            http: notFoundHTTP,
            fileSystem: MemoryFileSystem(),
            externalKeychain: NullExternalKeychainReader(),
            ghTokenProvider: { "gho_plain_gh_user" }
        )
        do {
            _ = try await ghOnlyProvider.fetch(request: ProviderFetchRequest())
            XCTFail("Expected notConfigured for implicit gh fallback without Copilot")
        } catch let err as ProviderError {
            if case .notConfigured = err {
                // expected
            } else {
                XCTFail("Expected .notConfigured, got \(err)")
            }
        }
    }

    func testGoogleOAuthPKCEAndSilentRefresh() async throws {
        let pkce = GoogleOAuthFlow.generatePKCE()
        XCTAssertFalse(pkce.verifier.isEmpty)
        XCTAssertFalse(pkce.challenge.isEmpty)
        let store = InMemoryCredentialStore(seed: [
            CredentialAccount.geminiOAuthClientID: "test-gemini-client-id",
            CredentialAccount.geminiOAuthClientSecret: "test-gemini-client-secret",
        ])
        let resolvedGemini = GoogleOAuthAppConfig.gemini.resolved(credentials: store, environment: [:])
        XCTAssertTrue(resolvedGemini.isConfigured)
        let authURL = GoogleOAuthFlow.authorizationURL(
            app: resolvedGemini,
            redirectURI: "http://127.0.0.1:41234/oauth2callback",
            state: "state123",
            pkce: pkce
        )
        XCTAssertTrue(authURL.absoluteString.contains("accounts.google.com/o/oauth2/v2/auth"))
        XCTAssertTrue(authURL.absoluteString.contains("code_challenge="))

        let expired = GoogleOAuthBundle(
            accessToken: "old-token",
            refreshToken: "refresh-123",
            expiryDate: Date(timeIntervalSince1970: 1_000),
            email: "user@example.com",
            clientID: "test-gemini-client-id"
        )
        try expired.save(to: store, account: CredentialAccount.geminiOAuthBundle)

        let refreshResp = #"{"access_token":"fresh-token","expires_in":3600}"#.data(using: .utf8)!
        let http = FixtureHTTPClient(responses: [
            "oauth2.googleapis.com/token": HTTPResponse(statusCode: 200, headers: [:], body: refreshResp),
        ])

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let resolved = try await GoogleOAuthFlow.validAccessToken(
            http: http,
            app: .gemini,
            credentials: store,
            now: now
        )
        XCTAssertEqual(resolved?.accessToken, "fresh-token")
        XCTAssertEqual(resolved?.email, "user@example.com")

        // Verify persisted bundle was updated in Keychain
        let saved = GoogleOAuthBundle.load(from: store, account: CredentialAccount.geminiOAuthBundle)
        XCTAssertEqual(saved?.accessToken, "fresh-token")
    }

    func testMenuBarFormatterSelectionAndIconOnly() throws {
        let now = Date()
        let agy = try AntigravityProvider(
            http: FixtureHTTPClient(),
            stateReader: NullAntigravityStateReader()
        ).parseQuota(DemoFixtures.antigravityQuotaJSON, accountID: "antigravity.desktop", plan: "Pro", now: now)
        let ds = try DeepSeekBalanceParser.parse(json: DemoFixtures.deepSeekBalanceJSON, accountID: "deepseek.dsh", displayName: "DeepSeek Harness", now: now)

        // Multiple selected accounts render in exact user-selected order.
        let multi = MenuBarFormatter.summary(
            snapshots: [agy, ds],
            selectedAccountIDs: ["deepseek.dsh", "antigravity.desktop"]
        )
        XCTAssertEqual(multi, "DS ¥110 · AGY 55%")

        // Overflow beyond the menu bar item cap collapses into "+N".
        var extra1 = ds; extra1.account.id = "deepseek.extra1"
        var extra2 = ds; extra2.account.id = "deepseek.extra2"
        let overflow = MenuBarFormatter.summary(
            snapshots: [agy, ds, extra1, extra2],
            selectedAccountIDs: ["antigravity.desktop", "deepseek.dsh", "deepseek.extra1", "deepseek.extra2"]
        )
        XCTAssertEqual(overflow, "AGY 55% · DS ¥110 · DS ¥110 +1")

        // Icon-only mode returns empty text.
        XCTAssertEqual(
            MenuBarFormatter.summary(snapshots: [agy, ds], selectedAccountIDs: ["antigravity.desktop"], iconOnly: true),
            ""
        )

        // Empty selection auto-falls back to first snapshot.
        XCTAssertEqual(
            MenuBarFormatter.summary(snapshots: [agy, ds], selectedAccountIDs: []),
            "AGY 55%"
        )

        // Backward-compatible preferences decoding preserves defaults when new fields are absent.
        let legacyJSON = #"{"demoMode":false,"refreshIntervalSeconds":300,"enableLocalClaudeLogs":false,"enableLocalCodexLogs":false,"pinnedAccountIDs":[],"accountGroups":{},"appearance":"system"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: legacyJSON)
        XCTAssertEqual(decoded.menuBarAccountIDs, [])
        XCTAssertEqual(decoded.menuBarIconOnly, false)
        XCTAssertEqual(decoded.hiddenHomeAccountIDs, [])

        // Home display preferences round-trip cleanly.
        var custom = AppPreferences.default
        custom.hiddenHomeAccountIDs = ["copilot.default", "deepseek.dsh"]
        let encoded = try JSONEncoder().encode(custom)
        let roundTripped = try JSONDecoder().decode(AppPreferences.self, from: encoded)
        XCTAssertEqual(roundTripped.hiddenHomeAccountIDs, ["copilot.default", "deepseek.dsh"])
    }

    func testAntigravityLocalStateParserAndProvider() async throws {
        // Build a nested Base64-encoded protobuf containing a fresh Google access token & refresh token.
        func pbString(field: UInt8, _ value: String) -> Data {
            let utf8 = Data(value.utf8)
            var out = Data([field << 3 | 2])
            var len = utf8.count
            while len >= 0x80 {
                out.append(UInt8((len & 0x7F) | 0x80))
                len >>= 7
            }
            out.append(UInt8(len))
            out.append(utf8)
            return out
        }

        let freshAccess = "ya29.a0AfH6SMB_fresh_synced_antigravity_token_123456"
        let staleAccess = "ya29.a0AfH6SMB_stale_auth_status_token_987654"
        let refresh = "1//0g_test_antigravity_refresh_token_abcdef"
        var inner = Data()
        inner.append(pbString(field: 1, freshAccess))
        inner.append(pbString(field: 3, refresh))
        let outer = pbString(field: 1, inner.base64EncodedString())
        let encoded = outer.base64EncodedString()

        // Live synced oauthStateValues must take precedence over a stale apiKey in antigravityAuthStatus.
        let authStatus = #"{"email":"dev@example.com","apiKey":"ya29.a0AfH6SMB_stale_auth_status_token_987654"}"#
        let parsed = AntigravityStateParser.parse(authStatusJSON: authStatus, oauthStateValues: [encoded])
        XCTAssertEqual(parsed?.accessToken, freshAccess)
        XCTAssertEqual(parsed?.candidateAccessTokens, [freshAccess, staleAccess])
        XCTAssertEqual(parsed?.refreshToken, refresh)
        XCTAssertEqual(parsed?.email, "dev@example.com")

        // Also works with plain JSON apiKey alone in antigravityAuthStatus.
        let parsedJSON = AntigravityStateParser.parse(authStatusJSON: authStatus, oauthStateValues: [])
        XCTAssertEqual(parsedJSON?.accessToken, staleAccess)
        XCTAssertEqual(parsedJSON?.email, "dev@example.com")

        // Provider uses local desktop state exclusively to fetch live quota.
        struct StubAntigravityReader: AntigravityStateReading {
            let state: AntigravityLocalState?
            func readLocalState() -> AntigravityLocalState? { state }
        }
        let loadResp = #"{"cloudaicompanionProject":"proj-123","paidTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}"#.data(using: .utf8)!
        let fetchModelsResp = """
        {
          "models": {
            "gemini-3.1-pro-low": { "displayName": "Gemini 3.1 Pro", "quotaInfo": { "remainingFraction": 0.62, "resetTime": "2030-01-01T15:00:00Z" } },
            "gemini-3-flash": { "displayName": "Gemini 3 Flash", "quotaInfo": { "remainingFraction": 0.90, "resetTime": "2030-01-01T15:00:00Z" } },
            "claude-sonnet-4-6": { "displayName": "Claude Sonnet 4.6", "quotaInfo": { "remainingFraction": 0.45, "resetTime": "2030-01-01T15:00:00Z" } },
            "chat_20706": { "displayName": "Internal", "quotaInfo": { "remainingFraction": 0.1 } }
          }
        }
        """.data(using: .utf8)!
        let http = FixtureHTTPClient(responses: [
            "loadCodeAssist": HTTPResponse(statusCode: 200, headers: [:], body: loadResp),
            "fetchAvailableModels": HTTPResponse(statusCode: 200, headers: [:], body: fetchModelsResp),
        ])
        let provider = AntigravityProvider(
            http: http,
            stateReader: StubAntigravityReader(state: parsed)
        )
        let accounts = await provider.configuredAccounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, "antigravity.desktop")
        XCTAssertEqual(accounts.first?.email, "dev@example.com")

        let snaps = try await provider.fetch(request: ProviderFetchRequest(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(snaps[0].windows.count, 3)
    }

    func testGoogleOAuthConfigResolvesFromLocalConfigFile() throws {
        let json = """
        {
          "gemini": {
            "clientId": "file-gem-id.apps.googleusercontent.com",
            "clientSecret": "file-gem-secret"
          }
        }
        """
        let fs = MemoryFileSystem(files: ["~/.aiquoty/oauth.json": Data(json.utf8)])

        // Falls back to ~/.aiquoty/oauth.json when Keychain and env are empty.
        let gem = GoogleOAuthAppConfig.gemini.resolved(
            credentials: InMemoryCredentialStore(),
            environment: [:],
            fileSystem: fs
        )
        XCTAssertEqual(gem.clientID, "file-gem-id.apps.googleusercontent.com")
        XCTAssertEqual(gem.clientSecret, "file-gem-secret")

        // Keychain takes precedence over env and file.
        let creds = InMemoryCredentialStore()
        try creds.setSecret("keychain-gem-id", account: CredentialAccount.geminiOAuthClientID)
        let overridden = GoogleOAuthAppConfig.gemini.resolved(
            credentials: creds,
            environment: ["AIQUOTY_GEMINI_OAUTH_CLIENT_ID": "env-gem-id"],
            fileSystem: fs
        )
        XCTAssertEqual(overridden.clientID, "keychain-gem-id")
        XCTAssertEqual(overridden.clientSecret, "file-gem-secret")

        // Falls back to build-time injected Info.plist keys when Keychain/env/file are absent.
        let fromPlist = GoogleOAuthAppConfig.gemini.resolved(
            credentials: InMemoryCredentialStore(),
            environment: [:],
            fileSystem: MemoryFileSystem(),
            bundleInfo: [
                "AIQuotyGeminiOAuthClientID": "plist-gem-id.apps.googleusercontent.com",
                "AIQuotyGeminiOAuthClientSecret": "plist-gem-secret",
            ]
        )
        XCTAssertEqual(fromPlist.clientID, "plist-gem-id.apps.googleusercontent.com")
        XCTAssertEqual(fromPlist.clientSecret, "plist-gem-secret")
    }
}
