# MessEarthKit Guidance

MessEarthKit contains a reusable root Swift package and the existing macOS
example project at `MessEarthKit/MessEarthKit.xcodeproj`.

## Documentation and Audience

- Write for readers encountering MessEarthKit independently. Explain the Swift
  package and macOS example app without assuming knowledge of MESS, MessScene,
  sibling repositories or an enclosing workspace.
- Keep setup, API examples, format contracts, limitations and contributor
  instructions self-contained. Required links and tools must be available from
  a standalone checkout or a documented public dependency.
- Describe capabilities directly. Mention a consuming application only when
  documenting a specific integration; explain any context that reader needs.
- Keep the README focused on getting started. Put detailed current contracts in
  [`docs/TECHNICAL_REFERENCE.md`](docs/TECHNICAL_REFERENCE.md),
  [`docs/APP_STORAGE.md`](docs/APP_STORAGE.md) and
  [`docs/NATIVE_PREPARATION.md`](docs/NATIVE_PREPARATION.md).
- Keep internal implementation plans, task handoffs, machine/account history and
  workspace-specific verification logs in separate maintainer documentation.
  Do not create `docs/internal/` here. When working in an integration workspace,
  use its maintainer documentation index; that checkout must remain optional for
  outside contributors.
- Keep fixture provenance and license notices beside the assets they describe.
  Update current technical contracts when behavior changes; historical plans do
  not override source, tests or the current task's authorization.

## Implementation and Verification

- The package owns geographic transforms, tile/GLB decoding, validation, immutable
  CPU assets, and any explicitly selected output codec. Keep one public library
  module. Do not import SwiftUI or application types or use sibling package paths.
- The example app uses only public package APIs. It owns security-scoped file
  access, presentation, job lifetime, and GPU preview resources. Views consume
  prepared values and send semantic actions to main-actor observable view models.
- Each mutable service has explicit isolation. Package work remains off the main
  actor. Return Sendable values; native decoder objects never escape their worker.
- App storage changes follow
  [`APP_STORAGE.md`](docs/APP_STORAGE.md):
  one injected app-files owner centralizes managed roots, metadata I/O and access
  lifetimes. SDK workers retain bounded artifact/SQLite I/O. Do not add private
  filesystem paths in features, legacy readers, migrations or silent fallbacks.
- Preserve raw source assets and metadata. Reject unsupported/corrupt content
  explicitly; do not supply placeholder geometry or silently change materials.
- Preserve appearance by default. Filtering/lighting approximations require an
  explicit optimized-copy profile; retain that policy through save/export/import.
- Combined standalone delivery uses GLB; USDZ remains optional future work.
  Local coordinates use meters, East +X, Up +Y, North -Z. Use double precision
  through geographic origin subtraction.
- Use cohesive feature files, explicit mutations, descriptive names, and no
  extensions of repository-owned types. Avoid generic provider abstractions and
  public protocols before a real client needs them.
- Keep runtime diagnostics free of source credentials and private paths. Do not
  add direct console or OSLog diagnostics to the example app.
- Preserve existing user work. Do not stage, commit, push, switch branches, or
  change other repositories unless requested for that work.
- Use the repository's [`.swiftformat`](.swiftformat) when linting changed Swift
  files. Formatting is a commit-time concern; do not enable extra rules or run
  broad formatting passes.
- Run focused package tests and the affected macOS example build for code changes.
  Normal tests use local fixtures and no network/API key. Add assertions only for
  distinct format, placement, material, or lifecycle risks. Do not build for docs.
- Keep SwiftPM output outside the checkout. For a standalone checkout, use
  `$HOME/Library/Developer/Xcode/DerivedData/MessEarthKit/swiftpm` as the stable
  scratch path. In an integration workspace, follow its existing build-output
  location and environment overrides. Use normal Xcode DerivedData for the app.
- For substantial integration work, update its separate maintainer handoff
  before implementation or expensive builds. Finish or checkpoint one bounded
  milestone before beginning the next. Standalone contributions require no
  external handoff or private documentation checkout.
