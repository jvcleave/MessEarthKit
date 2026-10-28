# MessEarthKit Guidance

MessEarthKit contains a reusable root Swift package and the existing macOS
example project at `MessEarthKit/MessEarthKit.xcodeproj`.

- The package owns geographic transforms, tile/GLB decoding, validation, immutable
  CPU assets, and any explicitly selected output codec. Keep one public library
  module. Do not import SwiftUI or application types or use sibling package paths.
- The example app uses only public package APIs. It owns security-scoped file
  access, presentation, job lifetime, and GPU preview resources. Views consume
  prepared values and send semantic actions to main-actor observable view models.
- Each mutable service has explicit isolation. Package work remains off the main
  actor. Return Sendable values; native decoder objects never escape their worker.
- Preserve raw source assets and metadata. Reject unsupported/corrupt content
  explicitly; do not supply placeholder geometry or silently change materials.
- GLB versus USDZ delivery remains deferred. Local coordinates use meters, East
  +X, Up +Y, North -Z. Use double precision through geographic origin subtraction.
- Use cohesive feature files, explicit mutations, descriptive names, and no
  extensions of repository-owned types. Avoid generic provider abstractions and
  public protocols before a real client needs them.
- Keep runtime diagnostics free of source credentials and private paths. Do not
  add direct console or OSLog diagnostics to the example app.
- Preserve existing user work. Do not stage, commit, push, switch branches, or
  change the super-repository unless requested for that work.
- Follow the parent workspace's `.swiftformat` explicitly when linting changed
  Swift files. Formatting is a commit-time concern; do not enable extra rules.
- Run focused package tests and the affected macOS example build for code changes.
  Normal tests use local fixtures and no network/API key. Add assertions only for
  distinct format, placement, material, or lifecycle risks. Do not build for docs.
- SwiftPM commands must use
  `${MESS_BUILD_CACHE_ROOT:-$HOME/Library/Developer/Xcode/DerivedData/MESS-LocalBuilds}/MessEarthKit/swiftpm`
  as their stable scratch path. Use normal Xcode DerivedData for the example app.
- Before substantial work or builds, update
  `docs/internal/handoffs/mess-earth-kit.md`; finish or checkpoint one bounded
  milestone before beginning the next.
