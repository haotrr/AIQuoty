#if os(macOS)
import Foundation
import Network
import AIQuotyCore

/// Lightweight loopback-only HTTP server embedded in the macOS app.
///
/// Serves the static Web dashboard (`Web/index.html`, `styles.css`, `app.js`)
/// and exposes `/api/status` (live in-memory snapshots) and `/api/status?demo=1`.
final class LocalWebDashboardServer: @unchecked Sendable {
    struct StatusPayload: Encodable {
        let demo: Bool
        let generatedAt: Date
        let snapshots: [AccountSnapshot]
        let providerErrors: [String: String]
    }

    typealias StatusProvider = @Sendable (_ demo: Bool) async -> StatusPayload

    private let queue = DispatchQueue(label: "local.aiquoty.web-dashboard-server")
    private var listener: NWListener?
    private let statusProvider: StatusProvider
    private let preferredPort: UInt16
    private let webRoot: URL?
    private var onReady: (@Sendable (URL) -> Void)?

    private(set) var currentURL: URL?

    init(
        preferredPort: UInt16 = 8787,
        webRoot: URL? = nil,
        statusProvider: @escaping StatusProvider
    ) {
        self.preferredPort = preferredPort
        self.webRoot = webRoot ?? Self.discoverWebRoot()
        self.statusProvider = statusProvider
    }

    deinit {
        stop()
    }

    func start(onReady: @escaping @Sendable (URL) -> Void) {
        self.onReady = onReady
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            self.startListener(port: self.preferredPort, allowFallback: true)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.currentURL = nil
        }
    }

    // MARK: - Listener Setup

    private func startListener(port: UInt16?, allowFallback: Bool) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
            )
            let newListener = try NWListener(using: params)
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let actualPort = newListener.port?.rawValue,
                       let url = URL(string: "http://127.0.0.1:\(actualPort)/") {
                        self.currentURL = url
                        self.onReady?(url)
                    }
                case .failed:
                    newListener.cancel()
                    self.listener = nil
                    if allowFallback && port != nil {
                        self.startListener(port: nil, allowFallback: false)
                    }
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            self.listener = newListener
            newListener.start(queue: queue)
        } catch {
            if allowFallback && port != nil {
                startListener(port: nil, allowFallback: false)
            }
        }
    }

    // MARK: - HTTP Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty,
                  let rawRequest = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let firstLine = rawRequest.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.sendResponse(connection: connection, status: "400 Bad Request", contentType: "text/plain; charset=utf-8", body: Data("Bad Request".utf8))
                return
            }

            let method = String(parts[0])
            let rawTarget = String(parts[1])
            guard method == "GET" || method == "HEAD" else {
                self.sendResponse(connection: connection, status: "405 Method Not Allowed", contentType: "text/plain; charset=utf-8", body: Data("Method Not Allowed".utf8))
                return
            }

            let components = URLComponents(string: "http://127.0.0.1" + rawTarget)
            let path = components?.path ?? "/"

            if path == "/api/status" {
                let demoValue = components?.queryItems?.first(where: { $0.name == "demo" })?.value ?? "0"
                let isDemo = demoValue == "1" || demoValue.lowercased() == "true"
                Task { [weak self] in
                    guard let self else { return }
                    let payload = await self.statusProvider(isDemo)
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let body = (try? encoder.encode(payload)) ?? Data("{}".utf8)
                    self.sendResponse(
                        connection: connection,
                        status: "200 OK",
                        contentType: "application/json; charset=utf-8",
                        body: method == "HEAD" ? Data() : body
                    )
                }
                return
            }

            self.serveStaticFile(path: path, headOnly: method == "HEAD", connection: connection)
        }
    }

    private func serveStaticFile(path: String, headOnly: Bool, connection: NWConnection) {
        guard let root = webRoot else {
            let msg = "AIQuoty Web resources not found."
            sendResponse(connection: connection, status: "500 Internal Server Error", contentType: "text/plain; charset=utf-8", body: Data(msg.utf8))
            return
        }

        let relative: String
        switch path {
        case "/", "/index.html":
            relative = "index.html"
        case "/styles.css":
            relative = "styles.css"
        case "/app.js":
            relative = "app.js"
        default:
            sendResponse(connection: connection, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not Found".utf8))
            return
        }

        let fileURL = root.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: fileURL) else {
            sendResponse(connection: connection, status: "404 Not Found", contentType: "text/plain; charset=utf-8", body: Data("Not Found".utf8))
            return
        }

        sendResponse(
            connection: connection,
            status: "200 OK",
            contentType: Self.mimeType(for: relative),
            body: headOnly ? Data() : data
        )
    }

    private func sendResponse(connection: NWConnection, status: String, contentType: String, body: Data) {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r\n
        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Helpers

    private static func mimeType(for filename: String) -> String {
        if filename.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if filename.hasSuffix(".css") { return "text/css; charset=utf-8" }
        if filename.hasSuffix(".js") { return "application/javascript; charset=utf-8" }
        return "application/octet-stream"
    }

    /// Locate `Web/` inside the `.app` bundle, or fall back to workspace `web/` during development.
    private static func discoverWebRoot() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Web", isDirectory: true))
            candidates.append(resourceURL.appendingPathComponent("web", isDirectory: true))
        }

        // Dev fallback: walk up from current working directory and executable path.
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("web", isDirectory: true))

        if let execURL = Bundle.main.executableURL {
            var dir = execURL.deletingLastPathComponent()
            for _ in 0..<5 {
                candidates.append(dir.appendingPathComponent("web", isDirectory: true))
                dir.deleteLastPathComponent()
            }
        }

        for dir in candidates {
            let index = dir.appendingPathComponent("index.html")
            if fm.fileExists(atPath: index.path) {
                return dir
            }
        }
        return nil
    }
}
#endif
