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
        state.snapshots = state.snapshots.map { snap in
            guard snap.account.id == accountID else { return snap }
            var copy = snap
            copy.account.pinned = pinned
            return copy
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

        for provider in providers {
            let pid = provider.descriptor.id
            if !force, let wait = backoffSeconds[pid], wait > 0,
               let last = state.lastRefreshAt,
               now.timeIntervalSince(last) < wait {
                // Keep previous snapshots for this provider during backoff.
                nextSnapshots.append(contentsOf: state.snapshots.filter { $0.account.providerID == pid })
                errors[pid] = "退避中（\(Int(wait))s）"
                continue
            }
            do {
                let fetched = try await provider.fetch(
                    request: ProviderFetchRequest(force: force, now: now, demoMode: state.demoMode)
                )
                // Account isolation: only replace this provider's rows.
                let merged = fetched.map { fresh -> AccountSnapshot in
                    if let old = previousByID[fresh.account.id] {
                        var copy = fresh
                        copy.account.pinned = old.account.pinned
                        copy.account.group = old.account.group
                        return copy
                    }
                    return fresh
                }
                nextSnapshots.append(contentsOf: merged)
                backoffSeconds[pid] = 0
            } catch {
                let providerError = (error as? ProviderError) ?? .network(String(describing: error))
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
                    backoffSeconds[pid] = min((backoffSeconds[pid] ?? 30) * 2, maxBackoff)
                    if prior.isEmpty {
                        nextSnapshots.append(
                            AccountSnapshot(
                                account: AccountIdentity(id: "\(pid).missing", providerID: pid, displayName: provider.descriptor.displayName),
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
        state.snapshots = Array(unique.values).sorted { lhs, rhs in
            if lhs.account.pinned != rhs.account.pinned { return lhs.account.pinned && !rhs.account.pinned }
            return lhs.account.displayName.localizedStandardCompare(rhs.account.displayName) == .orderedAscending
        }
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
