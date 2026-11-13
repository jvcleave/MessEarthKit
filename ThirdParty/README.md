# Native dependencies

[MessGLBKit 0.1.0](https://github.com/jvcleave/MessGLBKit/tree/0.1.0) supplies the
macOS GLTFKit2 and Draco binaries, notices and recovery sources. SwiftPM fetches
the pinned package checkout. The codec binaries come with that checkout.

MessEarthKit compiles the meshoptimizer 1.3 subset in
[`Sources/EarthMeshOptimizer/vendor/`](../Sources/EarthMeshOptimizer/vendor)
for remapping, cache/fetch ordering and simplification. The corresponding source
archive and license are under [Sources](Sources) and [Licenses](Licenses).
[PROVENANCE.json](PROVENANCE.json) records the pinned upstream revision and the
selection. The MIT notice also ships in the Swift package resource bundle.

Run `shasum -a 256 -c ThirdParty/SHA256SUMS` from the repository root to check
the preserved meshoptimizer files.
