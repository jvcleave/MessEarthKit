# Example app storage and file access

MessEarthKit includes a macOS example app for downloading geographic 3D tiles,
preparing models, previewing captures and exporting GLBs. This reference describes
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

The default root is `~/Documents/MessEarthKit/`:

```text
appSettings.json
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

Settings use schema 1, projects schema 5 and export history schema 1. The
`exports.json` file is first created with a tracked export. Relative references
and validated UUIDs identify artifacts; display names and addresses are metadata.
SDK artifact names/layouts stay with the SDK. Export naming is documented in the
[technical reference](TECHNICAL_REFERENCE.md#export-filenames-and-history).
An output directory may also contain its optional `.glb.info.json`; export history
continues to identify the independent GLB. See [the companion format](GLB_INFO.md).

API keys stay in Keychain or active memory. They are excluded from settings,
projects, request history and source artifacts. Preferences go through the one
settings owner and `appSettings.json`; feature views/stores do not introduce
independent preference files or `UserDefaults`. The request ledger is app-wide.

## Source, preparation and export lifetimes

Registering a variant creates an offline paused source journal and records its
request/identity before transport. Explicit Download/Resume actions start
acquisition. Reopening validates the recorded journal, request and preparation
profile/source; navigation never starts transport or selects a newest archive.
Location/variant mutation and area-freeze rules are described in the
[project metadata contract](TECHNICAL_REFERENCE.md#project-metadata).

Completed source archives are immutable. Preparation and export use new
destinations outside their input archives. Create required parents, but leave
destinations absent when the SDK's API requires that. Failed/cancelled work may
remove only its own unpublished staging files or empty output directory.
Existing sources, committed preparations and completed outputs remain intact.

Each export captures its target variant, options, name and request once. The
service retains access while preflighting/writing and revalidates the exact
source/preparation before publication. Offline preparation records its result
on that variant without changing the current editing location or preview.

Successful GLB publication appends provenance and the managed output reference
to `exports.json` with a serialized atomic write. A missing history file is the
initial state; malformed, unsupported or mismatched history fails explicitly.
Missing outputs remain recorded as unavailable, and Reveal rechecks existence
and confinement. If history writing fails after GLB publication, keep the file
and report the failure with a Finder action. Publication that wins a concurrent
cancellation still records the completed file. Cancellation before publication
adds no history and cannot remove earlier exports.

Each export can be renamed or explicitly deleted while project work is idle.
Rename keeps the export UUID and provenance, moves the GLB and any optional
`.glb.info.json` together, then atomically updates history. It rejects invalid
names and existing destinations; ordinary failures restore the original files.
Capture names embedded inside the files remain unchanged. Interrupted rename
can leave a recorded file unavailable and requires review in Finder.

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
