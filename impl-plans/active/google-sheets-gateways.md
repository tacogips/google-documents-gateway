# Google Sheets reader and writer gateways

**Status**: Completed
**Date**: 2026-08-13
**Design**: `design-docs/specs/design-google-sheets-gateways.md`

## Development list established before implementation

- [x] Add fixed-role `google-sheet-gateway-reader` and
  `google-sheet-gateway-writer` SwiftPM products.
- [x] Give the reader metadata/value reads and only the exact
  `spreadsheets.readonly` scope.
- [x] Give the writer create/append/update/clear/batch-value updates and only
  the exact `spreadsheets` scope.
- [x] Reject copied cross-role commands before authentication or HTTP access.
- [x] Validate and size-bound value input, require exact clear confirmation,
  and make dry-run avoid OAuth and transport calls.
- [x] Reuse the shared Desktop OAuth, token, transport, JSON, and kinko
  foundations used by Docs and Drive.
- [x] Add tests, documentation, package integration, and quality gates.

## Implemented tasks

### TASK-SHEETS-001: Products and permission boundary

**Status**: Completed

Both products have thin role-fixed entry points. The reader exposes
`spreadsheet get`, `values get`, and `values batch-get`. The writer exposes
`spreadsheet create`, `values append`, `values update`, `values clear`, and
`values batch-update`. Neither executable can dispatch the other role's
business commands.

### TASK-SHEETS-002: Request construction and validation

**Status**: Completed

Implemented encoded Sheets v4 request paths, repeated ranges, `RAW` and
`USER_ENTERED` input modes, lossless structured provider responses, JSON file
or stdin value bodies, a 2 MiB input limit, and exact range confirmation for a
live clear. Unknown options and unsupported inputs fail locally. Dry-run emits
a redacted request plan without loading credentials or calling Google.

### TASK-SHEETS-003: Exact-scope OAuth

**Status**: Completed

Reader and writer use separate kinko profiles, consent flows, scopes, and
role-bound token files. The common loopback/PKCE implementation validates
state, requires a refreshable initial grant, preserves refresh tokens, and
rejects a token store created for the other role.

### TASK-SHEETS-004: Verification and documentation

**Status**: Completed

README and executable help list the role-specific surface and kinko setup.
Boundary, input, dry-run, request, scope, and shared OAuth tests run as part of
the package suite. No spreadsheet values or secret values are logged by the
gateway.

## Verification

- [x] `swift test`
- [x] `swift build`
- [x] strict SwiftLint with the mise-installed binary
- [x] both Sheets `--help` smoke checks
- [x] no Swift file over 1,000 lines
- [x] redacted secret scan and machine-local-path audit
- [x] no commit or push performed
