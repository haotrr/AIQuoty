import Foundation
import AIQuotyCore

@main
struct AIQuotyCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print(
                """
                AIQuoty CLI — 本机优先的 AI Agent 配额读取工具

                用法:
                  aiquoty-cli status [--demo] [--json]
                  aiquoty-cli detect
                  aiquoty-cli providers
                  aiquoty-cli coverage

                说明:
                  - 默认不会发起产生账单的 AI 任务。
                  - --demo 使用内置合成夹具，不会读取真实密钥。
                  - 密钥只应存放在钥匙串 / 本机 CLI 凭证文件中。
                """
            )
            return
        }

        if args.first == "providers" || args.first == "coverage" {
            for d in ProviderRegistry.allDescriptors {
                print("[\(d.implementationStatus.rawValue)] \(d.displayName) (\(d.id))")
                print("  \(d.notes)")
            }
            return
        }

        if args.first == "detect" {
            let detected = LocalAgentDetector.detect(fileSystem: LocalFileSystem())
            print("Detected local AI Agents: \(detected.count)")
            for item in detected {
                print("• \(item.displayName) (\(item.providerID)) [\(item.category)]")
                print("  paths: \(item.matchedPaths.joined(separator: ", "))")
                print("  hint:  \(item.setupHint)")
            }
            return
        }

        let demo = args.contains("--demo")
        let jsonOutput = args.contains("--json")
        #if os(macOS)
        let credentials: CredentialStore = demo ? InMemoryCredentialStore() : KeychainCredentialStore()
        #else
        let credentials: CredentialStore = InMemoryCredentialStore()
        #endif
        let fs = LocalFileSystem()
        let http = URLSessionHTTPClient()
        var providers = ProviderRegistry.makeLiveProviders(credentials: credentials, http: http, fileSystem: fs)

        if demo {
            let memFS = MemoryFileSystem()
            providers = [
                ClaudeOAuthProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: memFS, externalKeychain: NullExternalKeychainReader(), demoFixture: DemoFixtures.claudeUsageJSON),
                CodexOAuthProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: memFS, demoFixture: DemoFixtures.codexUsageJSON),
                CursorSessionProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: memFS, cursorStateReader: NullCursorStateReader(), demoFixture: DemoFixtures.cursorUsageJSON),
                AntigravityProvider(http: FixtureHTTPClient(), stateReader: NullAntigravityStateReader(), demoFixture: DemoFixtures.antigravityQuotaJSON),
                GeminiCLIProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: memFS, demoFixture: DemoFixtures.geminiQuotaJSON),
                OpenCodeProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: memFS, demoFixture: DemoFixtures.openCodeUsageJSON),
                DeepSeekProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: memFS, demoFixture: DemoFixtures.deepSeekBalanceJSON),
                CopilotProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: memFS, demoFixture: DemoFixtures.copilotUserJSON),
                KimiCodeProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: memFS, demoSubscriptionFixture: DemoFixtures.kimiCodeUsageJSON, demoBalanceFixture: DemoFixtures.moonshotBalanceJSON),
                MiniMaxProvider(credentials: credentials, http: FixtureHTTPClient(), demoFixture: DemoFixtures.miniMaxRemainsJSON),
                ZaiGLMProvider(credentials: credentials, http: FixtureHTTPClient(), demoFixture: DemoFixtures.zaiQuotaJSON),
                FactoryDroidProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: memFS, demoFixture: DemoFixtures.factoryUsageJSON),
                OpenRouterProvider(credentials: credentials, http: FixtureHTTPClient(), demoFixture: DemoFixtures.openRouterKeyJSON),
            ]
        }

        let coordinator = RefreshCoordinator(providers: providers)
        await coordinator.setDemoMode(demo)
        let state = await coordinator.refreshAll(force: true)

        if jsonOutput {
            struct StatusJSONPayload: Encodable {
                let demo: Bool
                let generatedAt: Date
                let snapshots: [AccountSnapshot]
                let providerErrors: [String: String]
            }
            let payload = StatusJSONPayload(
                demo: demo,
                generatedAt: Date(),
                snapshots: state.snapshots,
                providerErrors: state.providerErrors
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            return
        }

        print("AIQuoty \(demo ? "DEMO" : "LIVE") — accounts: \(state.snapshots.count)")
        for snap in state.snapshots {
            print("• \(snap.account.displayName) [\(snap.connection.rawValue)] \(snap.account.planLabel ?? "")")
            if let email = snap.account.email { print("  \(email)") }
            for w in snap.windows {
                let reset = CountdownFormatter.format(seconds: w.secondsUntilReset(now: Date()))
                let used = w.usedDisplay.display
                let fresh = w.freshness.rawValue
                print("  - \(w.title): used \(used) · \(reset) · \(fresh) · \(w.source.label)")
            }
            for m in snap.spendMetrics {
                print("  $ \(m.display) [\(m.kind.rawValue)/\(m.precision.rawValue)]")
            }
            for m in snap.localTokenMetrics {
                print("  ∑ \(m.display) [\(m.kind.rawValue)/\(m.precision.rawValue)]")
            }
            if let err = snap.lastError {
                print("  ! \(err)")
            }
        }
        if !demo {
            let activeIDs = Set(state.snapshots.map(\.account.providerID))
            let unconfigured = LocalAgentDetector.detect(fileSystem: fs).filter { !activeIDs.contains($0.providerID) }
            if !unconfigured.isEmpty {
                print("Detected local apps awaiting setup (\(unconfigured.count)):")
                for app in unconfigured {
                    print("  • \(app.displayName) (\(app.providerID)) — \(app.setupHint)")
                }
            }
        }
        if !state.providerErrors.isEmpty {
            print("Provider errors:")
            for (k, v) in state.providerErrors.sorted(by: { $0.key < $1.key }) {
                print("  \(k): \(v)")
            }
        }
    }
}
