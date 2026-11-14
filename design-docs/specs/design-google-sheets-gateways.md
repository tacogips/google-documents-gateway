# Permission-Separated Google Sheets Gateways

> Historical initial-design record. The additive API coverage expansion is
> specified in `api-coverage.md`, which supersedes this document where the
> supported method set differs.

> Implementation reconciliation (2026-08-13): this file preserves the
> pre-implementation design and review record. The delivered shared module is
> named `AppCore`; it preserves provider JSON dynamically rather than declaring
> an exhaustive Sheets DTO graph, and does not add generic automatic GET
> retries. The completed implementation and verification record is
> `impl-plans/active/google-sheets-gateways.md`.

**Status**: Accepted for implementation
**Feature ID**: `google-sheets-gateways`
**Issue**: `workflow-input: Implement permission-separated Google Docs Sheets and Drive gateway clients`
**Last reviewed**: 2026-08-13

## 1. Purpose

This design defines two role-separated Swift command-line programs for Google
Sheets:

- `google-sheet-gateway-reader` reads spreadsheet metadata and cell values.
- `google-sheet-gateway-writer` creates spreadsheets and performs controlled
  value mutations.

The executable, configured credential role, requested OAuth scope, stored token
role, and granted OAuth scope must all agree before any remote request is sent.
This makes a binary's authority visible, testable, and fail-closed.

## 2. Context and References

The implementation is part of the six-binary `document-gateway` suite and uses
the same shared authentication, transport, structured-output, and error
foundations as the Docs and Drive features.

Authoritative references inspected for this design:

- `../mail-gateway`: installed-app OAuth bootstrap, credential configuration,
  atomic token storage, `auth status`, `doctor`, redacted errors, request
  injection, and reader/writer executable separation.
- <https://github.com/googleworkspace/cli>: discoverable resource/action command
  naming, JSON-first operation input/output, request preview, and Sheets range
  handling.
- Google Sheets API v4 REST and OAuth documentation: endpoints, request and
  response models, required options, and the `spreadsheets.readonly` versus
  `spreadsheets` capability boundary.

The upstream CLI is a behavioral reference, not a runtime dependency. The Swift
implementation talks directly to `https://sheets.googleapis.com/v4`.

## 3. Goals

- Provide metadata and single-/multi-range value reads without mutation
  authority.
- Provide controlled create, append, update, clear, and multi-range value
  update operations without Drive-wide authority.
- Request exactly one Sheets scope per role and reject missing, broader,
  conflicting, unknown, or stale scope metadata.
- Return stable JSON on success and failure with actionable, redacted details.
- Reuse shared Google OAuth, token refresh, HTTP transport, error, and testing
  abstractions across all document gateway products.
- Use Swift 6 concurrency-safe types and keep every non-generated Swift source
  file below 1,000 lines.
- Support macOS 14 and Linux where the surrounding package supports them.

## 4. Non-Goals

- Arbitrary `spreadsheets.batchUpdate` structural requests, formatting,
  protected-range management, sheet deletion, or Drive permission management.
- `batchGetByDataFilter`, `batchUpdateByDataFilter`, `batchClear`, or
  `batchClearByDataFilter` in the first release.
- CSV import/export, formula analysis, schema inference, or local spreadsheet
  caching.
- Service accounts, domain-wide delegation, or device authorization in the
  first release.
- Accepting Drive scopes as substitutes for Sheets scopes, even though Google
  documents some Drive scopes as technically sufficient for Sheets endpoints.
- Exposing a generic raw HTTP command.

`spreadsheets.values.batchUpdate` is in scope. The broader structural
`spreadsheets.batchUpdate` endpoint is deliberately excluded because its open
request union includes destructive operations outside this feature contract.

## 5. Products and Capability Boundary

| Product | Remote commands | Required access mode | Exact OAuth scope |
|---|---|---|---|
| `google-sheet-gateway-reader` | `spreadsheet get`, `values get`, `values batch-get` | `read` | `https://www.googleapis.com/auth/spreadsheets.readonly` |
| `google-sheet-gateway-writer` | `spreadsheet create`, `values append`, `values update`, `values clear`, `values batch-update` | `write` | `https://www.googleapis.com/auth/spreadsheets` |

Both products also expose local control commands:

- `config validate`
- `auth login --credential <id>`
- `auth status --credential <id>`
- `auth revoke --credential <id>`
- `doctor --credential <id>`
- `--help`
- `--version`

The reader parser has no mutation cases and its help contains no mutation
commands. The writer parser has no read cases. Shared implementation types do
not imply shared CLI authority: each executable constructs a role-specific root
command with a closed command enum.

## 6. Command Contract

All remote commands require `--credential <id>`. Spreadsheet identity and A1
ranges are always explicit; the gateway does not infer them from a current
directory or prior invocation.

Every command accepts global `--config <path>` and `--pretty` options. Config
resolution is explicit `--config`, then `DOCUMENT_GATEWAY_CONFIG`, then
`$XDG_CONFIG_HOME/document-gateway/config.toml` (falling back to the platform
config directory when `XDG_CONFIG_HOME` is unset). Pretty mode changes only JSON
whitespace.

### 6.1 Reader Commands

```text
google-sheet-gateway-reader spreadsheet get \
  --credential <id> --spreadsheet-id <id>

google-sheet-gateway-reader values get \
  --credential <id> --spreadsheet-id <id> --range <a1-range> \
  [--major-dimension ROWS|COLUMNS] \
  [--value-render-option FORMATTED_VALUE|UNFORMATTED_VALUE|FORMULA] \
  [--date-time-render-option SERIAL_NUMBER|FORMATTED_STRING]

google-sheet-gateway-reader values batch-get \
  --credential <id> --spreadsheet-id <id> \
  --range <a1-range> [--range <a1-range> ...] \
  [--major-dimension ROWS|COLUMNS] \
  [--value-render-option FORMATTED_VALUE|UNFORMATTED_VALUE|FORMULA] \
  [--date-time-render-option SERIAL_NUMBER|FORMATTED_STRING]
```

`spreadsheet get` requests metadata only. Its fixed field mask includes the
spreadsheet ID, URL, spreadsheet properties, sheet properties, and named ranges;
it sets `includeGridData=false` and does not expose a caller-controlled `fields`
option that could turn a metadata read into a grid-data read.

`values batch-get` preserves repeated `--range` order in both the query and the
returned `valueRanges`. Sheets value endpoints do not paginate; the shared
pagination abstraction remains available to the Drive feature but is not
artificially applied here.

### 6.2 Writer Commands

```text
google-sheet-gateway-writer spreadsheet create \
  --credential <id> --title <title> \
  [--locale <locale>] [--time-zone <iana-zone>] [--sheet-title <title>] \
  [--dry-run]

google-sheet-gateway-writer values append \
  --credential <id> --spreadsheet-id <id> --range <a1-range> \
  --input-file <path|-> [--value-input-option RAW|USER_ENTERED] \
  [--insert-data-option OVERWRITE|INSERT_ROWS] [--dry-run]

google-sheet-gateway-writer values update \
  --credential <id> --spreadsheet-id <id> --range <a1-range> \
  --input-file <path|-> [--value-input-option RAW|USER_ENTERED] [--dry-run]

google-sheet-gateway-writer values clear \
  --credential <id> --spreadsheet-id <id> --range <a1-range> \
  --confirm-range <exact-a1-range> [--dry-run]

google-sheet-gateway-writer values batch-update \
  --credential <id> --spreadsheet-id <id> --input-file <path|-> \
  [--value-input-option RAW|USER_ENTERED] [--dry-run]
```

`RAW` is the default input mode. A caller must opt into `USER_ENTERED`, which
can interpret strings as formulas, numbers, dates, or booleans.

`--input-file -` reads standard input so cell values need not appear in shell
history. The accepted single-range input is:

```json
{
  "majorDimension": "ROWS",
  "values": [["name", "score"], ["Alice", 95]]
}
```

The accepted batch input is:

```json
{
  "data": [
    {"range": "Sheet1!A1:B2", "majorDimension": "ROWS", "values": [["a", "b"]]},
    {"range": "Sheet2!A1", "majorDimension": "ROWS", "values": [[true]]}
  ]
}
```

Cell inputs are limited to JSON strings, finite numbers, booleans, and null.
Objects and nested arrays within a cell are rejected locally. Empty payloads,
empty batch data, non-finite numeric values, invalid enum values, and encoded
request bodies above the documented local maximum are rejected before auth or
network access. The initial encoded-body maximum is 2 MiB, matching Google's
published recommendation for efficient API requests, and is a named constant
covered by tests and help text.

`values clear` requires `--confirm-range` to exactly equal `--range` after
trimming surrounding whitespace. A dry run does not require confirmation and
does not load a token or send a request. All writer commands support `--dry-run`;
the result contains the method, redacted URL template, query options, body byte
count, and affected ranges, but never credentials, bearer headers, or cell
values.

### 6.3 Endpoint Mapping

| Command | HTTP request |
|---|---|
| `spreadsheet get` | `GET /v4/spreadsheets/{spreadsheetId}` |
| `values get` | `GET /v4/spreadsheets/{spreadsheetId}/values/{range}` |
| `values batch-get` | `GET /v4/spreadsheets/{spreadsheetId}/values:batchGet` |
| `spreadsheet create` | `POST /v4/spreadsheets` |
| `values append` | `POST /v4/spreadsheets/{spreadsheetId}/values/{range}:append` |
| `values update` | `PUT /v4/spreadsheets/{spreadsheetId}/values/{range}` |
| `values clear` | `POST /v4/spreadsheets/{spreadsheetId}/values/{range}:clear` |
| `values batch-update` | `POST /v4/spreadsheets/{spreadsheetId}/values:batchUpdate` |

Path segments are percent-encoded by one shared request builder. Query items are
constructed with `URLComponents`, including repeated `ranges` entries. No user
input is concatenated into a URL.

## 7. Authentication and Scope Enforcement

### 7.1 Configuration

The shared configuration contains credential profiles rather than secrets:

```toml
[[credentials]]
id = "sheets-reader"
service = "sheets"
access_mode = "read"
oauth_client_secret_path = "/path/to/desktop-client.json"
token_store_path = "/path/to/sheets-reader-token.json"
```

`access_mode` is a closed enum: `read` or `write`. Credential IDs are unique.
Paths may be relative to the config file and are standardized before use. A
reader credential and writer credential must not share a token-store path.

Following `mail-gateway`, path fields have normalized per-credential environment
overrides. Secret-bearing JSON may be supplied through kinko-backed environment
injection where supported by the shared credential loader. Documentation names
variables and commands only; it never prints sample secret values. Precedence is
explicit CLI path, normalized credential environment override, then TOML.

### 7.2 Installed-App OAuth

`auth login` uses a Google Desktop OAuth client, loopback redirect on localhost,
PKCE, random state, offline access, and an explicit consent prompt. It requests
only the single scope fixed by the invoking executable. Reader login never asks
for `spreadsheets`; writer login never asks for Drive authority.

Token stores are written atomically with directory mode `0700` and file mode
`0600`. They contain access/refresh tokens plus non-secret inspection metadata:

- service and access mode
- requested and granted normalized scope sets
- token type and expiry
- authenticated principal when Google returns it

No token, authorization code, OAuth client secret, refresh response, or bearer
header may enter structured output, error details, logs, dry-run output, test
snapshots, or committed fixtures.

### 7.3 Fail-Closed Preflight

Before every non-dry-run remote operation, the gateway validates all of the
following:

1. The executable's fixed service is `sheets`.
2. The executable's fixed mode equals the credential's configured mode.
3. The token store service and mode equal the executable service and mode.
4. The token's normalized granted scope set equals the one-element expected set.
5. The token is unexpired or can be refreshed and safely persisted.

The equality check intentionally rejects:

- a writer token in the reader binary;
- a reader token in the writer binary;
- Drive-wide or `drive.file` substitution;
- mixed read/write Sheets scopes;
- extra Workspace data scopes;
- legacy stores with absent or unparseable granted-scope metadata.

For the initial authorization-code exchange, an omitted `scope` means the exact
requested set was granted, so login records that one-element set. For refresh,
an omitted `scope` retains the previously validated granted set. A new/imported
store without trustworthy granted scopes is `UNKNOWN_SCOPE` and must be replaced
through role-specific `auth login`. A refresh that returns a different scope set
is rejected before the refreshed token is used or persisted.

`auth status` and `doctor` use the same preflight without returning token values.
`doctor` checks config syntax, path accessibility, Desktop OAuth client shape,
token-store permissions/decoding, expiry/refresh readiness, and exact scope
agreement. It performs no spreadsheet mutation and needs no spreadsheet ID.
`auth revoke` remains available for a mismatched or malformed local store: it
attempts provider revocation only when a token can be decoded, then removes the
selected local store without requiring role/scope agreement and reports the
redacted result.

## 8. Architecture and Swift Boundaries

The feature extends the issue-wide package architecture:

- `DocumentGatewayCore`: shared configuration, OAuth, token persistence,
  redaction, HTTP transport, request/response envelope, errors, clocks, and file
  access abstractions.
- `DocumentGatewayCore/Sheets`: role-specific commands, Sheets request builder,
  API DTOs, and application services.
- `GoogleSheetGatewayReader`: minimal executable entry point selecting `.sheets`
  and `.read`.
- `GoogleSheetGatewayWriter`: minimal executable entry point selecting `.sheets`
  and `.write`.
- `DocumentGatewayCoreTests`: shared and Sheets-specific unit/protocol tests.

The two executables depend on the same core target but receive different
`GatewayRole` values at construction. Role is immutable and `Sendable`.
Business command enums are separate so a mutation cannot be represented by the
reader's parser.

External effects use injected protocols:

- `HTTPTransport: Sendable` for async `URLSession` requests;
- `OAuthAuthorizing: Sendable` for login and refresh;
- `TokenStore: Sendable` for atomic persistence;
- `FileReading: Sendable` for JSON input;
- `Clock: Sendable` for expiry tests.

Mutable shared state is isolated in actors or synchronized wrappers. DTOs are
`Codable` and `Sendable`; cell values use a closed `SheetsCellValue` enum rather
than `[String: Any]`. Linux networking imports `FoundationNetworking` when
needed. No force unwraps, implicit globals, or unchecked mutable singletons are
permitted.

## 9. API Models

Representative decoded/encoded types include:

- `Spreadsheet`, `SpreadsheetProperties`, `Sheet`, `SheetProperties`,
  `NamedRange`, and `GridRange`;
- `ValueRange` and `BatchGetValuesResponse`;
- `CreateSpreadsheetRequest`;
- `UpdateValuesResponse`, `AppendValuesResponse`, `ClearValuesResponse`, and
  `BatchUpdateValuesResponse`;
- `GoogleAPIErrorEnvelope` with status, reason, message, request ID when
  available, and retryability.

Unknown response fields are ignored for forward compatibility. Required command
inputs use strict local DTOs and reject unknown top-level fields to catch typos.
Provider error bodies are size-bounded and redacted before inclusion in error
details.

## 10. Structured Output and Exit Behavior

Standard output contains one JSON document and no prose. Successful operations
use:

```json
{
  "ok": true,
  "command": "values.get",
  "role": "reader",
  "credentialId": "sheets-reader",
  "data": {}
}
```

Failures use the same stable error shape on standard error:

```json
{
  "ok": false,
  "command": "values.get",
  "error": {
    "code": "SCOPE_MISMATCH",
    "message": "Credential scope does not match the reader role",
    "retryable": false,
    "details": {"expectedMode": "read", "actualMode": "write"}
  }
}
```

Error categories are `INVALID_ARGUMENT`, `CONFIG_INVALID`, `AUTH_REQUIRED`,
`AUTH_EXPIRED`, `SCOPE_MISMATCH`, `INPUT_TOO_LARGE`, `PROVIDER_RATE_LIMITED`,
`PROVIDER_API_ERROR`, `TRANSPORT_ERROR`, and `INTERNAL_ERROR`. Exit codes group
CLI/config/auth/scope/provider/internal failures consistently across all six
products. Messages explain the next safe action, such as running role-specific
`auth login`, without exposing secret material.

Provider retries are limited to idempotent reads and retry-safe status codes.
Mutations are not automatically replayed because an ambiguous network failure
could otherwise duplicate an append or create.

## 11. Security Properties

- Reader authority is constrained by both command construction and an exact
  read-only OAuth grant.
- Writer authority is constrained to Sheets; no Drive scope is requested or
  accepted.
- Clear requires exact range confirmation; all writes offer a token-free,
  network-free dry run.
- Cell content is omitted from dry-run summaries and provider error snippets are
  redacted and bounded.
- Inputs are passed as arguments or JSON, never interpolated into a shell.
- OAuth state, PKCE verifier, tokens, client secrets, and kinko values are never
  printed or committed.
- Token files use least-permissive local modes and separate paths per role.
- Reader and writer role/scope mismatches fail before HTTP transport invocation.

## 12. Verification and Acceptance

The implementation is accepted when:

- both named products build and their help lists only role-appropriate commands;
- reader mutation strings fail parsing and transport is not invoked;
- exact-scope tests cover correct, reversed, broader, mixed, missing, malformed,
  expired, and refresh-changed grants;
- request protocol tests assert method, encoded path, repeated query items,
  headers, and JSON body for every endpoint in section 6.3;
- DTO tests decode representative success/error payloads and preserve mixed cell
  scalar types;
- output tests assert stable JSON, redaction, exit categories, dry-run behavior,
  clear confirmation, and the 2 MiB boundary;
- OAuth/config/doctor tests match the shared conventions and never expose
  credentials;
- no non-generated Swift file exceeds 1,000 lines;
- `mise run lint`, `mise run test`, and `mise run build` pass;
- README, CLI help, this design, and the implementation plan agree; and
- no secret scan finding, commit, or push is produced by the work.

## 13. Review Record

### Self-Review

**Decision**: Accepted after correction.

The first pass left `batch-update` ambiguous between the structural and values
APIs and did not define distinct initial-exchange versus refresh behavior when a
token response omits scope. This version separates
`spreadsheets.values.batchUpdate` from the excluded structural API, records the
requested set only for a new exchange, and otherwise retains only a previously
validated scope set.

### Independent Review

**Decision**: Accepted after correction.

The independent pass identified two medium issues: a metadata `fields` escape
hatch could have expanded reads to grid data, and clear lacked an accidental-use
guard. The accepted design fixes the metadata field mask and requires exact
range confirmation while preserving token-free dry runs. No high or unresolved
medium findings remain.
