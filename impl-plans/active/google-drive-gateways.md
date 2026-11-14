# Google Drive reader and writer gateways

**Status**: Completed
**Date**: 2026-08-13
**Design**: `design-docs/specs/design-google-drive-gateways.md`

## Development list established before implementation

- [x] Add fixed-role `google-drive-gateway-reader` and
  `google-drive-gateway-writer` SwiftPM products.
- [x] Give the reader metadata/content/permission reads under exact
  `drive.readonly` authority.
- [x] Give the writer an allowlisted file/permission mutation surface under
  exact `drive.file` authority, with no delete/trash/ownership operation.
- [x] Add bounded pagination, downloads/exports, and resumable uploads.
- [x] Require explicit overwrite, size, exact-ID, observed-state, and broad
  sharing safeguards before relevant operations.
- [x] Keep reader and writer command dispatch, credentials, and token stores
  separate while reusing the common OAuth/transport/JSON foundation.
- [x] Add request, pagination, transfer, upload-host, stale-state, permission,
  role, storage, and boundary tests plus documentation and quality gates.

## Implemented tasks

### TASK-DRIVE-001: Products and least privilege

**Status**: Completed

The reader exposes file list/get/download/export and permission list/get. The
writer exposes folder create, file upload/replace/rename/move, and permission
create/update/delete. The writer uses `drive.file`, so README explicitly notes
that arbitrary pre-existing files are not automatically visible.

### TASK-DRIVE-002: Reader behavior

**Status**: Completed

Implemented Drive v3 metadata, `alt=media` download, export, shared-drive query
flags, bounded `--page-all --max-pages` aggregation, stable continuation
metadata, required transfer ceilings, atomic output writes, and overwrite
refusal. Provider JSON is preserved losslessly.

### TASK-DRIVE-003: Writer behavior and safeguards

**Status**: Completed

Implemented resumable upload initiation and 256 KiB content chunks with 308
continuation and bounded retry. Session URLs must be HTTPS on an approved Google
host before a bearer token is sent. Existing-file mutations require exact file
confirmation plus a matching observed `modifiedTime`; permission update/delete
requires exact permission confirmation plus a matching observed role. Public
or domain sharing requires explicit acknowledgement. Delete/trash, ownership
transfer, raw method dispatch, and arbitrary scope selection do not exist.

### TASK-DRIVE-004: OAuth, tests, and documentation

**Status**: Completed

Drive roles use separate Desktop OAuth consent and role-bound token files with
exact `drive.readonly` or `drive.file` scope. Tests cover unsafe credential IDs,
private token files, paginated aggregation, correct media paths, resumable
binary upload, untrusted session-host rejection, stale preflight rejection,
and shared command/scope boundaries. README documents operations and kinko
setup without values.

## Verification

- [x] `swift test`
- [x] `swift build`
- [x] strict SwiftLint with the mise-installed binary
- [x] both Drive `--help` smoke checks
- [x] no Swift file over 1,000 lines
- [x] redacted secret scan and machine-local-path audit
- [x] no commit or push performed
