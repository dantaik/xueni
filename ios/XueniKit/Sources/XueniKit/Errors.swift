// Errors.swift — what can go wrong between the reader and a node.
//
// One error type for the whole reading path, so that the scanner can ask
// the questions it has to ask — is this a node that failed, a range the node
// refuses, a head the node has not reached — without knowing which
// transport raised it.

import Foundation

public enum ChainError: Error, Sendable, Equatable {
    /// The chain has no endpoints configured at all.
    case noEndpoints
    /// The node could not be reached, or did not answer in time.
    case network(String)
    /// The node answered with an HTTP status that is not an answer.
    case http(status: Int)
    /// The node answered the request with a JSON-RPC error.
    case rpc(code: Int, message: String)
    /// The node's answer could not be read as what was asked for.
    case malformed(String)
    /// A block the chain itself pointed at holds none of the author's posts:
    /// the node serving logs is behind the one that served the head pointer.
    case nodeBehind(block: UInt64)
    /// The request was cancelled by whoever made it.
    case cancelled

    /// What the node said, for matching by keyword.
    public var text: String {
        switch self {
        case .noEndpoints: return "no endpoints"
        case .network(let s): return s
        case .http(let status): return "HTTP \(status)"
        case .rpc(_, let message): return message
        case .malformed(let s): return s
        case .nodeBehind(let block): return "xueni:node-behind \(block)"
        case .cancelled: return "cancelled"
        }
    }

    /// Too many requests: worth backing off and trying again.
    public var isRateLimited: Bool {
        if case .http(let status) = self, status == 429 { return true }
        return matches(text, ["rate limit", "429", "too many requests"])
    }

    /// The NODE failed (network, timeout, HTTP error, rate limit) — try
    /// someone else and remember it briefly. An answer the node gave is not
    /// this: the node is fine, only this request is refused.
    public var isNodeFailure: Bool {
        switch self {
        case .network, .noEndpoints: return true
        case .http: return true
        default: return isRateLimited || matches(text, ["fetch failed", "timed out", "timeout"])
        }
    }

    /// The node caps `eth_getLogs` ranges below our window: halve and retry.
    public var isRangeTooLarge: Bool {
        if isRateLimited { return false }
        guard case .rpc = self else { return false }
        return matches(text, ["range", "too large", "exceed", "limited to", "must not exceed"])
    }

    /// The node has not seen the top of the window we asked for: ask for
    /// one block less, not half.
    public var isBeyondHead: Bool {
        let t = text.lowercased()
        return (t.contains("beyond") && t.contains("head"))
            || (t.contains("exceed") && (t.contains("head") || t.contains("latest")))
    }

    /// Transient in the way exponential backoff fixes.
    public var isRetriable: Bool {
        isRateLimited || matches(text, ["timeout", "timed out", "underlying network", "can't route", "cant route", "suitable provider"])
    }

    private func matches(_ text: String, _ needles: [String]) -> Bool {
        let t = text.lowercased()
        return needles.contains { t.contains($0) }
    }
}
