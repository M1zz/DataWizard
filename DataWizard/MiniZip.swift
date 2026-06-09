import Foundation
import Compression

/// A minimal, in-process ZIP archive reader. Reads the central directory,
/// then inflates individual entries. Supports STORE (0) and DEFLATE (8),
/// which is everything an .xlsx uses. No external tools or dependencies,
/// so it works inside the App Sandbox.
enum MiniZip {

    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    enum ZipError: Error, LocalizedError {
        case notZip
        case badEntry
        case inflateFailed
        var errorDescription: String? {
            switch self {
            case .notZip: return "File is not a valid ZIP/XLSX archive."
            case .badEntry: return "A ZIP entry could not be read."
            case .inflateFailed: return "Failed to decompress a ZIP entry."
            }
        }
    }

    /// Read the archive and return a map of entry name -> decompressed bytes.
    static func entries(of url: URL) throws -> [String: Data] {
        let data = try Data(contentsOf: url)
        let dir = try readCentralDirectory(data)
        var out: [String: Data] = [:]
        for e in dir {
            out[e.name] = try extract(entry: e, from: data)
        }
        return out
    }

    // MARK: - central directory

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        // Find End Of Central Directory record signature 0x06054b50, scanning from the tail.
        let eocdSig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let bytes = [UInt8](data)
        guard bytes.count > 22 else { throw ZipError.notZip }

        var eocd = -1
        var i = bytes.count - 22
        let lowerBound = max(0, bytes.count - 22 - 65536) // max comment length
        while i >= lowerBound {
            if bytes[i] == eocdSig[0], bytes[i+1] == eocdSig[1],
               bytes[i+2] == eocdSig[2], bytes[i+3] == eocdSig[3] {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }

        let entryCount = readU16(bytes, eocd + 10)
        var cdOffset = Int(readU32(bytes, eocd + 16))

        var entries: [Entry] = []
        for _ in 0..<entryCount {
            // Central directory file header signature 0x02014b50
            guard readU32(bytes, cdOffset) == 0x02014b50 else { throw ZipError.badEntry }
            let method = readU16(bytes, cdOffset + 10)
            let compSize = Int(readU32(bytes, cdOffset + 20))
            let uncompSize = Int(readU32(bytes, cdOffset + 24))
            let nameLen = Int(readU16(bytes, cdOffset + 28))
            let extraLen = Int(readU16(bytes, cdOffset + 30))
            let commentLen = Int(readU16(bytes, cdOffset + 32))
            let localOffset = Int(readU32(bytes, cdOffset + 42))
            let nameStart = cdOffset + 46
            let nameData = Data(bytes[nameStart..<(nameStart + nameLen)])
            let name = String(decoding: nameData, as: UTF8.self)

            entries.append(Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset
            ))
            cdOffset = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }

    // MARK: - extraction

    private static func extract(entry: Entry, from data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let off = entry.localHeaderOffset
        // Local file header signature 0x04034b50
        guard readU32(bytes, off) == 0x04034b50 else { throw ZipError.badEntry }
        let nameLen = Int(readU16(bytes, off + 26))
        let extraLen = Int(readU16(bytes, off + 28))
        let dataStart = off + 30 + nameLen + extraLen
        let compressed = Data(bytes[dataStart..<(dataStart + entry.compressedSize)])

        if entry.compressionMethod == 0 {
            return compressed // STORE: no compression
        }
        // DEFLATE (raw, no zlib header)
        return try inflate(compressed, expectedSize: entry.uncompressedSize)
    }

    private static func inflate(_ input: Data, expectedSize: Int) throws -> Data {
        // Generous destination buffer; xlsx parts are modest in size.
        let capacity = max(expectedSize, 64 * 1024)
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { (dstPtr: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw ZipError.inflateFailed }
        return dst.prefix(written)
    }

    // MARK: - little-endian readers

    private static func readU16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i+1]) << 8)
    }
    private static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i+1]) << 8) | (UInt32(b[i+2]) << 16) | (UInt32(b[i+3]) << 24)
    }
}
