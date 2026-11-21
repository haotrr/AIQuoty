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
                  aiquoty-cli status [--demo]
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

        let demo = args.contains("--demo")
        let credentials = InMemoryCredentialStore()
        let fs = LocalFileSystem()
        let http = URLSessionHTTPClient()
        var providers = ProviderRegistry.makeLiveProviders(credentials: credentials, http: http, fileSystem: fs)

        if demo {
            providers = [
                ClaudeOAuthProvider(
                    credentials: credentials,
                    http: FixtureHTTPClient(),
                    fileSystem: MemoryFileSystem(),
                    demoFixture: DemoFixtures.claudeUsageJSON
                ),
                CodexOAuthProvider(
                    credentials: credentials,
                    http: FixtureHTTPClient(),
                    fileSystem: MemoryFileSystem(),
                    demoFixture: DemoFixtures.codexUsageJSON
                ),
                CursorSessionProvider(
                    credentials: credentials,
                    http: FixtureHTTPClient(),
                    fileSystem: MemoryFileSystem(),
                    demoFixture: DemoFixtures.cursorUsageJSON
                ),
                GeminiCLIProvider(
                    credentials: credentials,
                    http: FixtureHTTPClient(),
                    fileSystem: MemoryFileSystem(),
                    demoFixture: DemoFixtures.geminiQuotaJSON
                ),
                CopilotProvider(
                    credentials: credentials,
                    http: FixtureHTTPClient(),
                    demoFixture: DemoFixtures.copilotUserJSON
                ),
                OpenRouterProvider(
                    credentials: credentials,
                    http: FixtureHTTPClient(),
                    demoFixture: DemoFixtures.openRouterKeyJSON
                ),
            ]
        }

        let coordinator = RefreshCoordinator(providers: providers)
        await coordinator.setDemoMode(demo)
        let state = await coordinator.refreshAll(force: true)
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
        if !state.providerErrors.isEmpty {
            print("Provider errors:")
            for (k, v) in state.providerErrors.sorted(by: { $0.key < $1.key }) {
                print("  \(k): \(v)")
            }
        }
    }
}
