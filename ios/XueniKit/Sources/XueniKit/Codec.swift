// Codec.swift — call data → post (SPEC §6), the reading direction.
//
// The three publishing calls share a title word and a payload tail; the
// reader tells them apart by selector, reads every offset from its head
// word rather than assuming it, and refuses call data that is cut short or
// holds an address word that is not an address. What else the call
// carries — the hook and its data, and for a relayed post the author, the
// deadline and the signature — is handed on as data and never interpreted.

import Foundation

public enum CodecError: Error, Equatable, Sendable {
    case notAPublishCall(selector: String)
    case malformedCallData(String)
}

public enum CallForm: String, Sendable, Equatable {
    case publish
    case publishWithHook
    case publishFor
}

public struct RelayedCall: Sendable, Equatable {
    /// The author of record, lowercase.
    public let author: String
    /// The deadline as a decimal string: it is a uint256, and no reader does arithmetic on it.
    public let deadline: String
    public let signature: [UInt8]
}

public struct PublishCall: Sendable, Equatable {
    public let form: CallForm
    public let titleWord: [UInt8]
    public let payload: [UInt8]
    /// The hook the post named, lowercase, or nil for a plain post / the zero address.
    public let hook: String?
    public let hookData: [UInt8]
    public let relayed: RelayedCall?

    public var title: String { Title.decode(titleWord) }
}

/// A post as read back from the chain: the presentation plus the exact text.
public struct DecodedPost: Sendable, Equatable {
    public let title: String
    public let tags: [String]
    public let markdown: String
    public let meta: [String: String]
    public let metaOrder: [String]
    /// The document byte for byte, U+FFFD where it was not UTF-8.
    public let text: String
    public let compressedBytes: Int
    public let call: PublishCall
}

public enum Codec {
    /// Read the arguments of any of the three publishing calls.
    public static func decodeCallData(_ bytes: [UInt8]) throws -> PublishCall {
        guard bytes.count >= 4 else { throw CodecError.malformedCallData("shorter than a selector") }
        let selector = Array(bytes[0..<4])
        let body = Array(bytes[4...]) // offsets count from here
        switch selector {
        case ABI.publishSelector:
            guard body.count >= 64 else { throw CodecError.malformedCallData("head cut short") }
            let title = Array(body[0..<32])
            let payload = try tail(in: body, offsetWord: 1, label: "payload")
            return PublishCall(form: .publish, titleWord: title, payload: payload, hook: nil, hookData: [], relayed: nil)
        case ABI.publishWithHookSelector:
            guard body.count >= 128 else { throw CodecError.malformedCallData("head cut short") }
            let title = Array(body[0..<32])
            let payload = try tail(in: body, offsetWord: 1, label: "payload")
            guard let hook = ABI.address(word: body[64..<96]) else { throw CodecError.malformedCallData("the hook word is not an address") }
            let hookData = try tail(in: body, offsetWord: 3, label: "hookData")
            return PublishCall(form: .publishWithHook, titleWord: title, payload: payload, hook: hook == ABI.zeroAddress ? nil : hook, hookData: hookData, relayed: nil)
        case ABI.publishForSelector:
            guard body.count >= 224 else { throw CodecError.malformedCallData("head cut short") }
            guard let author = ABI.address(word: body[0..<32]) else { throw CodecError.malformedCallData("the author word is not an address") }
            let title = Array(body[32..<64])
            let payload = try tail(in: body, offsetWord: 2, label: "payload")
            guard let hook = ABI.address(word: body[96..<128]) else { throw CodecError.malformedCallData("the hook word is not an address") }
            let hookData = try tail(in: body, offsetWord: 4, label: "hookData")
            let deadline = decimal(word: body[160..<192])
            let signature = try tail(in: body, offsetWord: 6, label: "signature")
            return PublishCall(
                form: .publishFor,
                titleWord: title,
                payload: payload,
                hook: hook == ABI.zeroAddress ? nil : hook,
                hookData: hookData,
                relayed: RelayedCall(author: author, deadline: deadline, signature: signature)
            )
        default:
            throw CodecError.notAPublishCall(selector: Hex.string(selector))
        }
    }

    /// The same, from the hex text a node hands back.
    public static func decodeCallData(hex: String) throws -> PublishCall {
        guard let bytes = Hex.bytes(hex) else { throw CodecError.malformedCallData("not hex") }
        return try decodeCallData(bytes)
    }

    /// The whole trip: call data in, the post out.
    public static func readPost(callData: [UInt8], with brotli: BrotliDecompressor) throws -> DecodedPost {
        let call = try decodeCallData(callData)
        let payload = try Payload.decode(call.payload, with: brotli)
        return DecodedPost(
            title: call.title,
            tags: payload.document.tags,
            markdown: payload.document.markdown,
            meta: payload.document.meta,
            metaOrder: payload.document.metaOrder,
            text: payload.text,
            compressedBytes: payload.compressedBytes,
            call: call
        )
    }

    // MARK: - Tails

    /// The bytes of a dynamic argument: its offset is read from head word
    /// `offsetWord`, the length word must fit inside the data, and so must
    /// `length` bytes after it (SPEC §6.3, steps 2, 3 and 5).
    private static func tail(in body: [UInt8], offsetWord: Int, label: String) throws -> [UInt8] {
        let start = offsetWord * 32
        guard body.count >= start + 32, let offset = ABI.uint64(word: body[start..<(start + 32)]) else {
            throw CodecError.malformedCallData("\(label): offset word missing or too large")
        }
        guard offset <= UInt64(Int.max - 32), Int(offset) + 32 <= body.count else {
            throw CodecError.malformedCallData("\(label): offset leaves no room for a length")
        }
        let at = Int(offset)
        guard let length = ABI.uint64(word: body[at..<(at + 32)]), length <= UInt64(Int.max - 32) else {
            throw CodecError.malformedCallData("\(label): length too large")
        }
        let from = at + 32
        guard from + Int(length) <= body.count else {
            throw CodecError.malformedCallData("\(label): cut short")
        }
        return Array(body[from..<(from + Int(length))])
    }

    /// A uint256 word as decimal text, whatever its size.
    private static func decimal(word: ArraySlice<UInt8>) -> String {
        // Schoolbook base conversion over bytes: small (32 bytes) and rare.
        var digits: [UInt8] = [0]
        for byte in word {
            var carry = Int(byte)
            for i in 0..<digits.count {
                let v = Int(digits[i]) * 256 + carry
                digits[i] = UInt8(v % 10)
                carry = v / 10
            }
            while carry > 0 {
                digits.append(UInt8(carry % 10))
                carry /= 10
            }
        }
        return String(digits.reversed().map { Character(UnicodeScalar($0 + 48)) })
    }
}
