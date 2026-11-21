#if os(macOS)
import SwiftUI
import AIQuotyCore
import AppKit

@main
struct AIQuotyApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverRootView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRootView()
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 420)
        }

        Window("AIQuoty 仪表盘", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let text = model.menuBarSummary
        Label(text, systemImage: "gauge.with.dots.needle.33percent")
            .accessibilityLabel("AIQuoty \(text)")
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state: RefreshCoordinator.State = .init()
    @Published var preferences: AppPreferences = .default
    @Published var searchText: String = ""
    @Published var statusMessage: String = ""

    private var coordinator: RefreshCoordinator?
    private let preferencesStore = JSONPreferencesStore()
    private var refreshTask: Task<Void, Never>?

    var menuBarSummary: String {
        if preferences.demoMode { return "演示" }
        let pinned = state.snapshots.filter(\.account.pinned)
        let focus = pinned.first ?? state.snapshots.first
        guard let focus else { return "AIQuoty" }
        if let used = focus.windows.first?.usedFraction {
            return String(format: "%.0f%%", used * 100)
        }
        if focus.windows.contains(where: { $0.freshness == .stale }) {
            return "陈旧"
        }
        switch focus.connection {
        case .authRequired: return "授权"
        case .error, .rateLimited: return "异常"
        default: return focus.account.displayName
        }
    }

    init() {
        bootstrap()
    }

    private func bootstrap() {
        preferences = (try? preferencesStore.load()) ?? .default
        #if os(macOS)
        let credentials: CredentialStore = KeychainCredentialStore()
        #else
        let credentials: CredentialStore = InMemoryCredentialStore()
        #endif
        let fs = LocalFileSystem()
        let http = URLSessionHTTPClient()
        var providers = ProviderRegistry.makeLiveProviders(credentials: credentials, http: http, fileSystem: fs)
        if preferences.enableLocalClaudeLogs || preferences.enableLocalCodexLogs {
            providers.append(LocalClaudeLogProvider(fileSystem: fs, enabled: preferences.enableLocalClaudeLogs))
            providers.append(LocalCodexLogProvider(fileSystem: fs, enabled: preferences.enableLocalCodexLogs))
        }
        if preferences.demoMode {
            providers = Self.demoProviders()
        }
        let coordinator = RefreshCoordinator(
            providers: providers,
            baseInterval: preferences.refreshIntervalSeconds
        )
        self.coordinator = coordinator
        Task {
            await coordinator.setDemoMode(preferences.demoMode)
            await refresh(force: true)
            startTimer()
        }
    }

    func refresh(force: Bool = false) async {
        guard let coordinator else { return }
        statusMessage = "刷新中…"
        let newState = await coordinator.refreshAll(force: force)
        state = newState
        if newState.providerErrors.isEmpty {
            statusMessage = "已更新"
        } else {
            statusMessage = "部分失败"
        }
    }

    func savePreferences() {
        try? preferencesStore.save(preferences)
        refreshTask?.cancel()
        bootstrap()
    }

    func togglePin(_ accountID: String) {
        Task {
            guard let coordinator else { return }
            let currently = state.snapshots.first(where: { $0.account.id == accountID })?.account.pinned ?? false
            await coordinator.setPinned(accountID: accountID, pinned: !currently)
            state = await coordinator.currentState()
            var prefs = preferences
            if !currently {
                prefs.pinnedAccountIDs.append(accountID)
            } else {
                prefs.pinnedAccountIDs.removeAll { $0 == accountID }
            }
            preferences = prefs
            try? preferencesStore.save(prefs)
        }
    }

    private func startTimer() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = UInt64((self?.preferences.refreshIntervalSeconds ?? 300) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: interval)
                await self?.refresh(force: false)
            }
        }
    }

    private static func demoProviders() -> [any QuotaProvider] {
        let credentials = InMemoryCredentialStore()
        let fs = MemoryFileSystem()
        return [
            ClaudeOAuthProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.claudeUsageJSON),
            CodexOAuthProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.codexUsageJSON),
            CursorSessionProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.cursorUsageJSON),
            GeminiCLIProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.geminiQuotaJSON),
            CopilotProvider(credentials: credentials, http: FixtureHTTPClient(), demoFixture: DemoFixtures.copilotUserJSON),
            OpenRouterProvider(credentials: credentials, http: FixtureHTTPClient(), demoFixture: DemoFixtures.openRouterKeyJSON),
        ]
    }
}

#endif
