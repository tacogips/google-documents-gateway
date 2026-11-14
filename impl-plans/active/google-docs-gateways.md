# Google Docs reader and writer gateways

**Status**: Completed
**Date**: 2026-08-13
**Design**: `design-docs/specs/design-google-docs-gateways.md`

## Development list established before implementation

- [x] Add fixed-role `google-docs-gateway-reader` and
  `google-docs-gateway-writer` SwiftPM products.
- [x] Give the reader only `document get` and the exact
  `documents.readonly` scope.
- [x] Give the writer only `document create` and `document batch-update` and
  the exact `documents` scope.
- [x] Reuse a shared structured-JSON CLI, HTTP transport, OAuth client,
  role-bound token store, validation, and error contract.
- [x] Follow the sibling mail-gateway Desktop OAuth, loopback, PKCE, refresh,
  revoke, kinko, and local file-permission conventions.
- [x] Preserve Google response JSON losslessly, including fields not known to
  this package.
- [x] Add boundary, request, OAuth, refresh, storage, and redaction-oriented
  tests; run SwiftLint, tests, builds, and help checks.

## Implemented tasks

### TASK-DOCS-001: Products and permission boundary

**Status**: Completed

Both products have thin role-fixed entry points over `AppCore`. Reader and
writer command sets and OAuth scopes are closed in `GatewayRole` and
`GatewayCommandRunner`; a reader mutation is rejected before credential load.

### TASK-DOCS-002: Docs request surface

**Status**: Completed

Implemented `document get` with `includeTabsContent=true` by default and an
allowlisted suggestions view mode. Implemented create and representative
batch-update requests with exactly one inline/file JSON source, a 2 MiB input
ceiling, non-empty request validation, and a closed request-variant allowlist.
Provider responses remain structured JSON without a lossy exhaustive DTO.

### TASK-DOCS-003: OAuth and credential lifecycle

**Status**: Completed

Implemented installed-Desktop-client JSON loading from role-specific kinko
environment keys, localhost browser login, state and PKCE validation, exact
single-scope grants, mandatory initial refresh tokens, refresh-token
preservation, remote revoke, and atomic role-bound `0600` token files.
Authorization codes, PKCE verifiers, access tokens, and refresh tokens are not
accepted as command arguments or printed.

### TASK-DOCS-004: Verification and documentation

**Status**: Completed

Docs behavior is covered by focused request/OAuth/storage tests and the shared
boundary suite. README setup includes the copied kinko key names, role-specific
login commands, scopes, commands, and storage behavior. No secret value is
stored in the repository.

## Verification

- [x] `swift test`
- [x] `swift build`
- [x] strict SwiftLint with the mise-installed binary
- [x] both Docs `--help` smoke checks
- [x] no Swift file over 1,000 lines
- [x] redacted secret scan and machine-local-path audit
- [x] no commit or push performed
