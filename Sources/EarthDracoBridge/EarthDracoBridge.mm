#import "EarthDracoBridge.h"
#import <GLTFKit2/GLTFKit2.h>
#include <draco/compression/decode.h>
#include <cstring>

@interface MessEarthDracoDecoder : NSObject <GLTFDracoMeshDecompressor>
@end

@implementation MessEarthDracoDecoder

+ (GLTFPrimitive *)newPrimitiveForCompressedBufferView:(GLTFBufferView *)view
                                        attributeMap:(NSDictionary<NSString *, NSNumber *> *)attributeMap
{
    NSData *source = view.buffer.data;
    if (source == nil || view.offset < 0 || view.length <= 0 ||
        static_cast<NSUInteger>(view.offset) > source.length ||
        static_cast<NSUInteger>(view.length) > source.length - view.offset ||
        attributeMap.count == 0 || attributeMap.count > 16)
    {
        return nil;
    }
    draco::DecoderBuffer buffer;
    buffer.Init(static_cast<const char *>(source.bytes) + view.offset, view.length);
    draco::Decoder decoder;
    auto result = decoder.DecodeMeshFromBuffer(&buffer);
    if (!result.ok()) { return nil; }
    auto mesh = std::move(result).value();
    // Fixed codec ceiling; the Swift importer also enforces its caller's smaller budget.
    if (mesh == nullptr || mesh->num_points() == 0 || mesh->num_points() > 2000000 ||
        mesh->num_faces() == 0 || mesh->num_faces() > 2000000)
    {
        return nil;
    }
    NSMutableArray<GLTFAttribute *> *attributes = [NSMutableArray array];
    for (NSString *name in attributeMap)
    {
        NSNumber *identifier = attributeMap[name];
        if (identifier.longLongValue < 0 || identifier.unsignedLongLongValue > UINT32_MAX) { return nil; }
        const draco::PointAttribute *attribute = mesh->GetAttributeByUniqueId(identifier.unsignedIntValue);
        if (attribute == nullptr || attribute->num_components() < 1 || attribute->num_components() > 4) { return nil; }
        GLTFComponentType type;
        switch (attribute->data_type())
        {
            case draco::DT_INT8: type = GLTFComponentTypeByte; break;
            case draco::DT_UINT8: type = GLTFComponentTypeUnsignedByte; break;
            case draco::DT_INT16: type = GLTFComponentTypeShort; break;
            case draco::DT_UINT16: type = GLTFComponentTypeUnsignedShort; break;
            case draco::DT_UINT32: type = GLTFComponentTypeUnsignedInt; break;
            case draco::DT_FLOAT32: type = GLTFComponentTypeFloat; break;
            default: return nil;
        }
        const size_t elementSize = draco::DataTypeLength(attribute->data_type()) * attribute->num_components();
        NSMutableData *values = [NSMutableData dataWithLength:mesh->num_points() * elementSize];
        for (draco::PointIndex index(0); index < mesh->num_points(); ++index)
        {
            const auto mapped = attribute->mapped_index(index);
            if (mapped.value() >= attribute->size()) { return nil; }
            attribute->GetValue(mapped, static_cast<char *>(values.mutableBytes) + index.value() * elementSize);
        }
        GLTFBuffer *valueBuffer = [[GLTFBuffer alloc] initWithData:values];
        GLTFBufferView *valueView = [[GLTFBufferView alloc] initWithBuffer:valueBuffer length:values.length offset:0 stride:0];
        GLTFAccessor *accessor = [[GLTFAccessor alloc] initWithBufferView:valueView offset:0 componentType:type
            dimension:static_cast<GLTFValueDimension>(attribute->num_components()) count:mesh->num_points()
            normalized:attribute->normalized()];
        [attributes addObject:[[GLTFAttribute alloc] initWithName:name accessor:accessor]];
    }
    const size_t indexCount = mesh->num_faces() * 3;
    NSMutableData *indexData = [NSMutableData dataWithLength:indexCount * sizeof(uint32_t)];
    uint32_t *indices = static_cast<uint32_t *>(indexData.mutableBytes);
    for (draco::FaceIndex faceIndex(0); faceIndex < mesh->num_faces(); ++faceIndex)
    {
        const auto &face = mesh->face(faceIndex);
        for (int corner = 0; corner < 3; ++corner)
        {
            if (face[corner].value() >= mesh->num_points()) { return nil; }
            indices[faceIndex.value() * 3 + corner] = face[corner].value();
        }
    }
    GLTFBuffer *indexBuffer = [[GLTFBuffer alloc] initWithData:indexData];
    GLTFBufferView *indexView = [[GLTFBufferView alloc] initWithBuffer:indexBuffer length:indexData.length offset:0 stride:0];
    GLTFAccessor *indexAccessor = [[GLTFAccessor alloc] initWithBufferView:indexView offset:0
        componentType:GLTFComponentTypeUnsignedInt dimension:GLTFValueDimensionScalar count:indexCount normalized:NO];
    return [[GLTFPrimitive alloc] initWithPrimitiveType:GLTFPrimitiveTypeTriangles attributes:attributes indices:indexAccessor];
}
@end

void EarthInstallDracoDecoder(void)
{
    // GLTFKit2 exposes codec registration as process-wide configuration. Installation
    // is immutable after dispatch_once; all actual decoder state remains per call.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        GLTFAsset.dracoDecompressorClassName = NSStringFromClass([MessEarthDracoDecoder class]);
    });
}
