// Payload.swift — the brotli boundary (SPEC §5).
//
// A version-1 payload is one raw brotli stream of the document's UTF-8
// bytes. The first byte says which format version a payload is: 0x91 is a
// version envelope no brotli stream can begin with; anything else is
// version 1. A reader bounds the decompressed size WHILE decompressing —
// 106 bytes can otherwise unpack into 64 MiB — and refuses what passes it.
//
// The decompressor is an argument, exactly as in the reference library: the
// app binds Apple's Compression framework (below, where it exists), and the
// tests bind a stand-in, so the rules here are checked on Linux too.

import Foundation

public enum PayloadError: Error, Equatable, Sendable {
    case emptyPayload
    case malformedPayload(String)
    case unsupportedFormatVersion(Int)
    case documentTooLarge(bound: Int)
}

/// Something that turns a brotli stream back into bytes, stopping once the
/// output passes `maxOutputBytes`.
public protocol BrotliDecompressor: Sendable {
    func decompress(_ input: [UInt8], maxOutputBytes: Int) throws -> [UInt8]
}

public struct DecodedPayload: Sendable, Equatable {
    /// The exact document the chain holds, U+FFFD where the bytes are not UTF-8.
    public let text: String
    public let document: ParsedDocument
    /// What the post cost to store: the payload's own size.
    public let compressedBytes: Int
}

public enum Payload {
    public static let formatVersion = 1
    public static let versionEnvelopeByte: UInt8 = 0x91
    /// The reference bound: a document over 4 MiB is refused on both sides.
    public static let maxDocumentBytes = 4 * 1024 * 1024

    /// Which format version a payload is (SPEC §5.2).
    public static func detectFormatVersion(_ bytes: [UInt8]) throws -> Int {
        guard let first = bytes.first else { throw PayloadError.emptyPayload }
        if first == versionEnvelopeByte {
            guard bytes.count >= 2, bytes[1] >= 2 else { throw PayloadError.malformedPayload("malformed version envelope") }
            return Int(bytes[1])
        }
        return 1
    }

    /// The document a payload holds, decompressed within the bound (SPEC §5.4).
    public static func decode(_ bytes: [UInt8], with brotli: BrotliDecompressor, maxDocumentBytes bound: Int = maxDocumentBytes) throws -> DecodedPayload {
        let version = try detectFormatVersion(bytes)
        guard version == formatVersion else { throw PayloadError.unsupportedFormatVersion(version) }
        let raw = try brotli.decompress(bytes, maxOutputBytes: bound)
        // A decompressor that ignored the bound still cannot hand a bomb through.
        guard raw.count <= bound else { throw PayloadError.documentTooLarge(bound: bound) }
        let text = String(decoding: raw, as: UTF8.self)
        return DecodedPayload(text: text, document: Document.parse(text), compressedBytes: bytes.count)
    }
}

#if canImport(Compression)
import Compression

/// Brotli decoding through the Compression framework (iOS 15+, macOS 12+),
/// streamed into a bounded buffer so that a bomb is refused while it
/// decompresses rather than after it has taken the memory.
public struct AppleBrotli: BrotliDecompressor {
    public init() {}

    public func decompress(_ input: [UInt8], maxOutputBytes: Int) throws -> [UInt8] {
        guard !input.isEmpty else { throw PayloadError.emptyPayload }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0, src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_BROTLI) == COMPRESSION_STATUS_OK else {
            throw PayloadError.malformedPayload("the decoder could not be initialised")
        }
        defer { compression_stream_destroy(&stream) }

        let chunk = 64 * 1024
        var output = [UInt8]()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }

        return try input.withUnsafeBufferPointer { src -> [UInt8] in
            stream.src_ptr = src.baseAddress!
            stream.src_size = src.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 {
                    if output.count + produced > maxOutputBytes {
                        throw PayloadError.documentTooLarge(bound: maxOutputBytes)
                    }
                    output.append(contentsOf: UnsafeBufferPointer(start: buffer, count: produced))
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    // More output to come; when the source is spent and the
                    // buffer came back empty the stream is stuck, not done.
                    if produced == 0 && stream.src_size == 0 {
                        throw PayloadError.malformedPayload("the stream ended early")
                    }
                default:
                    throw PayloadError.malformedPayload("not a brotli stream")
                }
            }
        }
    }
}
#endif
