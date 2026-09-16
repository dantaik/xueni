// JSONRPC.swift — talking to a node, with ordered failover.
//
// The endpoint list is the reader's preference order: the first one is
// used, the next one covers for it when it fails. A failed endpoint is put
// on a short cool-down rather than dropped, so one bad node costs one round
// trip, not one per request. The distinction that matters: a NODE failure
// (network, timeout, HTTP error, rate limit) means try someone else and
// remember it briefly; an ANSWER the node gave — "range too large", a
// revert — is not a failure of the node, though the next endpoint is still
// tried in case it is more permissive, and the last error propagates.
//
// The HTTP layer is injectable (`RPCRequester`), so the failover rules are
// tested without a network, and the whole client is a protocol
// (`RPCClient`), so ChainIO is tested over an in-memory node.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - A JSON value, without `Any`

public indirect enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> JSON? {
        object?[key]
    }

    /// A hex quantity field, as a number.
    public func quantity(_ key: String) -> UInt64? {
        self[key]?.string.flatMap(Hex.parseQuantity)
    }
}

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - The wire

/// One HTTP POST. Returns the body and the status.
public protocol RPCRequester: Sendable {
    func post(_ url: URL, body: Data, timeout: TimeInterval) async throws -> (Data, Int)
}

public struct URLSessionRequester: RPCRequester {
    public init() {}

    public func post(_ url: URL, body: Data, timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = timeout
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Int), Error>) in
                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error = error {
                        cont.resume(throwing: ChainError.network(error.localizedDescription))
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    cont.resume(returning: (data ?? Data(), status))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        func set(_ t: URLSessionDataTask) {
            lock.lock(); task = t; lock.unlock()
        }
        func cancel() {
            lock.lock(); task?.cancel(); lock.unlock()
        }
    }
}

/// Something that answers JSON-RPC calls.
public protocol RPCClient: Sendable {
    func call(_ method: String, _ params: [JSON]) async throws -> JSON
}

private struct RequestBody: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [JSON]
}

private struct ResponseError: Decodable {
    let code: Int
    let message: String
}

private struct ResponseBody: Decodable {
    let result: JSON?
    let error: ResponseError?
}

/// The ordered failover: walks the endpoints in order, skipping those still
/// cooling off from a recent failure (they are tried last, never dropped).
public actor OrderedTransport: RPCClient {
    public static let cooldown: TimeInterval = 30
    public static let timeout: TimeInterval = 8

    private struct Node {
        let url: URL
        var downUntil: Date?
    }

    private var nodes: [Node]
    private let requester: RPCRequester
    private let now: @Sendable () -> Date
    private var nextId = 1
    /// Every request, for a console: method, endpoint and outcome.
    public var log: (@Sendable (String) -> Void)?

    public init(urls: [String], requester: RPCRequester = URLSessionRequester(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.nodes = urls.compactMap(URL.init(string:)).map { Node(url: $0, downUntil: nil) }
        self.requester = requester
        self.now = now
    }

    /// The endpoint list, as the settings page sees it.
    public var urls: [String] { nodes.map { $0.url.absoluteString } }

    /// A changed endpoint list applies to the next request, even mid-sweep.
    public func setURLs(_ urls: [String]) {
        let fresh = urls.compactMap(URL.init(string:))
        nodes = fresh.map { url in Node(url: url, downUntil: nodes.first { $0.url == url }?.downUntil) }
    }

    public func setLog(_ log: (@Sendable (String) -> Void)?) {
        self.log = log
    }

    public func call(_ method: String, _ params: [JSON]) async throws -> JSON {
        guard !nodes.isEmpty else { throw ChainError.noEndpoints }
        let at = now()
        let order = nodes.indices.filter { nodes[$0].downUntil.map { $0 <= at } ?? true }
            + nodes.indices.filter { nodes[$0].downUntil.map { $0 > at } ?? false }
        let id = nextId
        nextId += 1
        let body = try JSONEncoder().encode(RequestBody(id: id, method: method, params: params))
        var lastError: ChainError = .noEndpoints
        for (i, index) in order.enumerated() {
            let node = nodes[index]
            do {
                let out = try await send(body, to: node.url, method: method)
                nodes[index].downUntil = nil
                return out
            } catch let error as ChainError {
                if case .cancelled = error { throw error }
                lastError = error
                if error.isNodeFailure { nodes[index].downUntil = now().addingTimeInterval(Self.cooldown) }
                if i < order.count - 1 {
                    log?("\(method): \(node.url.host ?? node.url.absoluteString) failed (\(error.text)); trying \(nodes[order[i + 1]].url.host ?? "next")")
                }
            }
        }
        throw lastError
    }

    private func send(_ body: Data, to url: URL, method: String) async throws -> JSON {
        if Task.isCancelled { throw ChainError.cancelled }
        let (data, status): (Data, Int)
        do {
            (data, status) = try await requester.post(url, body: body, timeout: Self.timeout)
        } catch let error as ChainError {
            throw error
        } catch {
            throw ChainError.network(String(describing: error))
        }
        if Task.isCancelled { throw ChainError.cancelled }
        guard (200..<300).contains(status) else { throw ChainError.http(status: status) }
        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw ChainError.malformed("\(method): the answer was not JSON-RPC")
        }
        if let err = decoded.error { throw ChainError.rpc(code: err.code, message: err.message) }
        return decoded.result ?? .null
    }
}

// MARK: - Retrying

public enum Retry {
    /// Retry with exponential backoff on transient public-RPC failures
    /// (rate limits, timeouts). Throws the original error after the last attempt.
    public static func withBackoff<T>(retries: Int = 2, baseDelay: TimeInterval = 1.2, _ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch let error as ChainError {
                guard error.isRetriable, attempt < retries else { throw error }
                let delay = baseDelay * pow(2, Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }
}
