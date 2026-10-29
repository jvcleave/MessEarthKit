# MessEarth app storage and file-access policy

Status: app files, schema-3 project/schema-1 settings stores and the MapKit-confirmed
download/preparation flow and whole-region preview are implemented. Location/model controls and direct map editing are implemented; Export UI remains.
Updated: 2026-10-29 (America/New_York).
Scope: MessEarthKitExample app-owned storage and authorization.

## Basis and ownership

Adapt MessScene's `MessSceneAppFiles` / `MessSceneFileAccess` pattern and
[storage policy](../../../../MessSceneApp/MessSceneApp/docs/internal/architecture/MESS_SCENE_STORAGE.md).
The reference implementation is
`MessSceneApp/MessSceneApp/Packages/MessSceneKit/Sources/MessSceneEditor/App/Storage/MessSceneAppFiles.swift`
relative to the MESS root. Inspect its current source before implementation.
Adapt the ownership and isolation rules; do not import MessScene types or copy
its domain-specific folders, custom-icon code or complete API.

Create one app-owned `EarthAppFiles` instance at composition and inject it into
the focused stores/services that need it. Its responsibilities are root selection,
managed names/URLs, small metadata I/O, directory operations and file-access
authorization. Project schemas, request state, preparation profiles and job
scheduling remain with their feature owners.

- `EarthAppFiles` is the sole app boundary for `FileManager`, metadata reads/
  writes and managed directory construction. Views and feature view models do
  not perform filesystem operations, choose private storage roots or start their
  own security scopes. Stores encode/validate values and request file operations.
- Use an explicit injected root for verification. The normal app resolves one
  namespaced Documents root; unavailable/inaccessible storage is an explicit
  error, not a reason to use another directory silently.
- Keep I/O off `MainActor`, with serialized app metadata mutations on an owning
  actor or utility queue. Return immutable Sendable values. Centralization must
  not block the main actor or serialize network/decode jobs behind metadata I/O.
- A narrow internal interface may express real store requirements. Do not add
  a new public SDK filesystem protocol or shared package for hypothetical hosts.

## Managed structure

New app-managed state uses the following structure:

```text
Documents/MessEarthKit/
  appSettings.json
  stats/
    RequestUsage.sqlite
  projects/
    <project UUID>/
      project.json
      sources/
        <capture UUID>/          # SDK source archive, including its journal
      prepared/
        <preparation UUID>/      # SDK prepared catalog and model parts
      output/
        <export UUID>/           # one exported GLB or aligned model folder
```

The app-files owner defines every name and derives paths from validated IDs.
Project records use relative references within their project directory; display
names and addresses are metadata, not filenames or identifiers. SDK-internal
artifact filenames and staging layouts remain owned by the SDK.

Folder creation must respect each SDK API's new-destination contract: create
parents as needed, but do not precreate an archive, prepared collection or model-
folder destination that the SDK requires to be absent. Failed/cancelled work may
remove only its own unpublished staging files; never another capture or output.
Explicit confirmed deletion below is a separate user action.

API keys stay in Keychain or active memory and are not stored in project/settings
JSON. Application preferences use one settings owner and `appSettings.json` through
`EarthAppFiles`; views/stores do not create independent preference files or access
`UserDefaults`. The request ledger is app-wide, independent of any project.

## Confirmed deletion

The user requested project/variant trash buttons and confirmations. Native
destructive confirmation alerts are allowed for these actions. A confirmed
project deletion moves its entire UUID folder to macOS Trash, including all
captures/preparations/outputs. Other projects, settings, Keychain and the global
request ledger are outside its scope. This also permits deleting a listed project
whose metadata is unreadable; no schema rewrite is needed to remove its folder.

Variant and location deletion serialize with project metadata writes. A location
deletion detaches every nested variant in one operation and uses one Trash bundle.
Variant deletion updates internal selection without replacing its area or title. The
last variant deletion clears active capture selection when none remain, but the
location stays frozen. Deleting a location preserves other areas and map search.
Only the removed variants' UUID sources and
recorded preparations are removed; a preparation still referenced by another
variant is retained. EarthAppFiles validates managed paths and rejects symlinks,
commits metadata first, stages those directories in a unique Deleted-Captures
folder within the project, then moves that bundle to Trash. Normal failures roll
back paths and original metadata. An interrupted operation can leave a retained
deletion folder; partial rollback reports an explicit error. There is no automatic
adoption, orphan scan or silent cleanup. Sources are never moved before their
live metadata references have been detached.

Delete controls are disabled during active work and while the target project is
saving. Project deletion waits for queued saves; the store blocks subsequent
writes to prevent resurrection.
Workers and GPU scenes must be settled/released before deletion. Once confirmed
file mutation starts, cancellation is unavailable. Verification injects a Trash
operation confined to temporary fixtures; it never deletes actual user projects
or fills the user's Trash.

## SDK boundary and bounded files

App file policy and SDK artifact I/O have different responsibilities:

- The app-files owner supplies the chosen, validated destination/source roots
  and any required authorization lifetime to SDK calls. Download, preparation
  and export services receive those roots; they do not independently query
  Documents, Application Support or temporary storage.
- SDK acquisition/preparation/export workers retain their confined file access,
  SQLite handles, streaming transfers, incremental hashes, atomic publication
  and resource bounds. They cannot depend on the concrete application owner.
- Do not route large GLBs, textures or SQLite files through a generic whole-file
  `readData` / `writeData` interface to imitate the reference pattern. Centralize
  app policy while preserving the SDK's bounded file-backed mechanisms.
- Project metadata operations remain small and atomic. Do not combine metadata
  and source files into one giant JSON document or copy payloads on view updates.

The project capture service initializes a paused source archive through
`EarthSourceArchive.create` and records its UUID/request before entering transport.
Only explicit Project Details Download/Resume actions enter Google acquisition. Interrupted
jobs reopen that recorded journal without inferred paths; preparation later commits
its selected collection reference. UI navigation never owns these job/file lifetimes.

## Confinement and authorization

- Resolve managed paths below the configured root using checked components;
  reject traversal, escaping references, symlinks that leave the permitted tree,
  mismatched project/artifact IDs and source/output overlap. Do not treat a
  string-prefix check alone as proof of containment.
- Internal project sources are immutable once acquisition completes. Derived
  data and exports use new destinations and never overwrite their inputs.
- External access requires an explicit app-owned authorization lease for the
  requested operation. Retain it through queued reads, catalog paging, preview,
  preparation and export; navigation does not release access still in use.
- UI routes request semantic operations, including reveal/export, instead of
  coordinating file access themselves. File-picker presentation remains subject
  to the project's no-overlay navigation rule.
- Report typed access, storage, corruption and unsupported-format errors. Runtime
  diagnostics do not expose credentials, source URLs or private absolute paths.

## Current-format-only policy

The user explicitly excluded legacy code and fallbacks from this work.

- Read/write only the current app-owned project/settings schemas. Reject unknown
  versions and missing required fields; no legacy readers, key aliases, inferred
  substitutions, compatibility branches or automatic migrations.
- Do not scan older Application Support archives to synthesize recovered projects,
  reuse an old ledger automatically, or search alternative roots after failure.
- A fresh root can explicitly initialize a new empty library/settings/ledger.
  A corrupt existing current file must not be replaced with fresh defaults or a
  trustworthy-looking empty library/count. Preserve its file and report failure.
- Pause/resume, explicit retry and crash-state validation for the current project
  format remain normal job behavior. They are not legacy recovery paths.
- Storage initialization does not authorize deleting or moving existing user
  files. Only explicit confirmed deletion above removes a registered project or
  variant. New-format operation requires no migration or compatibility work.

## Implementation and verification

Implement this boundary as the first milestone of the
[project workflow plan](../plans/PROJECT_WORKFLOW_REORGANIZATION_PLAN.md), before
project persistence and navigation. Route the current app-side path, metadata and
authorization call sites through it; add no old-root bridge or fallback to the
former workspace UI.

The implemented owner is `Storage/EarthAppFiles.swift` in the example app. The
project library supplies persistent IDs from schema-3 `project.json` records.
There is no newest-archive startup scan.
The old app inspection/recovery/calibration route has been removed. SDK/public
capture, preparation and export contracts are unchanged.

`EarthProjectStore` owns the independent project title/map-search state, locations,
nested detail variants, editing location ID and active capture ID. Each location
has its own center/Width/Height, a required nullable frozenAt and a required nullable
pending variant detail. The first source registration freezes area and records
variant identity atomically before transport. Freeze survives pause/failure and
last-variant deletion. Copies get fresh IDs with no frozen state or artifacts.
Search, editor and workflow selection serialize independently. A frozen area's
geometry is immutable; validation requires all nested variants to reference that
location ID and identical geometry. A source activation for Preview/Resume validates
it first while preserving search, editing location and pending variant settings.
Show on Map changes editor focus explicitly, without rewriting any area.
`EarthMapAreaEditing` owns transient gesture snapshots with location ID, original
area and live preview. It performs no I/O. Gesture release checks identity, original
area and frozen state before the project owner queues one normal atomic editor
save. Escape/navigation/gesture cancellation discard the preview. Active map edits
block acquisition, preparation, refresh and deletion. Camera browsing remains
separate, and map graphics are inline controls rather than modal presentations.
Journal-only card status reads leave selection and metadata untouched; an
unavailable inactive source reports its own card error. Activation cannot rewrite
another variant. Typed UUIDs derive relative artifact references. Current nullable fields must be present as null or a value. Loading checks
schema/folder ID, journal request and recorded preparation profile/source matches.
Corrupt projects appear as explicit per-file library errors without being reset.
`EarthAppSettingsStore` owns schema-1 `appSettings.json` with the usage-details
disclosure preference. Only a missing settings file initializes fresh defaults.
Credential loading and explicit Keychain saving remain in the credential owner.
App-owned library/settings and per-project workflows survive navigation; hidden
preview scenes release displayed GPU resources without cancelling workers.
`EarthRegionPreviewService` retains a read lease for both bounded import/upload
passes and verifies the recorded capture/preparation before returning a result.
Published scenes contain GPU resources/shader values and no source payloads, so
file access ends with worker completion. Hidden completion is discarded.
Explicit project/preview refresh waits for pending draft writes, reopens only the
saved current references and updates the retained owner before retrying. It never
starts network acquisition, adopts another folder or resets invalid metadata.

Verification should exercise an injected root, current metadata save/reopen,
explicit corrupt/version rejection, confinement and authorization/job lifetime.
Reuse existing SDK acquisition/preparation/export tests for large-file behavior;
do not create an app-files test matrix that repeats their implementation. Build
the affected macOS example after code changes. Twenty-one headless tests compile the
actual app storage/workflow/renderer sources through the internal `MessEarthKitAppFilesTests` target;
the tests are excluded from the Xcode app target. They cover metadata preservation
on rejected writes/new-destination publication, confinement/symlink/SQLite sidecar
failures, external read/export boundaries, strict current schemas/identity,
concurrent project mutation isolation, frozen requests and recorded artifact
reopening, map-before-transport ordering, source replacement/preparation failure,
pause/resume and revision-guarded navigation, independent titles, completed/paused
variants and selection/preparation isolation, whole-scene GPU placement/framing,
texture base pixels/mips, aggregate admission and publication/cancellation lifetime.
These tests and the milestone-4 example Debug build passed. They do not claim real sandbox-panel interaction or GUI acceptance.

The user approved one manual metadata update of the existing current project for
the schema-2 title/variant extension on 2026-10-29. The app was closed; original
metadata was backed up and compared before an atomic app-files write. Existing
source/prepared references reopened unchanged. No old-format decoder or automatic
migration ships in the app; this approval does not introduce ongoing compatibility
policy or permission to discover/delete unrelated artifacts.

The user separately approved preserving the existing schema-2 draft for the
schema-3 location hierarchy. With the app closed and original bytes unchanged,
a validated candidate was written atomically through EarthAppFiles and reopened
with the real store. Its title, search/resolved point, dimensions and detail were
retained as one editable location; it had no captures. The original metadata
backup is retained outside the repository and the temporary helper was removed.
No schema-2 runtime reader, automatic update or artifact discovery was added.
