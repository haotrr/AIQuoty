import Foundation

/// Local JSONL token observers. Output is always MetricKind.locallyObservedTokens / estimated.
/// Never used to invent subscription remaining.
public struct LocalTokenAggregate: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int
    public var uniqueMessageIDs: Int
    public var filesScanned: Int
    public var linesScanned: Int

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }
}

public enum LocalLogDedupe {
    /// Deduplicate Claude assistant streams by message.id + requestId.
    public static func claudeKey(messageID: String?, requestID: String?, sessionID: String?) -> String? {
        if let messageID, let requestID, !messageID.isEmpty, !requestID.isEmpty {
            return "msg:\(messageID)|req:\(requestID)"
        }
        if let messageID, let sessionID, !messageID.isEmpty, !sessionID.isEmpty {
            return "msg:\(messageID)|sess:\(sessionID)"
        }
        return nil
    }
}

public enum ClaudeLocalLogScanner {
    public static func scan(jsonlText: String) -> LocalTokenAggregate {
        var seen = Set<String>()
        var agg = LocalTokenAggregate(
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            uniqueMessageIDs: 0,
            filesScanned: 1,
            linesScanned: 0
        )
        // Keep last complete cumulative chunk per key.
        var latest: [String: (in: Int, out: Int, cacheRead: Int, cacheCreate: Int)] = [:]

        for line in jsonlText.split(whereSeparator: \.isNewline) {
            agg.linesScanned += 1
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let type = obj["type"] as? String
            guard type == "assistant" || obj["message"] != nil else { continue }
            let message = obj["message"] as? [String: Any]
            let usage = message?["usage"] as? [String: Any] ?? obj["usage"] as? [String: Any]
            guard let usage else { continue }
            let messageID = message?["id"] as? String ?? obj["id"] as? String
            let requestID = obj["requestId"] as? String ?? obj["request_id"] as? String
            let sessionID = obj["sessionId"] as? String ?? obj["session_id"] as? String
            let key = LocalLogDedupe.claudeKey(messageID: messageID, requestID: requestID, sessionID: sessionID)
                ?? "line:\(agg.linesScanned)"
            let input = int(usage["input_tokens"])
            let output = int(usage["output_tokens"])
            let cacheRead = int(usage["cache_read_input_tokens"])
            let cacheCreate = int(usage["cache_creation_input_tokens"])
            latest[key] = (input, output, cacheRead, cacheCreate)
            seen.insert(key)
        }
        for value in latest.values {
            agg.inputTokens += value.in
            agg.outputTokens += value.out
            agg.cacheReadTokens += value.cacheRead
            agg.cacheCreationTokens += value.cacheCreate
        }
        agg.uniqueMessageIDs = seen.count
        return agg
    }

    private static func int(_ raw: Any?) -> Int {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let i = Int(s) { return i }
        return 0
    }
}

public enum CodexLocalLogScanner {
    public static func scan(jsonlText: String) -> LocalTokenAggregate {
        var agg = LocalTokenAggregate(
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            uniqueMessageIDs: 0,
            filesScanned: 1,
            linesScanned: 0
        )
        var seen = Set<String>()
        for line in jsonlText.split(whereSeparator: \.isNewline) {
            agg.linesScanned += 1
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            // Native Codex token_count event_msg payloads vary; accept common shapes.
            let payload = obj["payload"] as? [String: Any] ?? obj
            let usage = payload["token_count"] as? [String: Any]
                ?? payload["last_token_usage"] as? [String: Any]
                ?? payload["token_usage"] as? [String: Any]
                ?? obj["usage"] as? [String: Any]
            guard let usage else { continue }
            let id = (obj["id"] as? String) ?? (payload["turn_id"] as? String) ?? "line:\(agg.linesScanned)"
            if seen.contains(id) { continue }
            seen.insert(id)
            agg.inputTokens += int(usage["input_tokens"] ?? usage["input"])
            agg.outputTokens += int(usage["output_tokens"] ?? usage["output"])
            agg.cacheReadTokens += int(usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"])
            agg.uniqueMessageIDs = seen.count
        }
        return agg
    }

    private static func int(_ raw: Any?) -> Int {
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String, let i = Int(s) { return i }
        return 0
    }
}

public struct LocalClaudeLogProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "local-claude-logs",
        displayName: "本地 Claude 日志（估算）",
        implementationStatus: .implemented,
        authMethods: [.localLogImport],
        supportedMetricKinds: [.locallyObservedTokens],
        notes: "扫描用户选择的 ~/.claude/projects JSONL。仅本地观测 token，绝不能当作订阅剩余。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }
    private let fileSystem: FileSystemReading
    private let clock: @Sendable () -> Date
    private let rootPath: String
    private let enabled: Bool

    public init(
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() },
        rootPath: String = "~/.claude/projects",
        enabled: Bool = false
    ) {
        self.fileSystem = fileSystem
        self.clock = clock
        self.rootPath = rootPath
        self.enabled = enabled
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        guard enabled, fileSystem.fileExists(at: rootPath) else { return [] }
        return [AccountIdentity(id: "local.claude", providerID: "local-claude-logs", displayName: "本机 Claude 日志")]
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        guard enabled else {
            throw ProviderError.notConfigured("未启用本地 Claude 日志导入（需用户明确同意）")
        }
        let files = try fileSystem.listFiles(at: rootPath, recursive: true).filter { $0.hasSuffix(".jsonl") }
        var total = LocalTokenAggregate(
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
            uniqueMessageIDs: 0, filesScanned: 0, linesScanned: 0
        )
        for file in files.prefix(500) {
            let text = (try? fileSystem.readUTF8(at: file)) ?? ""
            let part = ClaudeLocalLogScanner.scan(jsonlText: text)
            total.inputTokens += part.inputTokens
            total.outputTokens += part.outputTokens
            total.cacheReadTokens += part.cacheReadTokens
            total.cacheCreationTokens += part.cacheCreationTokens
            total.uniqueMessageIDs += part.uniqueMessageIDs
            total.filesScanned += 1
            total.linesScanned += part.linesScanned
        }
        let source = SourceAttribution(id: "local.claude.jsonl", label: "本地 Claude JSONL", detail: rootPath)
        let metric = MetricValue(
            kind: .locallyObservedTokens,
            precision: .estimated,
            unit: .tokens,
            value: Double(total.totalTokens),
            display: "约 \(total.totalTokens) tokens（本地）",
            source: source,
            capturedAt: now,
            freshness: .fresh
        )
        return [
            AccountSnapshot(
                account: AccountIdentity(id: "local.claude", providerID: "local-claude-logs", displayName: "本机 Claude 日志"),
                connection: .connected,
                localTokenMetrics: [metric],
                lastSuccessAt: now,
                lastAttemptAt: now,
                notes: [
                    "估算值，不等于订阅剩余。",
                    "扫描 \(total.filesScanned) 个文件 / \(total.linesScanned) 行，去重键 \(total.uniqueMessageIDs) 个。",
                ]
            ),
        ]
    }
}

public struct LocalCodexLogProvider: QuotaProvider {
    public static let descriptor = ProviderDescriptor(
        id: "local-codex-logs",
        displayName: "本地 Codex 日志（估算）",
        implementationStatus: .implemented,
        authMethods: [.localLogImport],
        supportedMetricKinds: [.locallyObservedTokens],
        notes: "扫描用户选择的 ~/.codex/sessions JSONL。仅本地观测 token。"
    )

    public var descriptor: ProviderDescriptor { Self.descriptor }
    private let fileSystem: FileSystemReading
    private let clock: @Sendable () -> Date
    private let rootPath: String
    private let enabled: Bool

    public init(
        fileSystem: FileSystemReading,
        clock: @escaping @Sendable () -> Date = { Date() },
        rootPath: String = "~/.codex/sessions",
        enabled: Bool = false
    ) {
        self.fileSystem = fileSystem
        self.clock = clock
        self.rootPath = rootPath
        self.enabled = enabled
    }

    public func configuredAccounts() async -> [AccountIdentity] {
        guard enabled, fileSystem.fileExists(at: rootPath) else { return [] }
        return [AccountIdentity(id: "local.codex", providerID: "local-codex-logs", displayName: "本机 Codex 日志")]
    }

    public func fetch(request: ProviderFetchRequest) async throws -> [AccountSnapshot] {
        let now = request.now
        guard enabled else {
            throw ProviderError.notConfigured("未启用本地 Codex 日志导入")
        }
        let files = try fileSystem.listFiles(at: rootPath, recursive: true).filter { $0.hasSuffix(".jsonl") }
        var total = LocalTokenAggregate(
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
            uniqueMessageIDs: 0, filesScanned: 0, linesScanned: 0
        )
        for file in files.prefix(500) {
            let text = (try? fileSystem.readUTF8(at: file)) ?? ""
            let part = CodexLocalLogScanner.scan(jsonlText: text)
            total.inputTokens += part.inputTokens
            total.outputTokens += part.outputTokens
            total.cacheReadTokens += part.cacheReadTokens
            total.uniqueMessageIDs += part.uniqueMessageIDs
            total.filesScanned += 1
            total.linesScanned += part.linesScanned
        }
        let source = SourceAttribution(id: "local.codex.jsonl", label: "本地 Codex JSONL", detail: rootPath)
        let metric = MetricValue(
            kind: .locallyObservedTokens,
            precision: .estimated,
            unit: .tokens,
            value: Double(total.totalTokens),
            display: "约 \(total.totalTokens) tokens（本地）",
            source: source,
            capturedAt: now,
            freshness: .fresh
        )
        return [
            AccountSnapshot(
                account: AccountIdentity(id: "local.codex", providerID: "local-codex-logs", displayName: "本机 Codex 日志"),
                connection: .connected,
                localTokenMetrics: [metric],
                lastSuccessAt: now,
                lastAttemptAt: now,
                notes: ["估算值，不等于 Codex 订阅剩余。"]
            ),
        ]
    }
}
