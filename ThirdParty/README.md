# Preserved native dependencies

MessEarthKit builds against the local frameworks in `Artifacts/`. Builds do not
contact GLTFKit2, DracoSwift or their release servers. The frameworks retain the
existing decoder versions and their universal macOS arm64/x86_64 slices; other
platform slices are omitted because MessEarthKit supports macOS.

`Sources/` holds compressed implementation snapshots for recovery and inspection.
These are source archives stored directly in this repository, without submodules
or Git LFS. Normal builds use the preserved frameworks. Rebuilding the frameworks
is an explicit maintenance operation.

| Component | Version | Preserved source | License notices |
| --- | --- | --- | --- |
| GLTFKit2 | 0.5.15 | [Implementation and Xcode project](Sources/GLTFKit2-0.5.15.tar.gz) | [MIT](Licenses/GLTFKit2/LICENSE) |
| DracoSwift | 1.5.7 | [Original package wrapper](Sources/DracoSwift-1.5.7.tar.gz) | [Apache 2.0](Licenses/DracoSwift/LICENSE) |
| Google Draco | 1.5.7 | [Native codec implementation](Sources/draco-1.5.7.tar.gz) | [Apache 2.0 and authors](Licenses/Draco/) |
| KTX-Software | 4.2.1 | [libktx and bundled native codecs](Sources/KTX-Software-4.2.1.tar.gz) | [Notices](Licenses/KTX-Software/NOTICE.md), [license texts](Licenses/KTX-Software/LICENSES/), [Ericsson terms](Licenses/KTX-Software/ETCDEC-LICENSE.txt) |
| cgltf | GLTFKit2's embedded revision | `GLTFKit2/deps/cgltf/` in the GLTFKit2 archive | [MIT](Licenses/cgltf/LICENSE) |

[PROVENANCE.json](PROVENANCE.json) records immutable upstream revisions, the
original GLTFKit2 release checksum and the exact source selections. Selected
source files are unmodified. Examples, large test datasets, web demos and unused
platform binaries are excluded. Optional Draco transcoder/test submodules are
not needed for the native codec and are excluded. KTX's Basis Universal, ASTC,
zstd and other native sources and their notices remain in its archive.

The archived package manifests describe upstream packaging; MessEarthKit does
not resolve them. The root `Package.swift` references only local binary targets.

## Verify the preserved files

From the repository root:

```sh
shasum -a 256 -c ThirdParty/SHA256SUMS
swift package show-dependencies
```

The checksum inventory covers artifacts, source archives, notices and provenance.
The dependency listing contains only MessEarthKit. GLTFKit2's framework, debug
symbols, headers and symlinks, and Draco's library and headers, retain upstream
contents. Only the outer XCFramework plists are reduced to macOS entries.

## Rebuild from the archived sources

Use Xcode and CMake 3.30 or newer. These commands run from the repository root
and require no dependency downloads. Choose a fresh recovery source directory;
keep compiler output outside the checkout. An enclosing workspace may select its
existing package-specific build-cache location instead.

```sh
earth_vendor_root="$HOME/Library/Developer/Xcode/DerivedData/MessEarthKit/vendor-recovery"
mkdir -p "$earth_vendor_root/sources"
tar -xzf ThirdParty/Sources/GLTFKit2-0.5.15.tar.gz -C "$earth_vendor_root/sources"
tar -xzf ThirdParty/Sources/draco-1.5.7.tar.gz -C "$earth_vendor_root/sources"
tar -xzf ThirdParty/Sources/KTX-Software-4.2.1.tar.gz -C "$earth_vendor_root/sources"

cmake -S "$earth_vendor_root/sources/draco-1.5.7" \
  -B "$earth_vendor_root/draco" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.6 \
  -DDRACO_TESTS=OFF -DDRACO_TRANSCODER_SUPPORTED=OFF \
  -DDRACO_UNITY_PLUGIN=OFF -DDRACO_MAYA_PLUGIN=OFF
cmake --build "$earth_vendor_root/draco" --target draco_static --parallel 4

cmake -S "$earth_vendor_root/sources/KTX-Software-4.2.1" \
  -B "$earth_vendor_root/ktx" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  '-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.6 \
  '-DCMAKE_CXX_FLAGS=-Wno-error=overriding-option -Wno-error=nontrivial-memcall' \
  -DKTX_FEATURE_STATIC_LIBRARY=ON -DKTX_FEATURE_TESTS=OFF \
  -DKTX_FEATURE_TOOLS=OFF -DKTX_FEATURE_DOC=OFF -DKTX_FEATURE_LOADTEST_APPS=OFF
cmake --build "$earth_vendor_root/ktx" --target ktx --parallel 4

xcodebuild -create-xcframework \
  -library "$earth_vendor_root/ktx/libktx.a" \
  -headers "$earth_vendor_root/sources/KTX-Software-4.2.1/include" \
  -output "$earth_vendor_root/sources/GLTFKit2-0.5.15/GLTFKit2/deps/libktx/ktx.xcframework"
xcodebuild \
  -project "$earth_vendor_root/sources/GLTFKit2-0.5.15/GLTFKit2/GLTFKit2.xcodeproj" \
  -scheme GLTFKit2 -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$earth_vendor_root/GLTFKit2" \
  MACOSX_DEPLOYMENT_TARGET=15.6 CODE_SIGNING_ALLOWED=NO build
```

The warning flags keep two newer Clang diagnostics from becoming fatal in the
unchanged KTX source. `CMAKE_POLICY_VERSION_MINIMUM` supports newer CMake releases;
older CMake may report that the variable is unused. Without Git history, KTX's
version script reports `0.0.0-noversion`; its actual source revision is recorded
in provenance. This does not change the selected implementation.

The outputs are `draco/libdraco.a`, `ktx/libktx.a` and
`GLTFKit2/Build/Products/Release/GLTFKit2.framework` beneath the recovery root.
Draco's generated `draco/draco_features.h` in its build directory belongs with
the source `src/draco/` headers when packaging a replacement library.

These commands preserve the checked-in artifacts. A replacement framework is a
dependency change: package its macOS slice with `xcodebuild -create-xcframework`,
review architecture/deployment settings, run the native decode/export tests and
example build, then update provenance and checksums. Rebuilt binaries need not
match the original release bytes because compiler versions and build settings
can differ.
