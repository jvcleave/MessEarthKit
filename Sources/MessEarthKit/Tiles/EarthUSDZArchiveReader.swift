import Foundation
import zlib

/// Reads the stored, aligned ZIP32 contract produced by EarthUSDZArchive.
/// Members never become filesystem paths and no archive content is extracted.
final class EarthUSDZArchiveReader
{
    struct Member { let offset: UInt64; let count: Int; let crc: UInt32; let localOffset: UInt32 }
    let members: [String: Member]
    let byteCount: Int
    private let input: FileHandle

    init(_ url: URL, maximumBytes: Int) throws
    {
        input = try FileHandle(forReadingFrom: url)
        let length = try input.seekToEnd()
        guard length <= maximumBytes, length >= 22 else { throw EarthImportError.limitExceeded("Exported USDZ source bytes.") }
        byteCount = Int(length)
        try input.seek(toOffset: length - 22)
        let footer = try Self.read(input, count: 22)
        guard Self.u32(footer, 0) == 0x06054B50, Self.u16(footer, 4) == 0, Self.u16(footer, 6) == 0,
              Self.u16(footer, 8) == Self.u16(footer, 10), Self.u16(footer, 20) == 0
        else { throw Self.invalid() }
        let central = UInt64(Self.u32(footer, 16))
        guard central + UInt64(Self.u32(footer, 12)) == length - 22 else { throw Self.invalid() }
        var found: [String: Member] = [:]
        var offset: UInt64 = 0
        while offset < central
        {
            try Task.checkCancellation()
            guard found.count < 65534, central - offset >= 30 else { throw Self.invalid() }
            try input.seek(toOffset: offset)
            let header = try Self.read(input, count: 30)
            guard Self.u32(header, 0) == 0x04034B50, Self.u16(header, 6) == 0, Self.u16(header, 8) == 0,
                  Self.u32(header, 18) == Self.u32(header, 22)
            else { throw Self.invalid() }
            let nameData = try Self.read(input, count: Int(Self.u16(header, 26)))
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty, !name.contains("\\"),
                  name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  found[name] == nil
            else { throw Self.invalid() }
            let start = offset + 30 + UInt64(nameData.count) + UInt64(Self.u16(header, 28))
            let count = Int(Self.u32(header, 18))
            guard start.isMultiple(of: 64), start <= central, UInt64(count) <= central - start else { throw Self.invalid() }
            found[name] = Member(offset: start, count: count, crc: Self.u32(header, 14), localOffset: UInt32(offset))
            offset = start + UInt64(count)
        }
        guard found.count == Int(Self.u16(footer, 10)), found["scene.usda"]?.localOffset == 0 else { throw Self.invalid() }
        try input.seek(toOffset: central)
        var centralNames = Set<String>()
        for _ in 0 ..< found.count
        {
            let header = try Self.read(input, count: 46)
            guard Self.u32(header, 0) == 0x02014B50, Self.u16(header, 8) == 0, Self.u16(header, 10) == 0,
                  Self.u16(header, 34) == 0
            else { throw Self.invalid() }
            let nameData = try Self.read(input, count: Int(Self.u16(header, 28)))
            guard let name = String(data: nameData, encoding: .utf8), let member = found[name],
                  centralNames.insert(name).inserted, Self.u32(header, 16) == member.crc,
                  Self.u32(header, 20) == member.count, Self.u32(header, 24) == member.count,
                  Self.u32(header, 42) == member.localOffset
            else { throw Self.invalid() }
            let skip = UInt64(Self.u16(header, 30)) + UInt64(Self.u16(header, 32))
            try input.seek(toOffset: input.offset() + skip)
        }
        guard try input.offset() == length - 22 else { throw Self.invalid() }
        members = found
    }

    deinit { try? input.close() }

    func data(_ name: String, maximumBytes: Int) throws -> Data
    {
        guard let member = members[name] else { throw Self.invalid() }
        guard member.count <= maximumBytes else { throw EarthImportError.limitExceeded("Exported USDZ member bytes.") }
        try input.seek(toOffset: member.offset)
        var result = Data()
        result.reserveCapacity(member.count)
        var checksum: uLong = 0
        while result.count < member.count
        {
            try Task.checkCancellation()
            let data = try Self.read(input, count: min(1024 * 1024, member.count - result.count))
            checksum = data.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
            result.append(data)
        }
        guard UInt32(checksum) == member.crc else { throw Self.invalid() }
        return result
    }

    func originalBytes() throws -> Data
    {
        try input.seek(toOffset: 0)
        return try Self.read(input, count: byteCount)
    }

    private static func read(_ handle: FileHandle, count: Int) throws -> Data
    {
        var result = Data()
        while result.count < count
        {
            try Task.checkCancellation()
            let next = try handle.read(upToCount: min(1024 * 1024, count - result.count)) ?? Data()
            guard !next.isEmpty else { throw invalid() }
            result.append(next)
        }
        return result
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16
    { data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) } }
    private static func u32(_ data: Data, _ offset: Int) -> UInt32
    { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
    static func invalid() -> EarthImportError { .invalidContent("The file is not a supported EarthKit USDZ export.") }
}
