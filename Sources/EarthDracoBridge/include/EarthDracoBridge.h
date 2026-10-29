#import <Foundation/Foundation.h>

/// Installs this package's stateless GLTFKit2 codec plugin exactly once.
/// Draco decoder instances and decoded data are private to each invocation.
FOUNDATION_EXPORT void EarthInstallDracoDecoder(void);

/// Constant-memory admission from the encoded topology, before native decoding.
/// 0 = admitted, 1 = malformed, 2 = unsupported, 3 = topology exceeds working set.
/// This is not a complete bound on every allocation made by Draco.
FOUNDATION_EXPORT NSInteger EarthInspectDracoTopology(NSData *data, NSUInteger offset, NSUInteger length,
                                                     uint64_t maximumPoints, uint64_t maximumFaces);
