#if os(macOS)
import SwiftUI
import AIQuotyCore
import AppKit
import ServiceManagement

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
        }

        Window("AIQuoty 仪表盘", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}

/// Window activation for an `LSUIElement` menu bar app.
///
/// While a regular window (Settings / Dashboard) is open, the app temporarily becomes a
/// `.regular` app so the window gets a Dock icon, appears in ⌘Tab and reliably comes to the
/// front. When the last regular window closes, it returns to `.accessory`.
@MainActor
enum AppWindowActivator {
    private static var closeObserver: NSObjectProtocol?

    static func activateWindow(identifierHint: String) {
        installCloseObserverIfNeeded()
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        // `openWindow` / `openSettings` create the window asynchronously; front it on the next turn.
        DispatchQueue.main.async {
            NSApp.activate()
            let target = regularWindows().first {
                $0.identifier?.rawValue.localizedCaseInsensitiveContains(identifierHint) == true
            } ?? regularWindows().first
            if let target {
                if target.isMiniaturized { target.deminiaturize(nil) }
                target.makeKeyAndOrderFront(nil)
            }
        }
    }

    private static func isRegularWindow(_ window: NSWindow) -> Bool {
        let className = NSStringFromClass(type(of: window))
        if className.contains("StatusBar") || className.contains("MenuBarExtra") { return false }
        return window.styleMask.contains(.titled) && window.canBecomeMain
    }

    private static func regularWindows() -> [NSWindow] {
        NSApp.windows.filter(isRegularWindow)
    }

    private static func installCloseObserverIfNeeded() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let closing = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard isRegularWindow(closing) else { return }
                let remaining = regularWindows().filter { $0 !== closing && $0.isVisible }
                if remaining.isEmpty, NSApp.activationPolicy() == .regular {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let text = model.menuBarSummary
        if text.isEmpty {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .accessibilityLabel("AIQuoty")
        } else {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text(text).monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("AIQuoty \(text)")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum ActiveSignIn: Equatable {
        case idle
        case githubDevice(userCode: String, verificationURI: String)
        case googleBrowser(providerName: String)
    }

    @Published var state: RefreshCoordinator.State = .init()
    @Published var detectedAgents: [DetectedLocalAgent] = []
    /// Settings apply immediately (macOS convention): every change is persisted, and changes that
    /// affect the provider set (demo mode / local logs) rebuild the coordinator automatically.
    @Published var preferences: AppPreferences = .default {
        didSet { preferencesDidChange(from: oldValue) }
    }
    @Published var searchText: String = ""
    @Published var statusMessage: String = ""
    @Published var isRefreshing: Bool = false
    @Published var activeSignIn: ActiveSignIn = .idle
    @Published var signInNotice: String = ""
    @Published private(set) var launchAtLogin: Bool = false
    @Published var launchAtLoginError: String?

    var preferredColorScheme: ColorScheme? {
        switch preferences.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var coordinator: RefreshCoordinator?
    private let preferencesStore = JSONPreferencesStore()
    private var refreshTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var activeLoopbackServer: LoopbackOAuthServer?
    private var isLoadingPreferences = false
    private var rebootstrapTask: Task<Void, Never>?

    var menuBarSummary: String {
        MenuBarFormatter.summary(
            snapshots: state.snapshots,
            selectedAccountIDs: preferences.menuBarAccountIDs,
            iconOnly: preferences.menuBarIconOnly,
            demoMode: preferences.demoMode
        )
    }

    func isShownInMenuBar(_ accountID: String) -> Bool {
        !preferences.menuBarIconOnly && preferences.menuBarAccountIDs.contains(accountID)
    }

    func toggleMenuBarAccount(_ accountID: String) {
        var prefs = preferences
        prefs.menuBarIconOnly = false
        if let idx = prefs.menuBarAccountIDs.firstIndex(of: accountID) {
            prefs.menuBarAccountIDs.remove(at: idx)
        } else {
            prefs.menuBarAccountIDs.append(accountID)
        }
        preferences = prefs
    }

    func selectAllMenuBarAccounts() {
        var prefs = preferences
        prefs.menuBarIconOnly = false
        prefs.menuBarAccountIDs = state.snapshots.map(\.account.id)
        preferences = prefs
    }

    func resetMenuBarToAuto() {
        var prefs = preferences
        prefs.menuBarIconOnly = false
        prefs.menuBarAccountIDs = []
        preferences = prefs
    }

    func setMenuBarIconOnly(_ enabled: Bool) {
        preferences.menuBarIconOnly = enabled
    }

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        bootstrap()
    }

    // MARK: Preferences

    private func preferencesDidChange(from old: AppPreferences) {
        guard !isLoadingPreferences, old != preferences else { return }
        try? preferencesStore.save(preferences)

        let providerSetChanged = old.demoMode != preferences.demoMode
            || old.enableLocalClaudeLogs != preferences.enableLocalClaudeLogs
            || old.enableLocalCodexLogs != preferences.enableLocalCodexLogs
            || old.enableLocalOpenCodeLogs != preferences.enableLocalOpenCodeLogs
            || old.enableLocalClineLogs != preferences.enableLocalClineLogs
        if providerSetChanged {
            // Debounce so flipping several toggles in a row rebuilds once.
            rebootstrapTask?.cancel()
            rebootstrapTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled, let self else { return }
                self.refreshTask?.cancel()
                self.bootstrap()
            }
        } else if old.refreshIntervalSeconds != preferences.refreshIntervalSeconds {
            startTimer()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "无法更改登录项：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func bootstrap() {
        isLoadingPreferences = true
        preferences = (try? preferencesStore.load()) ?? .default
        isLoadingPreferences = false
        #if os(macOS)
        let credentials: CredentialStore = KeychainCredentialStore()
        #else
        let credentials: CredentialStore = InMemoryCredentialStore()
        #endif
        let fs = LocalFileSystem()
        detectedAgents = LocalAgentDetector.detect(fileSystem: fs)
        let http = URLSessionHTTPClient()
        let localLogIDs: Set<String> = ["local-claude-logs", "local-codex-logs", "local-opencode-logs", "cline-roo"]
        var providers = ProviderRegistry.makeLiveProviders(credentials: credentials, http: http, fileSystem: fs)
            .filter { !localLogIDs.contains($0.descriptor.id) }
        providers.append(LocalClaudeLogProvider(fileSystem: fs, enabled: preferences.enableLocalClaudeLogs))
        providers.append(LocalCodexLogProvider(fileSystem: fs, enabled: preferences.enableLocalCodexLogs))
        providers.append(LocalOpenCodeLogProvider(fileSystem: fs, enabled: preferences.enableLocalOpenCodeLogs))
        providers.append(LocalClineRooLogProvider(fileSystem: fs, enabled: preferences.enableLocalClineLogs))
        if preferences.demoMode {
            providers = Self.demoProviders()
        }
        let coordinator = RefreshCoordinator(
            providers: providers,
            baseInterval: preferences.refreshIntervalSeconds
        )
        self.coordinator = coordinator
        let pinnedIDs = Set(preferences.pinnedAccountIDs)
        Task {
            await coordinator.setDemoMode(preferences.demoMode)
            await coordinator.applyPinnedAccountIDs(pinnedIDs)
            // A refresh from the previous coordinator may still be in flight; wait so the
            // rebuilt provider set (e.g. demo mode toggled) is fetched immediately.
            while isRefreshing { try? await Task.sleep(nanoseconds: 100_000_000) }
            await refresh(force: true)
            startTimer()
        }
    }

    func refresh(force: Bool = false) async {
        guard let coordinator else { return }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        statusMessage = "刷新中…"
        detectedAgents = LocalAgentDetector.detect(fileSystem: LocalFileSystem())
        let newState = await coordinator.refreshAll(force: force)
        state = newState
        if newState.providerErrors.isEmpty {
            statusMessage = "已更新"
        } else {
            statusMessage = "部分失败"
        }
    }

    func supportsOneClickSignIn(providerID: String) -> Bool {
        providerID == "copilot" || providerID == "gemini" || providerID == "antigravity"
    }

    /// Title of the primary sign-in action for a provider, or nil when it must be configured manually.
    func signInActionTitle(for providerID: String) -> String? {
        if supportsOneClickSignIn(providerID: providerID) { return "一键登录" }
        if CLILoginSpec.entry(for: providerID) != nil { return "终端登录" }
        return nil
    }

    func startOneClickSignIn(providerID: String) {
        switch providerID {
        case "copilot":
            startGitHubCopilotSignIn()
        case "gemini":
            startGoogleSignIn(app: .gemini)
        case "antigravity":
            startGoogleSignIn(app: .antigravity)
        default:
            launchCLILogin(providerID: providerID)
        }
    }

    func startGitHubCopilotSignIn() {
        cancelSignIn()
        let clientID = (preferences.githubOAuthClientID?.isEmpty == false)
            ? preferences.githubOAuthClientID!
            : GitHubDeviceFlow.defaultCopilotClientID
        signInNotice = "正在向 GitHub 请求授权码…"
        signInTask = Task { [weak self] in
            guard let self else { return }
            let http = URLSessionHTTPClient()
            do {
                let code = try await GitHubDeviceFlow.requestDeviceCode(http: http, clientID: clientID)
                CLILoginSpec.copyToClipboard(code.userCode)
                if let url = URL(string: code.verificationURI) {
                    NSWorkspace.shared.open(url)
                }
                self.activeSignIn = .githubDevice(userCode: code.userCode, verificationURI: code.verificationURI)
                self.signInNotice = "已复制授权码 \(code.userCode) 并打开浏览器，请粘贴确认授权…"

                let token = try await GitHubDeviceFlow.pollAccessToken(http: http, clientID: clientID, deviceCode: code)
                try KeychainCredentialStore().setSecret(token, account: CredentialAccount.copilotGitHubToken)
                self.activeSignIn = .idle
                self.signInNotice = "GitHub Copilot 登录成功，正在刷新配额…"
                await self.refresh(force: true)
            } catch is CancellationError {
                self.activeSignIn = .idle
            } catch ProviderError.cancelled {
                self.activeSignIn = .idle
                self.signInNotice = "已取消 GitHub 登录。"
            } catch {
                self.activeSignIn = .idle
                let msg = (error as? ProviderError)?.userMessage ?? error.localizedDescription
                self.signInNotice = "GitHub 登录失败：\(msg)"
            }
        }
    }

    func startGoogleSignIn(app: GoogleOAuthAppConfig) {
        cancelSignIn()
        let resolvedApp = app.resolved(credentials: KeychainCredentialStore())
        guard resolvedApp.isConfigured else {
            signInNotice = "请先在「设置 → 连接」中填写 \(app.displayName) 的 OAuth Client ID（可选 Secret，仅存本机钥匙串），或设置环境变量 \(app.envClientIDKey)。"
            return
        }
        activeSignIn = .googleBrowser(providerName: resolvedApp.displayName)
        signInNotice = "正在打开浏览器进行 \(resolvedApp.displayName) Google 授权…"
        signInTask = Task { [weak self] in
            guard let self else { return }
            let server = LoopbackOAuthServer()
            self.activeLoopbackServer = server
            defer {
                server.stop()
                self.activeLoopbackServer = nil
            }
            do {
                let port = try server.start()
                let redirectURI = "http://\(resolvedApp.loopbackHost):\(port)\(resolvedApp.callbackPath)"
                let state = GoogleOAuthFlow.generateState()
                let pkce = GoogleOAuthFlow.generatePKCE()
                let authURL = GoogleOAuthFlow.authorizationURL(app: resolvedApp, redirectURI: redirectURI, state: state, pkce: pkce)
                NSWorkspace.shared.open(authURL)

                let code = try await server.waitForCode(expectedPath: resolvedApp.callbackPath, expectedState: state)
                self.signInNotice = "已收到授权回调，正在换取令牌…"
                let http = URLSessionHTTPClient()
                let bundle = try await GoogleOAuthFlow.exchangeCode(
                    http: http,
                    app: resolvedApp,
                    code: code,
                    redirectURI: redirectURI,
                    codeVerifier: pkce.verifier
                )
                try bundle.save(to: KeychainCredentialStore(), account: resolvedApp.keychainAccount)
                self.activeSignIn = .idle
                let who = bundle.email.map { "（\($0)）" } ?? ""
                self.signInNotice = "\(resolvedApp.displayName) 登录成功\(who)，正在刷新配额…"
                await self.refresh(force: true)
            } catch is CancellationError {
                self.activeSignIn = .idle
            } catch ProviderError.cancelled {
                self.activeSignIn = .idle
                self.signInNotice = "已取消 \(resolvedApp.displayName) 登录。"
            } catch {
                self.activeSignIn = .idle
                let msg = (error as? ProviderError)?.userMessage ?? error.localizedDescription
                self.signInNotice = "\(resolvedApp.displayName) 登录失败：\(msg)"
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        activeLoopbackServer?.stop()
        activeLoopbackServer = nil
        activeSignIn = .idle
    }

    func launchCLILogin(providerID: String) {
        let result = CLILoginSpec.launchOrCopy(for: providerID)
        signInNotice = result.message
    }

    func signOutOAuth(account: String, label: String) {
        try? KeychainCredentialStore().deleteSecret(account: account)
        signInNotice = "已退出 \(label) 登录。"
        Task { await refresh(force: true) }
    }

    func togglePin(_ accountID: String) {
        Task {
            guard let coordinator else { return }
            let currently = state.snapshots.first(where: { $0.account.id == accountID })?.account.pinned ?? false
            await coordinator.setPinned(accountID: accountID, pinned: !currently)
            state = await coordinator.currentState()
            var prefs = preferences
            if !currently {
                if !prefs.pinnedAccountIDs.contains(accountID) {
                    prefs.pinnedAccountIDs.append(accountID)
                }
            } else {
                prefs.pinnedAccountIDs.removeAll { $0 == accountID }
            }
            preferences = prefs
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
            ClaudeOAuthProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, externalKeychain: NullExternalKeychainReader(), demoFixture: DemoFixtures.claudeUsageJSON),
            CodexOAuthProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.codexUsageJSON),
            CursorSessionProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, cursorStateReader: NullCursorStateReader(), externalKeychain: NullExternalKeychainReader(), demoFixture: DemoFixtures.cursorUsageJSON),
            AntigravityProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.antigravityQuotaJSON),
            GeminiCLIProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.geminiQuotaJSON),
            OpenCodeProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.openCodeUsageJSON),
            DeepSeekProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.deepSeekBalanceJSON),
            CopilotProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, externalKeychain: NullExternalKeychainReader(), ghTokenProvider: { nil }, demoFixture: DemoFixtures.copilotUserJSON),
            KimiCodeProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoSubscriptionFixture: DemoFixtures.kimiCodeUsageJSON, demoBalanceFixture: DemoFixtures.moonshotBalanceJSON),
            MiniMaxProvider(credentials: credentials, http: FixtureHTTPClient(), demoFixture: DemoFixtures.miniMaxRemainsJSON),
            ZaiGLMProvider(credentials: credentials, http: FixtureHTTPClient(), demoFixture: DemoFixtures.zaiQuotaJSON),
            FactoryDroidProvider(credentials: credentials, http: FixtureHTTPClient(), fileSystem: fs, demoFixture: DemoFixtures.factoryUsageJSON),
            OpenRouterProvider(credentials: credentials, http: FixtureHTTPClient(), demoFixture: DemoFixtures.openRouterKeyJSON),
        ]
    }
}

#endif
