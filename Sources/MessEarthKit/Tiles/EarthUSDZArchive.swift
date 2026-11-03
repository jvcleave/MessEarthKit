import Foundation
import zlib

/// USDZ uses stored ZIP members whose payloads start at 64-byte boundaries.
/// Files are CRC-checked and streamed; the archive is never held in memory.
final class EarthUSDZArchive
{
    private struct Entry { let name: Data; let crc: UInt32; let size: UInt32; let offset: UInt32 }
    private let output: FileHandle
    private var entries: [Entry] = []

    init(fileURL: URL) throws
    {
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else { throw EarthUSDZExportError.storage }
        output = try FileHandle(forWritingTo: fileURL)
    }

    deinit { try? output.close() }

    func append(_ fileURL: URL, name: String) throws
    {
        try Task.checkCancellation()
        guard entries.count < Int(UInt16.max) - 1, !name.isEmpty, name.utf8.count <= Int(UInt16.max),
              name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !name.contains("\\"), !entries.contains(where: { $0.name == Data(name.utf8) })
        else { throw EarthUSDZExportError.requirements(["USDZ member names or entry count exceed the delivery limit."]) }
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        guard length < UInt32.max else { throw EarthUSDZExportError.requirements(["A USDZ member exceeds 4 GiB."]) }
        try input.seek(toOffset: 0)
        var checksum: uLong = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty
        {
            try Task.checkCancellation()
            checksum = data.withUnsafeBytes { crc32(checksum, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
        }
        let offset = try output.offset()
        guard offset < UInt32.max else { throw EarthUSDZExportError.requirements(["The USDZ exceeds the 4 GiB archive limit."]) }
        let nameData = Data(name.utf8)
        let padding = Int((64 - (offset + 30 + UInt64(nameData.count) + 4) % 64) % 64)
        var header = Data()
        Self.word(UInt32(0x04034B50), into: &header)
        for value: UInt16 in [20, 0, 0, 0, 33] { Self.word(value, into: &header) }
        for value in [UInt32(checksum), UInt32(length), UInt32(length)] { Self.word(value, into: &header) }
        Self.word(UInt16(nameData.count), into: &header); Self.word(UInt16(padding + 4), into: &header)
        header.append(nameData)
        Self.word(UInt16(0x1986), into: &header); Self.word(UInt16(padding), into: &header)
        header.append(Data(repeating: 0, count: padding))
        try output.write(contentsOf: header)
        try input.seek(toOffset: 0)
        var copied: UInt64 = 0
        var copiedCRC: uLong = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty
        {
            try Task.checkCancellation()
            copied += UInt64(data.count)
            copiedCRC = data.withUnsafeBytes { crc32(copiedCRC, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
            try output.write(contentsOf: data)
        }
        guard copied == length, copiedCRC == checksum else { throw EarthUSDZExportError.sourceChanged }
        entries.append(Entry(name: nameData, crc: UInt32(checksum), size: UInt32(length), offset: UInt32(offset)))
    }

    func finish() throws -> Int
    {
        try Task.checkCancellation()
        let start = try output.offset()
        for entry in entries
        {
            var header = Data()
            Self.word(UInt32(0x02014B50), into: &header)
            for value: UInt16 in [20, 20, 0, 0, 0, 33] { Self.word(value, into: &header) }
            for value in [entry.crc, entry.size, entry.size] { Self.word(value, into: &header) }
            for value: UInt16 in [UInt16(entry.name.count), 0, 0, 0, 0] { Self.word(value, into: &header) }
            Self.word(UInt32(0), into: &header); Self.word(entry.offset, into: &header)
            header.append(entry.name)
            try output.write(contentsOf: header)
        }
        let end = try output.offset()
        guard end <= UInt64(UInt32.max) - 22 else { throw EarthUSDZExportError.requirements(["The USDZ exceeds the 4 GiB archive limit."]) }
        var footer = Data()
        Self.word(UInt32(0x06054B50), into: &footer)
        for value: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { Self.word(value, into: &footer) }
        Self.word(UInt32(end - start), into: &footer); Self.word(UInt32(start), into: &footer)
        Self.word(UInt16(0), into: &footer)
        try output.write(contentsOf: footer)
        try output.synchronize()
        try output.close()
        return Int(end) + footer.count
    }

    static func rootText(_ fileURL: URL) throws -> String?
    {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        guard let header = try input.read(upToCount: 30), header.count == 30,
              header.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }) == 0x04034B50
        else { throw EarthUSDZExportError.storage }
        func u16(_ offset: Int) -> UInt16 { header.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) } }
        func u32(_ offset: Int) -> UInt32 { header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
        guard u16(6) == 0, u16(8) == 0, u32(18) == u32(22), u32(22) <= 8 * 1024 * 1024 else { return nil }
        let name = try input.read(upToCount: Int(u16(26))) ?? Data()
        guard String(data: name, encoding: .utf8)?.hasSuffix(".usda") == true else { return nil }
        try input.seek(toOffset: UInt64(30 + Int(u16(26)) + Int(u16(28))))
        let data = try input.read(upToCount: Int(u32(22))) ?? Data()
        let checksum = data.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
        guard data.count == Int(u32(22)), UInt32(checksum) == u32(14) else { throw EarthUSDZExportError.storage }
        return String(data: data, encoding: .utf8)
    }

    private static func word<Value: FixedWidthInteger>(_ value: Value, into data: inout Data)
    { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
}
