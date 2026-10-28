import Foundation
import GLTFKit2

enum EarthAccessorReader
{
    static func readFloats(
        accessor: GLTFAccessor,
        dimension: GLTFValueDimension,
        componentCount: Int,
        maximumCount: Int
    ) throws -> [Float]
    {
        guard accessor.dimension == dimension, accessor.count > 0, accessor.count <= maximumCount
        else { throw EarthImportError.invalidContent("Vertex accessor shape or count is invalid.") }
        try validateBuffer(accessor: accessor, componentCount: componentCount)
        let packed = GLTFPackedDataForAccessor(accessor)
        let floats = GLTFTransformPackedDataToFloat(packed, accessor)
        guard floats.count == accessor.count * componentCount * MemoryLayout<Float>.size
        else { throw EarthImportError.invalidContent("Vertex accessor payload is truncated.") }
        let values = floats.withUnsafeBytes
        { bytes in
            (0 ..< accessor.count * componentCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        guard values.allSatisfy(\.isFinite)
        else { throw EarthImportError.invalidContent("Vertex attributes contain non-finite values.") }
        return values
    }

    static func readIndices(
        accessor: GLTFAccessor,
        vertexCount: Int,
        maximumCount: Int
    ) throws -> [UInt32]
    {
        guard accessor.dimension == .scalar, !accessor.isNormalized,
              accessor.count > 0, accessor.count <= maximumCount
        else { throw EarthImportError.invalidContent("Triangle index accessor is invalid.") }
        try validateBuffer(accessor: accessor, componentCount: 1)
        let packed = GLTFPackedDataForAccessor(accessor)
        let indices: [UInt32] = try packed.withUnsafeBytes
        { bytes in
            switch accessor.componentType
            {
                case .unsignedByte: (0 ..< accessor.count).map { UInt32(bytes[$0]) }
                case .unsignedShort: (0 ..< accessor.count).map { UInt32(bytes.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self).littleEndian) }
                case .unsignedInt: (0 ..< accessor.count).map { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
                default: throw EarthImportError.invalidContent("Indices must use an unsigned integer component type.")
            }
        }
        guard indices.allSatisfy({ $0 < vertexCount })
        else { throw EarthImportError.invalidContent("Triangle index is outside the vertex array.") }
        return indices
    }

    private static func validateBuffer(
        accessor: GLTFAccessor,
        componentCount: Int
    ) throws
    {
        guard accessor.sparse == nil
        else { throw EarthImportError.unsupportedContent("Sparse accessors are not supported by the initial adapter.") }
        guard let view = accessor.bufferView, let data = view.buffer.data,
              accessor.offset >= 0, view.offset >= 0, view.length >= 0,
              view.offset <= data.count, view.length <= data.count - view.offset
        else { throw EarthImportError.invalidContent("Accessor buffer range is invalid.") }
        let componentSize: Int
        switch accessor.componentType
        {
            case .byte, .unsignedByte: componentSize = 1
            case .short, .unsignedShort: componentSize = 2
            case .unsignedInt, .float: componentSize = 4
            default: throw EarthImportError.invalidContent("Unknown accessor component type.")
        }
        let elementSize = componentCount * componentSize
        let stride = view.stride == 0 ? elementSize : view.stride
        guard stride >= elementSize, accessor.offset <= view.length,
              elementSize <= view.length - accessor.offset,
              accessor.count - 1 <= (view.length - accessor.offset - elementSize) / stride
        else { throw EarthImportError.invalidContent("Accessor exceeds its buffer view.") }
    }
}
