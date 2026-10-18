import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProviderError: Error, CustomStringConvertible, Sendable {
    case http(Int, String)
    case throttled(String)
    case notFound(String)
    case unsupported(String)
    case parse(String)
    case missingKey
    case notInPlan(String)
    case network(String)

    public var description: String {
        switch self {
        case .http(let c, let s): return "HTTP \(c): \(s.prefix(160))"
        case .throttled(let s): return "Gedrosselt: \(s)"
        case .notFound(let s): return "Nicht gefunden: \(s)"
        case .unsupported(let s): return "Nicht unterstützt: \(s)"
        case .parse(let s): return "Antwort unlesbar: \(s)"
        case .missingKey: return "API-Schlüssel fehlt"
        case .notInPlan(let s): return "Nicht im Gratis-Tarif: \(s)"
        case .network(let s): return "Netzwerk: \(s)"
        }
    }

    /// Errors that say "this provider is unhappy right now" rather than "this symbol is wrong".
    public var isProviderWide: Bool {
        switch self {
        case .throttled, .network, .missingKey: return true
        case .http(let c, _): return c == 401 || c == 403 || c == 429 || c >= 500
        default: return false
        }
    }
}

/// Small wrapper around URLSession that works the same on macOS, iOS and Linux.
public final class HTTPClient: @unchecked Sendable {
    public static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    public let session: URLSession

    public init(timeout: TimeInterval = 20) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 3
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.httpAdditionalHeaders = [
            "User-Agent": HTTPClient.browserUA,
            "Accept-Language": "de-DE,de;q=0.9,en;q=0.8",
        ]
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    cont.resume(throwing: ProviderError.network(error.localizedDescription))
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    cont.resume(throwing: ProviderError.network("keine HTTP-Antwort"))
                    return
                }
                cont.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url)
        r.httpMethod = "GET"
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return try await send(r)
    }

    public func post(_ url: URL, body: Data, contentType: String, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = body
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return try await send(r)
    }

    /// GET returning parsed JSON; maps HTTP errors to `ProviderError`.
    public func json(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        let (data, resp) = try await get(url, headers: headers)
        try HTTPClient.check(resp, data)
        return try HTTPClient.parse(data)
    }

    public static func check(_ resp: HTTPURLResponse, _ data: Data) throws {
        let code = resp.statusCode
        guard !(200..<300).contains(code) else { return }
        let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
        if code == 429 { throw ProviderError.throttled(text) }
        if code == 404 { throw ProviderError.notFound(text) }
        throw ProviderError.http(code, text)
    }

    public static func parse(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let text = String(data: data.prefix(120), encoding: .utf8) ?? ""
            throw ProviderError.parse(text)
        }
    }
}

public extension URL {
    /// Builds a URL from a base string and query items, percent-encoding values.
    static func make(_ base: String, _ query: [(String, String)] = []) -> URL {
        var c = URLComponents(string: base)!
        if !query.isEmpty {
            c.queryItems = (c.queryItems ?? []) + query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves "+" alone; encode it so it is not read as a space.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return c.url!
    }
}

/// Limits parallel requests and enforces a minimum spacing per provider.
public actor RequestGate {
    private let maxConcurrent: Int
    private let minInterval: TimeInterval
    private var running = 0
    private var lastStart = Date.distantPast
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int, minInterval: TimeInterval) {
        self.maxConcurrent = maxConcurrent
        self.minInterval = minInterval
    }

    public func acquire() async {
        while running >= maxConcurrent {
            await withCheckedContinuation { waiters.append($0) }
        }
        running += 1
        let wait = minInterval - Date().timeIntervalSince(lastStart)
        lastStart = Date().addingTimeInterval(max(0, wait))
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    public func release() {
        running -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let r = try await body()
            release()
            return r
        } catch {
            release()
            throw error
        }
    }
}
