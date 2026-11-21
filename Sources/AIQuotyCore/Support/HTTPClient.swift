import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public var bodyText: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.network("非 HTTP 响应")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    headers[k.lowercased()] = v
                }
            }
            return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
    }
}

public struct FixtureHTTPClient: HTTPClient {
    public var responses: [String: HTTPResponse]

    public init(responses: [String: HTTPResponse] = [:]) {
        self.responses = responses
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let key = request.url.absoluteString
        if let exact = responses[key] { return exact }
        if let match = responses.first(where: { key.contains($0.key) })?.value {
            return match
        }
        throw ProviderError.network("Fixture 未命中：\(key)")
    }
}

public enum HTTPStatusMapper {
    public static func mapFailure(status: Int, body: String, headers: [String: String] = [:]) -> ProviderError {
        if status == 401 || status == 403 {
            return .authRequired("HTTP \(status)")
        }
        if status == 429 {
            let retry = headers["retry-after"].flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retry)
        }
        return .httpStatus(status, body: String(body.prefix(500)))
    }
}
