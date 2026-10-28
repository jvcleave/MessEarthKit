#import <Foundation/Foundation.h>

/// Installs this package's stateless GLTFKit2 codec plugin exactly once.
/// Draco decoder instances and decoded data are private to each invocation.
FOUNDATION_EXPORT void EarthInstallDracoDecoder(void);
