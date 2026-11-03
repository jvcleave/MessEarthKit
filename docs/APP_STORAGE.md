# Example app storage and file access

MessEarthKit includes a macOS example app for downloading geographic 3D tiles,
preparing models, previewing captures and exporting GLBs and USDZs. This reference describes
the app's file ownership and persistence rules. The reusable Swift package
accepts caller-supplied locations and does not choose the app's storage root.
See the [technical reference](TECHNICAL_REFERENCE.md#example-app-storage-and-lifecycle)
for project metadata and the [README](../README.md) for the app workflow.

## Ownership and isolation

The composition root creates one
[`EarthAppFiles`](../MessEarthKit/MessEarthKit/Storage/EarthAppFiles.swift) actor
and injects it into stores and services. It owns the managed root, checked names
and URLs, small metadata reads/writes, directory operations, authorization leases
and Finder actions. Project schemas and job scheduling stay with their feature
owners. Views send semantic actions to view models; they do not choose roots,
perform file I/O or start independent security scopes.

Metadata operations serialize off `MainActor` and return immutable Sendable
values. The injected root also allows verification in temporary directories.
An unavailable normal root is an explicit error; it does not select another
location silently. Centralizing app policy must not serialize network/decoding
behind metadata work or route large payloads through whole-file metadata APIs.

SDK workers retain bounded artifact streaming, SQLite connections, hashing,
staging and atomic publication. They receive authorized roots from the app and
remain independent of its concrete file owner.

## Managed locations

The default root is `~/Documents/MessEarthKit/`. Settings can move this complete
managed layout to a user-selected root:

```text
appSettings.json
exportQueue.json
stats/
  RequestUsage.sqlite
projects/
  <project UUID>/
    project.json
    exports.json
    sources/<source attempt UUID>/
    prepared/<preparation UUID>/
    output/<export UUID>/
```

Settings use schema 1, projects schema 5, export history schema 1 and the global
export queue schema 1. `exportQueue.json` is first written when the queue changes.
The `exports.json` file is first created with a tracked export. Relative references
and validated UUIDs identify artifacts; display names and addresses are metadata.
SDK artifact names/layouts stay with the SDK. Export naming is documented in the
[technical reference](TECHNICAL_REFERENCE.md#export-filenames-and-history).
An output directory may also contain its optional `.glb.info.json`; export history
continues to identify the independent GLB. See [the companion format](GLB_INFO.md).

Prepared artifacts can contain optional `capture.info.json` companions in their
root and individual model folders. Explicit Prepare Models, Reveal Models and
export operations snapshot the location title and variant title through the SDK's
metadata-only `EarthCaptureStore.recordIdentity` worker. Revealing an existing
preparation refreshes its companions without preparing geometry again. Names are
portable metadata; UUID directories, raw archives and model payloads retain their
identities and bytes. See the [prepared-folder identity contract](TECHNICAL_REFERENCE.md#prepared-folder-display-identity).

API keys stay in Keychain or active memory. They are excluded from settings,
projects, request history and source artifacts. Library preferences go through
the one settings owner and `appSettings.json`. The file owner retains only the
storage-location bookmark in a separate bootstrap file, described below; feature
views/stores do not introduce independent preference files or `UserDefaults`.
The request ledger is app-wide.

## Moving storage

**Settings → Storage → Move Storage…** moves the existing managed library to an
empty writable folder. It does not merge libraries. The destination must be
outside the current root and its parents. Download/preparation/export/preview
jobs, history operations and pending project/settings saves must finish first.
The app blocks new actions, stops request-history refreshes and closes its SQLite
connection before file copying. All filesystem work remains with `EarthAppFiles`;
the UI consumes progress and sends move/cancel actions.

The file owner copies `projects`, `stats`, any `appSettings.json` and any
`exportQueue.json` to a private staging folder in the destination, rejects links
and unsupported file types, and compares source/copy hashes with bounded buffers.
It checks the source inventory
again before publication. Project/source/preparation/export identities and file
bytes are retained. Other files at the previous root are left in place.

Only after verification and publication does it atomically save the selected
root's security-scoped bookmark to `MessEarthKit/StorageLocation.json` inside the
system Application Support directory. This schema-1 bootstrap file remains
outside movable library storage. Root access is retained by the file owner;
operation-specific leases use that authorization. Subsequent launches resolve
the bookmark without mounting drives or presenting system UI. Stale bookmarks
are refreshed after access validation. An invalid or unavailable selection fails
explicitly without choosing the default root or recreating a missing selected
folder. No project, settings or export-history schema changes are involved.

Failure or cancellation before location publication leaves the original library
active and removes only this move's copies. After publication, the new location
is authoritative; cleanup failure or late cancellation leaves old copies and
reports a Finder action. Old owners reject further managed I/O. The composition
root rebuilds project/settings/usage/viewer owners for the new URLs, preserving
the current API-key field; Keychain storage is independent of the library.

The move temporarily needs space for another copy of the managed data. An app
or system interruption can leave staged or published copies in the destination;
the saved location determines which library opens. No interrupted copy is
automatically adopted or deleted.

## Source, preparation and export lifetimes

Registering a variant creates an offline paused source journal and records its
request/identity before transport. Explicit Download/Resume actions start
acquisition. Reopening validates the recorded journal, request and preparation
profile/source; navigation never starts transport or selects a newest archive.
Location/variant mutation and area-freeze rules are described in the
[project metadata contract](TECHNICAL_REFERENCE.md#project-metadata).

The download queue admits two independent source acquisitions and serializes native
model preparation, including preview/export preparation. Jobs retain explicit
project/variant/source identity and survive navigation; they never use a later
selection as their write target. Download queue entries are session-only, while SDK
journals retain completed source files and interruption checkpoints on disk.
Pause waits for the worker to stop before releasing its slot. Active variants,
their containing locations and projects cannot be deleted, and their source
detail/area cannot change. Unrelated variants and projects remain available.

Completed source archives are immutable. Preparation and export use new
destinations outside their input archives. Create required parents, but leave
destinations absent when the SDK's API requires that. Failed/cancelled work may
remove only its own unpublished staging files or empty output directory.
Existing sources, committed preparations and completed outputs remain intact.

Each export captures its target variant, options, name and request once. The
service retains access while preflighting/writing and revalidates the exact
source/preparation before publication. Offline preparation records its result
on that variant without changing the current editing location or preview.

Successful GLB/USDZ publication appends provenance and the managed output reference
to `exports.json` with a serialized atomic write. A missing history file is the
initial state; malformed, unsupported or mismatched history fails explicitly.
Missing outputs remain recorded as unavailable, and Reveal rechecks existence
and confinement. If history writing fails after output publication, keep the file
and report the failure with a Finder action. Publication that wins a concurrent
cancellation still records the completed file. Cancellation before publication
adds no history and cannot remove earlier exports.

Each export can be renamed or explicitly deleted while project work is idle.
Rename keeps the export UUID and provenance, moves the GLB or USDZ and any optional GLB
`.glb.info.json` together, then atomically updates history. It rejects invalid
names and existing destinations; ordinary failures restore the original files.
Capture names embedded inside the files remain unchanged. Interrupted rename
can leave a recorded file unavailable and requires review in Finder.

History schema 1 accepts `.glb` and `.usdz` filenames and derives the managed
path from that record. Existing GLBs remain unchanged. USDZ keeps its detailed
channel/optimization/identity metadata inside its root layer; listing reads only
that bounded marker. Format and optimization settings are snapshotted with the
variant request. Each regular/optimized export gets a fresh UUID output folder.
There is no scan, history reassignment or rewrite of older files.

## Global export queue and collection

One library-retained `EarthExportQueue` owns the global export queue. Its
schema-1 `exportQueue.json` contains explicit project/location/variant/source
identities, captured display/export names, preparation profile, format, channel
options, optimization settings, selection, phase and completed export references.
It contains no security-scoped destination bookmarks, API keys or source URLs.
Only a missing file initializes an empty queue; malformed or unsupported metadata
blocks queue changes until it can be read. Queue writes are serialized atomic
snapshots through `EarthAppFiles`, within the normal small-metadata limit.

START snapshots checked pending entry IDs and processes them sequentially.
Before each worker starts, its new export UUID and running phase are saved. The
existing export service revalidates the pinned source and preparation profile;
later selection, location names and export-control changes do not replace the
request. A worker waits for any active export-history read before starting.
Project refresh after successful export uses the worker's awaited history result
without starting a second background read. Native preparation uses the shared
preparation gate. Individual export failures stay on their entries and processing
continues. Pending entries can be
unchecked or removed during a run; the active entry stays locked until settled.
Removing an entry never deletes an output or changes export history.

Cancellation waits for the active worker and its project refresh. Publication
that wins cancellation remains complete and collectible. Other pending entries
are retained; cancelled/failed entries require Retry. Relaunch never starts
exports. Running entries are reconciled against their exact saved export UUID
in project history: a published tracked result becomes complete, an unpublished
attempt becomes cancelled, and a history-read failure stays explicit. No output
folders are scanned or adopted. An interruption before history publication can
leave an untracked file for review in Finder, following normal export policy.

COLLECT copies checked completed results into a new named batch folder beneath
the user-selected folder. The file owner resolves the recorded export UUID
through current history so later renames are respected. It includes each GLB's
optional `.glb.info.json` companion. Duplicate names receive numeric suffixes,
including matching companion names; existing destination files are never replaced.
The source exports and history remain unchanged. A known output whose history
write failed can be collected from its explicit retained reference.

The file owner retains source/destination access and export read tokens while a
worker streams copies in bounded buffers, verifies their SHA-256 hashes and
checks source file identity/size/modification time. It publishes the complete
batch from private staging only after verification. Failure/cancellation removes
only that transaction's unpublished copies; incomplete cleanup is an explicit
error. Managed-library destinations and linked source files are rejected. New
project work is disabled during queue processing/collection; navigation and
pending-row selection/removal remain available. Active queue work, collection,
folder selection and pending queue saves block storage relocation. Moving an
idle library includes the queue and preserves its relative output references.

## Confinement and access

Resolve checked path components beneath the configured root. Reject traversal,
escaping references, unsupported symlinks, mismatched IDs and input/output
overlap. A string-prefix comparison alone is insufficient proof of containment.

The app-files owner creates operation-specific authorization leases. Retain a
lease through queued reads, catalog paging, import/upload, preparation and export,
including cancellation until the worker has finished. Navigation must not release
access still in use. Preview scenes contain prepared GPU resources/shader values;
their file lease can end after the worker completes. Hidden preview resources can
be released independently of retained project jobs.

Report typed access, storage, corruption and unsupported-format errors. Runtime
diagnostics must exclude credentials, source URLs and private absolute paths.

## Export viewer read lifetime

VIEW starts a read of the specific history/project/export identity in a dedicated
window. It never regenerates output from a capture or preparation. The app-files
actor resolves the managed output and holds its security scope while the worker
reads and uploads it. Active read tokens block rename/export deletion for that
export and project deletion for its project. Attribute identity/size/modification
time are rechecked at completion; changed files fail the load.

The actor remains reentrant during decoding, so unrelated metadata work can
continue. Cancellation keeps the lease until native work settles. Close or a new
selection cancels the old request; late results cannot attach to the window.
After upload, only immutable GPU resources and cached display values remain.
Closing releases them. No new managed folders, history schema or preferences are
introduced by viewing. The capture preview retains its own lifecycle.

## Confirmed deletion

Project, location, variant and export deletion require explicit confirmation and serialize
with metadata saves. Disable deletion during active work; settle workers and GPU
resources before mutation. Project deletion waits for queued saves and blocks
later writes from recreating the removed project.

Deleting a project moves its entire UUID folder to macOS Trash, including exports.
It leaves other projects, settings, Keychain and the global request ledger intact.
Location/variant deletion detaches metadata references before moving only their
recorded source attempts and unshared preparations into a Trash bundle. Shared
preparations remain. Variant/location deletion retains exports and history.
Removing a final variant leaves the location's frozen footprint intact.

Deleting an export detaches its history entry and moves only its UUID output
folder, including its optional information companion, to Trash. A failed Trash
operation restores history. Missing outputs can be removed from history without
recreating their folders. Source archives, preparations and other exports remain
intact.

Normal failures restore moved paths and metadata. Interrupted deletion may leave
a retained deletion folder; incomplete rollback reports an explicit error. There
is no automatic orphan adoption or cleanup. Tests inject a Trash operation under
temporary roots rather than deleting user projects.

## Current formats and verification

Read/write current app schemas only. Reject unknown versions, missing required
fields and corrupt existing metadata without replacing them with defaults.
Only a missing settings file initializes default settings. Do not infer projects
from source folders, scan old storage roots, add legacy readers or automatically
migrate user data. Current-format pause/resume and explicit retry retain the
recorded identities and files.

Use the existing [storage tests](../MessEarthKit/MessEarthKit/Storage/Tests/) and
[workflow tests](../MessEarthKit/MessEarthKit/Workflow/Tests/) for metadata,
confinement, publication and job/access lifetime changes. SDK tests cover bounded
payload I/O independently. Local commands are in the
[technical reference](TECHNICAL_REFERENCE.md#verify-locally).
