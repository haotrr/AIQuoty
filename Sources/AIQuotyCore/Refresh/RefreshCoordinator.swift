import Foundation

/// Single owner of connection/refresh state across all providers.
public actor RefreshCoordinator {
    public struct State: Sendable, Equatable {
        public var snapshots: [AccountSnapshot]
        public var providerErrors: [String: String]
        public var isRefreshing: Bool
        public var lastRefreshAt: Date?
        public var nextAllowedAt: Date?
        public var demoMode: Bool

        public init(
            snapshots: [AccountSnapshot] = [],
            providerErrors: [String: String] = [:],
            isRefreshing: Bool = false,
            lastRefreshAt: Date? = nil,
            nextAllowedAt: Date? = nil,
            demoMode: Bool = false
        ) {
            self.snapshots = snapshots
            self.providerErrors = providerErrors
            self.isRefreshing = isRefreshing
            self.lastRefreshAt = lastRefreshAt
            self.nextAllowedAt = nextAllowedAt
            self.demoMode = demoMode
        }

        public var pinned: [AccountSnapshot] {
            snapshots.filter(\.account.pinned)
        }
    }

    private var providers: [any QuotaProvider]
    private var state = State()
    private var backoffSeconds: [String: TimeInterval] = [:]
    private var pinnedIDs: Set<String> = []
    private let baseInterval: TimeInterval
    private let maxBackoff: TimeInterval

    public init(
        providers: [any QuotaProvider],
        baseInterval: TimeInterval = 300,
        maxBackoff: TimeInterval = 3600
    ) {
        self.providers = providers
        self.baseInterval = baseInterval
        self.maxBackoff = maxBackoff
    }

    public func currentState() -> State { state }

    public func setDemoMode(_ enabled: Bool) {
        state.demoMode = enabled
    }

    public func setPinned(accountID: String, pinned: Bool) {
        if pinned {
            pinnedIDs.insert(accountID)
        } else {
            pinnedIDs.remove(accountID)
        }
        state.snapshots = Self.sorted(state.snapshots.map { snap in
            guard snap.account.id == accountID else { return snap }
            var copy = snap
            copy.account.pinned = pinned
            return copy
        })
    }

    public func applyPinnedAccountIDs(_ ids: Set<String>) {
        pinnedIDs.formUnion(ids)
        guard !pinnedIDs.isEmpty else { return }
        state.snapshots = Self.sorted(state.snapshots.map { snap in
            guard pinnedIDs.contains(snap.account.id) else { return snap }
            var copy = snap
            copy.account.pinned = true
            return copy
        })
    }

    private static func sorted(_ snapshots: [AccountSnapshot]) -> [AccountSnapshot] {
        snapshots.sorted { lhs, rhs in
            if lhs.account.pinned != rhs.account.pinned { return lhs.account.pinned && !rhs.account.pinned }
            return lhs.account.displayName.localizedStandardCompare(rhs.account.displayName) == .orderedAscending
        }
    }

    public func setGroup(accountID: String, group: String?) {
        state.snapshots = state.snapshots.map { snap in
            guard snap.account.id == accountID else { return snap }
            var copy = snap
            copy.account.group = group
            return copy
        }
    }

    public func filtered(query: String) -> [AccountSnapshot] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return state.snapshots }
        return state.snapshots.filter { snap in
            snap.account.displayName.lowercased().contains(q)
                || (snap.account.email?.lowercased().contains(q) ?? false)
                || snap.account.providerID.lowercased().contains(q)
                || (snap.account.group?.lowercased().contains(q) ?? false)
        }
    }

    @discardableResult
    public func refreshAll(force: Bool = false, now: Date = Date()) async -> State {
        if state.isRefreshing { return state }
        if !force, let next = state.nextAllowedAt, now < next {
            return state
        }
        state.isRefreshing = true
        defer { state.isRefreshing = false }

        var nextSnapshots: [AccountSnapshot] = []
        var errors: [String: String] = [:]
        // Preserve previous by account id for stale marking / isolation.
        let previousByID = Dictionary(uniqueKeysWithValues: state.snapshots.map { ($0.account.id, $0) })

        enum ProviderOutcome: Sendable {
            case success(pid: String, snapshots: [AccountSnapshot])
            case failure(pid: String, displayName: String, error: ProviderError)
        }

        var activeProviders: [any QuotaProvider] = []
        for provider in providers {
            let pid = provider.descriptor.id
            if !force, let wait = backoffSeconds[pid], wait > 0,
               let last = state.lastRefreshAt,
               now.timeIntervalSince(last) < wait {
                nextSnapshots.append(contentsOf: state.snapshots.filter { $0.account.providerID == pid })
                errors[pid] = "退避中（\(Int(wait))s）"
                continue
            }
            activeProviders.append(provider)
        }

        let demoMode = state.demoMode
        let outcomes: [ProviderOutcome] = await withTaskGroup(of: ProviderOutcome.self) { group in
            for provider in activeProviders {
                let pid = provider.descriptor.id
                let displayName = provider.descriptor.displayName
                group.addTask {
                    do {
                        let fetched = try await provider.fetch(
                            request: ProviderFetchRequest(force: force, now: now, demoMode: demoMode)
                        )
                        return .success(pid: pid, snapshots: fetched)
                    } catch {
                        let providerError = (error as? ProviderError) ?? .network(String(describing: error))
                        return .failure(pid: pid, displayName: displayName, error: providerError)
                    }
                }
            }
            var collected: [ProviderOutcome] = []
            for await item in group {
                collected.append(item)
            }
            return collected
        }

        for outcome in outcomes {
            switch outcome {
            case .success(let pid, let fetched):
                let merged = fetched.map { fresh -> AccountSnapshot in
                    var copy = fresh
                    if let old = previousByID[fresh.account.id] {
                        copy.account.pinned = old.account.pinned
                        copy.account.group = old.account.group
                    }
                    if pinnedIDs.contains(fresh.account.id) {
                        copy.account.pinned = true
                    }
                    return copy
                }
                nextSnapshots.append(contentsOf: merged)
                backoffSeconds[pid] = 0
            case .failure(let pid, let displayName, let providerError):
                let prior = state.snapshots.filter { $0.account.providerID == pid }
                switch providerError {
                case .notConfigured:
                    // Silent skip for unconfigured providers — no fake rows, no error badge.
                    continue
                case .rateLimited(let retry):
                    errors[pid] = providerError.userMessage
                    let delay = min(max(retry ?? 60, 30), maxBackoff)
                    backoffSeconds[pid] = delay
                    nextSnapshots.append(contentsOf: prior.map { $0.markingRateLimited(retryAfter: delay, at: now) })
                case .authRequired:
                    errors[pid] = providerError.userMessage
                    let prevBackoff = backoffSeconds[pid] ?? 0
                    backoffSeconds[pid] = min(max(prevBackoff * 2, 30), maxBackoff)
                    if prior.isEmpty {
                        nextSnapshots.append(
                            AccountSnapshot(
                                account: AccountIdentity(id: "\(pid).missing", providerID: pid, displayName: displayName),
                                connection: .authRequired,
                                lastAttemptAt: now,
                                lastError: providerError.userMessage
                            )
                        )
                    } else {
                        nextSnapshots.append(contentsOf: prior.map {
                            var c = $0.markingStale(error: providerError.userMessage, at: now)
                            c.connection = .authRequired
                            return c
                        })
                    }
                default:
                    errors[pid] = providerError.userMessage
                    backoffSeconds[pid] = min(max((backoffSeconds[pid] ?? baseInterval / 2) * 2, 60), maxBackoff)
                    nextSnapshots.append(contentsOf: prior.map { $0.markingStale(error: providerError.userMessage, at: now) })
                }
            }
        }

        // Deduplicate by account id (last write wins within provider batch already unique).
        var unique: [String: AccountSnapshot] = [:]
        for snap in nextSnapshots {
            unique[snap.account.id] = snap
        }
        state.snapshots = Self.sorted(Array(unique.values))
        state.providerErrors = errors
        state.lastRefreshAt = now
        state.nextAllowedAt = now.addingTimeInterval(baseInterval)
        return state
    }
}

public enum CountdownFormatter {
    public static func format(seconds: TimeInterval?) -> String {
        guard let seconds else { return "重置未知" }
        if seconds <= 0 { return "已到重置点" }
        let total = Int(seconds.rounded())
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)天 \(hours)小时" }
        if hours > 0 { return "\(hours)小时 \(minutes)分" }
        return "\(minutes) 分"
    }
}
