import EarthDracoBridge
import Foundation

enum EarthDracoAdmission
{
    static func validate(data: Data, json: [String: Any]) throws
    {
        let meshes = json["meshes"] as? [[String: Any]] ?? []
        let views = json["bufferViews"] as? [[String: Any]] ?? []
        let jsonLength = Int(data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self)) })
        let binaryHeader = 20 + jsonLength
        for mesh in meshes
        {
            for primitive in mesh["primitives"] as? [[String: Any]] ?? []
            {
                guard let ext = primitive["extensions"] as? [String: Any], let draco = ext["KHR_draco_mesh_compression"] as? [String: Any] else { continue }
                guard let index = draco["bufferView"] as? Int, views.indices.contains(index),
                      views[index]["buffer"] as? Int ?? 0 == 0,
                      let length = views[index]["byteLength"] as? Int, length > 0,
                      binaryHeader <= data.count - 8
                else { throw EarthImportError.invalidContent("Invalid compressed buffer view.") }
                let offset = views[index]["byteOffset"] as? Int ?? 0
                let words = data.withUnsafeBytes { bytes in (0 ..< 2).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: binaryHeader + $0 * 4, as: UInt32.self)) } }
                guard words[1] == 0x004E4942, Int(words[0]) <= data.count - binaryHeader - 8,
                      offset >= 0, offset <= Int(words[0]), length <= Int(words[0]) - offset
                else { throw EarthImportError.invalidContent("Compressed content exceeds its binary buffer.") }
                try inspect(data: data, offset: binaryHeader + 8 + offset, length: length)
            }
        }
    }

    static func inspect(data: Data, offset: Int = 0, length: Int? = nil, maximumPoints: UInt64 = 2000000, maximumFaces: UInt64 = 2000000) throws
    {
        guard offset >= 0, offset <= data.count else { throw EarthImportError.invalidContent("Invalid compressed offset.") }
        let count = length ?? (data.count - offset)
        guard count >= 0 else { throw EarthImportError.invalidContent("Invalid compressed length.") }
        switch EarthInspectDracoTopology(data, UInt(offset), UInt(count), maximumPoints, maximumFaces)
        {
            case 0: break
            case 2: throw EarthImportError.unsupportedContent("Draco bitstream version, topology method or flags.")
            case 3: throw EarthImportError.limitExceeded("Encoded Draco topology exceeds the native source working set before decoding. Original sources are retained.")
            default: throw EarthImportError.invalidContent("Malformed or excessively nested Draco topology metadata.")
        }
    }
}
