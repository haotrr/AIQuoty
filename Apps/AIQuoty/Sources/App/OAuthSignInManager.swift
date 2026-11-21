#if os(macOS)
import Foundation
import AppKit
import Darwin
import AIQuotyCore

/// Ephemeral 127.0.0.1 HTTP loopback server (RFC 8252) for native OAuth redirects.
final class LoopbackOAuthServer: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var cancelled = false

    private(set) var port: UInt16 = 0

    func start() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ProviderError.network("无法创建本地 OAuth 回调 socket")
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw ProviderError.network("无法绑定本地 OAuth 回调端口")
        }
        guard Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw ProviderError.network("无法监听本地 OAuth 回调端口")
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw ProviderError.network("无法获取本地回调端口")
        }

        lock.lock()
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)
        lock.unlock()
        return self.port
    }

    func waitForCode(expectedPath: String, expectedState: String, timeoutSeconds: TimeInterval = 180) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ProviderError.cancelled)
                    return
                }
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                defer { self.stop() }

                while Date() < deadline {
                    self.lock.lock()
                    let fd = self.listenFD
                    let isCancelled = self.cancelled
                    self.lock.unlock()
                    if isCancelled || fd < 0 {
                        continuation.resume(throwing: ProviderError.cancelled)
                        return
                    }

                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = Darwin.poll(&pfd, 1, 300)
                    if ready <= 0 { continue }

                    var clientAddr = sockaddr_in()
                    var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.accept(fd, $0, &clientLen)
                        }
                    }
                    if clientFD < 0 { continue }
                    defer { Darwin.close(clientFD) }

                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let readBytes = Darwin.recv(clientFD, &buffer, buffer.count, 0)
                    guard readBytes > 0 else { continue }
                    let rawRequest = String(decoding: buffer[0..<readBytes], as: UTF8.self)
                    guard let firstLine = rawRequest.split(separator: "\r\n").first ?? rawRequest.split(separator: "\n").first else {
                        continue
                    }
                    let parts = firstLine.split(separator: " ")
                    guard parts.count >= 2 else { continue }
                    let target = String(parts[1])
                    guard let comps = URLComponents(string: "http://127.0.0.1\(target)") else { continue }
                    if comps.path != expectedPath {
                        self.sendHTML(fd: clientFD, status: "404 Not Found", title: "AIQuoty", body: "无效回调路径。")
                        continue
                    }
                    let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                    if let err = items["error"], !err.isEmpty {
                        self.sendHTML(fd: clientFD, status: "200 OK", title: "授权已取消", body: "授权未完成（\(err)），可关闭此标签页返回 AIQuoty。")
                        continuation.resume(throwing: ProviderError.authRequired("浏览器授权未完成：\(err)"))
                        return
                    }
                    guard items["state"] == expectedState else {
                        self.sendHTML(fd: clientFD, status: "400 Bad Request", title: "校验失败", body: "State 参数不匹配，请回到 AIQuoty 重试。")
                        continuation.resume(throwing: ProviderError.authRequired("OAuth state 校验失败"))
                        return
                    }
                    guard let code = items["code"], !code.isEmpty else {
                        self.sendHTML(fd: clientFD, status: "400 Bad Request", title: "缺少授权码", body: "未收到 code 参数。")
                        continuation.resume(throwing: ProviderError.authRequired("OAuth 回调缺少 code"))
                        return
                    }
                    self.sendHTML(fd: clientFD, status: "200 OK", title: "AIQuoty 授权成功", body: "已完成授权，正在同步配额。你可以关闭此页面并返回菜单栏应用。")
                    continuation.resume(returning: code)
                    return
                }
                continuation.resume(throwing: ProviderError.authRequired("浏览器授权超时，请重试。"))
            }
        }
    }

    func stop() {
        lock.lock()
        cancelled = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    private func sendHTML(fd: Int32, status: String, title: String, body: String) {
        let html = """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:460px;margin:72px auto;padding:24px;color:#1d1d1f;line-height:1.6}
        h2{margin:0 0 8px}p{color:#6e6e73}</style></head><body><h2>\(title)</h2><p>\(body)</p></body></html>
        """
        let bodyData = Data(html.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        let full = Data(header.utf8) + bodyData
        full.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                _ = Darwin.send(fd, base, full.count, 0)
            }
        }
    }
}

enum CLILoginSpec {
    struct Entry {
        let providerID: String
        let displayName: String
        let binaryNames: [String]
        let loginCommand: String
        let installHint: String
    }

    static let all: [Entry] = [
        Entry(providerID: "claude", displayName: "Claude Code", binaryNames: ["claude"], loginCommand: "claude", installHint: "npm install -g @anthropic-ai/claude-code && claude"),
        Entry(providerID: "codex", displayName: "Codex", binaryNames: ["codex"], loginCommand: "codex login", installHint: "npm install -g @openai/codex && codex login"),
        Entry(providerID: "cursor", displayName: "Cursor Agent", binaryNames: ["cursor-agent", "agent"], loginCommand: "cursor-agent login", installHint: "curl https://cursor.com/install -fsS | bash && cursor-agent login"),
        Entry(providerID: "gemini", displayName: "Gemini CLI", binaryNames: ["gemini"], loginCommand: "gemini", installHint: "npm install -g @google/gemini-cli && gemini"),
        Entry(providerID: "opencode", displayName: "OpenCode", binaryNames: ["opencode"], loginCommand: "opencode auth login", installHint: "brew install opencode && opencode auth login"),
        Entry(providerID: "kimi-code", displayName: "Kimi CLI", binaryNames: ["kimi"], loginCommand: "kimi login", installHint: "pipx install kimi-cli && kimi login"),
        Entry(providerID: "factory-droid", displayName: "Factory Droid", binaryNames: ["droid"], loginCommand: "droid", installHint: "curl -fsSL https://app.factory.ai/cli | sh && droid"),
        Entry(providerID: "grok", displayName: "Grok CLI", binaryNames: ["grok"], loginCommand: "grok login", installHint: "grok login"),
    ]

    static func entry(for providerID: String) -> Entry? {
        all.first { $0.providerID == providerID }
    }

    static func findBinary(names: [String]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let searchDirs = envPaths + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.cursor/bin",
            "\(home)/.claude/local",
            "\(home)/.grok/bin",
            "\(home)/.npm-global/bin",
        ]
        for dir in searchDirs {
            for name in names {
                let candidate = (dir as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Launches the official CLI login command in macOS Terminal.app, or copies the install+login command if not installed.
    static func launchOrCopy(for providerID: String) -> (launched: Bool, message: String) {
        guard let spec = entry(for: providerID) else {
            return (false, "暂不支持该服务的终端自动登录")
        }
        if let bin = findBinary(names: spec.binaryNames) {
            let escaped = spec.loginCommand.replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            do {
                try proc.run()
                _ = bin
                return (true, "已在终端打开 `\(spec.loginCommand)`，登录完成后点击刷新即可自动读取。")
            } catch {
                copyToClipboard(spec.loginCommand)
                return (false, "已复制命令 `\(spec.loginCommand)`，请粘贴到终端执行。")
            }
        } else {
            copyToClipboard(spec.installHint)
            return (false, "本机未找到 \(spec.displayName) CLI；已复制安装并登录命令到剪贴板，粘贴到终端即可。")
        }
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
#endif
