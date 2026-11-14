# Permission-Separated Google Drive Gateways

> Implementation reconciliation (2026-08-13): this file preserves the
> pre-implementation design and review record. The delivered `AppCore` uses
> lossless structured provider JSON, bounds upload inputs to an explicit 64 MiB
> ceiling, and implements bounded upload retry without generic read retries or
> interrupted-session persistence. The completed implementation and
> verification record is `impl-plans/active/google-drive-gateways.md`.

**Status**: Accepted for implementation

**Feature ID**: `google-drive-gateways`

**Issue**: `workflow-input: Implement permission-separated Google Docs Sheets and Drive gateway clients`

**Last reviewed**: 2026-08-13

## Purpose

Provide production-oriented Swift CLIs for bounded Google Drive v3 reads and
mutations while making the OAuth authority of each executable obvious and
enforceable. This feature owns the Drive-specific surface of the six-binary
suite:

- `google-drive-gateway-reader`
- `google-drive-gateway-writer`

Docs and Sheets binaries are designed in their own feature artifacts. All six
binaries may share authentication, transport, output, pagination, error, and
dependency-injection infrastructure, but no shared abstraction may weaken the
Drive reader/writer command boundary defined here.

## Reference Baseline

- `../mail-gateway` is the local authority for installed-app OAuth, credential
  configuration precedence, token inspection, `doctor`, structured errors,
  dependency injection, and secret redaction conventions.
- [googleworkspace/cli](https://github.com/googleworkspace/cli) is the external
  authority for discoverable resource/method command naming, structured JSON,
  bounded auto-pagination, schema-aware request construction, and file
  upload/download helper behavior.
- The Google Drive v3 documentation is authoritative where generated CLI
  behavior and the REST API differ, particularly for
  [Drive scopes](https://developers.google.com/workspace/drive/api/guides/api-specific-auth),
  [uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads),
  [downloads and exports](https://developers.google.com/workspace/drive/api/guides/manage-downloads),
  and [permissions](https://developers.google.com/workspace/drive/api/reference/rest/v3/permissions).

## Goals

- Expose useful Drive metadata, content, upload, move, and permission workflows.
- Keep reader tokens non-mutating and writer tokens limited to app-authorized
  files by default.
- Validate the configured role and granted scopes at login, refresh, doctor,
  and immediately before every API operation.
- Bound pagination, response projection, local content transfer, and every
  remote mutation with explicit inputs and configured limits.
- Return one stable JSON envelope for success and actionable JSON for failures.
- Support My Drive and shared-drive resources without silently broadening the
  query corpus.
- Keep secrets out of stdout, stderr, repository files, diagnostics, and tests.

## Non-Goals

- A generic Drive REST passthrough, arbitrary JSON patch command, or arbitrary
  URL fetcher.
- Google Picker or browser-hosted file selection in the first release.
- Full-drive writer authority, file deletion/trashing, ownership transfer,
  shared-drive administration, revisions, comments, labels, or watches.
- Unbounded recursive folder transfer, directory synchronization, or daemon
  operation.
- Printing downloaded/exported bytes to stdout.

## Security and OAuth Model

### Fixed role profiles

Each credential has `service = "drive"` and one immutable role:

| Executable | Credential role | Required granted scope | Rejected Drive scopes |
|---|---|---|---|
| `google-drive-gateway-reader` | `reader` | `https://www.googleapis.com/auth/drive.readonly` | `drive`, `drive.file`, `drive.metadata` |
| `google-drive-gateway-writer` | `writer` | `https://www.googleapis.com/auth/drive.file` | `drive`, `drive.readonly`, `drive.metadata` |

The role check uses normalized, exact scope URIs. A token may also contain
identity scopes needed by the shared OAuth bootstrap, but it must contain
exactly the Drive scope assigned above and no other Drive scope. A writer does
not accept the broader restricted `drive` scope. A reader does not accept a
write-capable scope even when that scope could technically satisfy a read.

`drive.file` is deliberately selected for the writer because Google recommends
it as the non-sensitive per-file scope. Consequently, the writer can mutate
only files it created or files the user has explicitly made available to the
OAuth application. Without Picker integration, arbitrary existing Drive files
are not promised. An API `404` caused by the per-file boundary is returned as
`RESOURCE_NOT_ACCESSIBLE` with guidance to use an app-authorized file; the CLI
must not suggest switching to the full `drive` scope.

### Enforcement points

The shared auth layer must:

1. Bind a credential role to the invoking executable; role mismatch fails
   before browser login or token loading.
2. Request only that role's fixed scopes during installed-app OAuth.
3. Persist normalized granted scopes, token expiry, token type, refresh-token
   presence, authenticated principal, and credential role in the token store.
4. Preserve the stored scope set when a refresh response omits `scope` and
   reject a refresh response that returns an incompatible Drive scope.
5. Require imported/environment token JSON to include scope and role metadata;
   an opaque access-token-only input cannot prove the boundary and is rejected.
6. Run the same role/scope guard before every Drive request, not only during
   `auth status`.

Reader command dispatch contains no mutation cases and receives a read-only
Drive client protocol. Writer dispatch receives only the allowlisted mutation
protocol. This compile-time split supplements runtime scope validation.

### Credential setup and secret handling

Configuration defaults to `$XDG_CONFIG_HOME/document-gateway/config.toml`
with `--config` and `DOCUMENT_GATEWAY_CONFIG` overrides. Credential-specific
environment names follow the mail-gateway normalization convention:

- `DOCUMENT_GATEWAY_CREDENTIAL_<ID>_OAUTH_CLIENT_SECRET_PATH`
- `DOCUMENT_GATEWAY_CREDENTIAL_<ID>_OAUTH_CLIENT_SECRET_JSON`
- `DOCUMENT_GATEWAY_CREDENTIAL_<ID>_TOKEN_STORE_PATH`
- `DOCUMENT_GATEWAY_CREDENTIAL_<ID>_TOKEN_STORE_JSON`

Environment JSON wins over environment path, which wins over the config path.
Credential IDs that normalize to the same environment suffix are invalid.
Default token files are created atomically with user-only permissions. Tokens
provided inline through the environment are never written back to disk during
refresh. `doctor`, `auth status`, and errors report only source kind, path,
role, scope names, expiry, refresh-token presence, and principal; they never
report client secrets, authorization codes, access tokens, refresh tokens,
request authorization headers, or kinko values.

Safe kinko usage passes named environment variables to the process, for
example:

```bash
kinko exec --env DOCUMENT_GATEWAY_CREDENTIAL_DRIVE_READER_OAUTH_CLIENT_SECRET_JSON,DOCUMENT_GATEWAY_CREDENTIAL_DRIVE_READER_TOKEN_STORE_JSON -- \
  swift run google-drive-gateway-reader doctor --credential drive-reader
```

Documentation must show names and setup structure only, never example secret
values or commands that reveal them.

## CLI Contract

Every command supports `--help`. Bootstrap commands are common to both Drive
binaries but remain role-bound:

```text
config validate [--config PATH]
doctor --credential ID [--config PATH]
auth login --credential ID [--config PATH]
auth status --credential ID [--config PATH]
auth revoke --credential ID --confirm-credential ID [--config PATH]
```

`auth revoke` may remove only the resolved token store for the named
credential, refuses inline environment token JSON, and requires an exact
confirmation value.

### Reader commands

```text
files list [--query Q] [--drive-id ID] [--page-size N]
           [--page-token TOKEN] [--page-all]
           [--max-pages N] [--max-items N]
files get --file-id ID
files download --file-id ID --output PATH --max-bytes N [--overwrite]
files export --file-id ID --mime-type TYPE --output PATH
             --max-bytes N [--overwrite]
permissions list --file-id ID [--page-size N] [--page-token TOKEN]
                 [--page-all] [--max-pages N] [--max-items N]
permissions get --file-id ID --permission-id ID
```

`files list` requests a fixed metadata field allowlist and defaults to
`trashed = false`. User corpus is the default. Supplying `--drive-id` selects
only that shared drive with `corpora=drive`, `driveId`,
`includeItemsFromAllDrives=true`, and `supportsAllDrives=true`; the CLI never
implicitly scans the domain corpus. `incompleteSearch` is preserved in output
and sets `meta.truncated=true` with an actionable warning.

Page tokens are opaque and returned unchanged. `page-size` is validated in the
Drive range. Single-page mode is the default. `--page-all` is still bounded:
defaults are 10 pages and 1,000 items, caller values may lower or raise them
only within configured ceilings, and reaching either bound returns the last
token with `meta.truncated=true`. Repeated page tokens fail with
`PAGINATION_CYCLE`.

Downloads and exports stream to a temporary sibling file, enforce the required
`--max-bytes` against both headers and observed bytes, `fsync` where supported,
and atomically rename on success. Output must resolve below a configured
`allowed_download_roots` entry. Existing destinations are refused unless
`--overwrite` is explicit; failure removes only the command-owned temporary
file. Export MIME type is required, and the API's export-size limit is surfaced
as an actionable error. Binary content never enters JSON or stdout.

### Writer commands

```text
folders create --name NAME [--parent-id ID]
files upload --input PATH --name NAME [--parent-id ID] --mime-type TYPE
             --max-bytes N
files replace-content --file-id ID --input PATH --mime-type TYPE
                      --max-bytes N --expected-modified-time RFC3339
                      --confirm-file-id ID
files rename --file-id ID --name NAME --expected-modified-time RFC3339
             --confirm-file-id ID
files move --file-id ID --from-parent-id ID --to-parent-id ID
           --expected-modified-time RFC3339 --confirm-file-id ID
permissions create --file-id ID --type user|group|domain|anyone
                   --role reader|commenter|writer
                   [--email ADDRESS] [--domain DOMAIN]
                   [--acknowledge-broad-access]
permissions update --file-id ID --permission-id ID
                   --role reader|commenter|writer
                   --expected-role reader|commenter|writer
                   --confirm-permission-id ID
permissions delete --file-id ID --permission-id ID
                   --expected-role reader|commenter|writer
                   --confirm-permission-id ID
```

No writer command accepts raw resource JSON. Request builders encode path
segments and map typed arguments to allowlisted fields. Local inputs must be
regular files whose canonical path is under `allowed_upload_roots`; symlink
escapes, devices, directories, and files exceeding the explicit and configured
limits are rejected before network access. Uploads use resumable Drive uploads,
fixed-size chunks, status probing after interruptions, and a configured retry
budget. The resumable session URI is treated as a secret and never logged.

Existing-resource mutations require exact resource IDs, exact confirmation
echoes, and the caller's previously observed `modifiedTime`. A preflight get
must match that timestamp. Rename changes only `name`. Replace-content changes
only media and `mimeType`. Move also requires `from-parent-id` to be present and
sends only `addParents` and `removeParents`; any mismatch returns
`PRECONDITION_FAILED`. These preflights reduce stale-state accidents but are not
an atomic concurrency guarantee, which is stated in help and output metadata.

Permission rules are stricter than the underlying API:

- Creation permits only `reader`, `commenter`, or `writer`; ownership transfer,
  `pendingOwner`, organizers, and inherited-permission changes are unsupported.
- `user` and `group` require `--email`; `domain` requires `--domain`; `anyone`
  accepts neither. Conflicting identity fields are rejected locally.
- Domain sharing must match `allowed_share_domains` and requires
  `--acknowledge-broad-access`. Anyone sharing requires both
  `allow_anyone_permissions = true` in config and that acknowledgement.
- User/group notification email remains enabled. The first release exposes no
  option to suppress it.
- Update/delete preflight the permission, require its current role to match
  `--expected-role`, and reject owner, inherited, deleted, or unsupported roles.
  Exact permission-ID confirmation is mandatory.
- Permission mutations are never automatically retried because concurrent or
  duplicated permission operations can have non-idempotent effects.

File delete, trash, ownership transfer, and permission ownership changes have
no parser route, request model, or client protocol method in this feature.

## JSON and Exit Contract

Commands emit exactly one JSON document on stdout. Success uses:

```json
{
  "ok": true,
  "data": {},
  "meta": {
    "executable": "google-drive-gateway-reader",
    "operation": "files.list",
    "nextPageToken": null,
    "pagesFetched": 1,
    "itemsReturned": 0,
    "truncated": false
  }
}
```

Content-transfer success returns destination path, MIME type, byte count, and
Drive file ID in `data`, never payload bytes. Failure uses:

```json
{
  "ok": false,
  "error": {
    "code": "SCOPE_MISMATCH",
    "message": "The stored token is not valid for the Drive reader role.",
    "details": {},
    "retryable": false,
    "httpStatus": null
  }
}
```

Google error bodies are decoded into allowlisted fields (`code`, `message`,
`reason`, request correlation metadata) and size-bounded before inclusion.
HTML, token-bearing headers, full response bodies, resumable URLs, and secrets
are excluded. Exit categories are stable: `0` success (including a valid
bounded result with `meta.truncated=true`), `2` usage/validation, `3`
configuration, `4` authentication/authorization, `5` remote API, and `6`
local I/O.

## Architecture and Concurrency

The Drive feature extends shared SwiftPM infrastructure instead of duplicating
auth and HTTP stacks. Expected responsibility boundaries are:

```text
DriveReaderCLI / DriveWriterCLI
  -> role-specific command parser and dispatcher
  -> DriveReadService / DriveWriteService
  -> DriveReadClient / DriveWriteClient protocols
  -> shared authenticated GoogleTransport
  -> injected URLSession, clock, sleeper, file system, token store, browser
```

Drive API DTOs are typed `Codable`, `Sendable` value types. Shared mutable
token refresh and resumable-upload state is isolated behind actors. Client,
transport, clock, sleeper, file-system, and token-store dependencies are
protocol-injected and concurrency-safe. Mutable global request interceptors
are prohibited in production code; tests use isolated injected transports.
Swift files remain below 1,000 lines and are split by responsibility.

The transport retries bounded, idempotent reads for `429`, `500`, `502`, `503`,
and `504` using `Retry-After` when valid plus capped exponential backoff and
jitter. It does not automatically retry permission creation/update/delete,
rename, move, or content replacement. Upload recovery follows resumable upload
status semantics rather than replaying creation blindly.

## Configuration Validation

The Drive-specific configuration includes:

```toml
[drive]
allowed_download_roots = ["/absolute/export/root"]
allowed_upload_roots = ["/absolute/import/root"]
max_download_bytes = 104857600
max_upload_bytes = 104857600
max_auto_pages = 10
max_auto_items = 1000
allowed_share_domains = ["example.com"]
allow_anyone_permissions = false

[[credentials]]
id = "drive-reader"
service = "drive"
role = "reader"
oauth_client_secret_path = "/outside/repository/google-client.json"
token_store_path = "/outside/repository/drive-reader-token.json"
```

Validation rejects relative roots, overlapping credential token stores,
environment-suffix collisions, missing role/service pairs, non-positive or
unreasonably large limits, and configurations where output roots contain an
OAuth client or token path. Only the selected credential's files are opened;
one broken unused credential does not block an unrelated command.

## Shared-Drive Behavior

All compatible get/update/permission calls set `supportsAllDrives=true`.
Shared-drive permission inheritance is reported, not modified. Operations that
require organizer authority are left to Google authorization checks and return
actionable errors. The CLI never enables `useDomainAdminAccess`, never changes
shared-drive membership, and never broadens user corpus to domain corpus.

## Verification Strategy

Tests use Swift Testing and injected transports/filesystems. Required coverage:

- Command snapshots prove reader help/parser/dispatcher have no writer routes,
  and writer help contains only the allowlisted Drive mutations.
- Role/scope tables cover exact match, missing scope, broad `drive` scope,
  write scope in reader, read scope in writer, imported token without scope,
  refresh response mismatch, and unrelated identity scopes.
- Request tests assert HTTP method, percent-encoded path, allowlisted query/body
  fields, shared-drive flags, page token propagation, field projection, and
  absence of delete/trash/ownership parameters.
- Pagination tests cover single page, bounded aggregation, cycle detection,
  incomplete search, max-item truncation, and continuation-token preservation.
- File tests cover root confinement, symlink escape, existing output refusal,
  atomic replacement, cleanup after failure, declared/observed byte limits,
  resumable status recovery, and no stdout payload bytes.
- Permission tests cover identity/role validation, domain/anyone acknowledgement,
  inherited and owner refusal, notification behavior, exact-ID confirmation,
  and no mutation retry.
- Doctor/error tests prove secret redaction and actionable Google API mapping.
- Representative Drive file, file-list, permission, error, upload-session, and
  export/download metadata models decode under Swift 6 strict concurrency.

Repository verification after implementation:

```bash
mise run lint
swift test
swift build
swift run google-drive-gateway-reader --help
swift run google-drive-gateway-writer --help
swift run google-drive-gateway-reader doctor --credential drive-reader --config /path/to/public-safe-config.toml
swift run google-drive-gateway-writer doctor --credential drive-writer --config /path/to/public-safe-config.toml
git diff --check
```

The two `doctor` commands are optional live/config checks and must use local
credential references without printing secret values. Unit and integration
tests may not require live Google credentials.

## Acceptance Criteria

- Both Drive executables build and expose only their role-appropriate commands.
- Reader dispatch cannot construct a mutation; writer authentication requires
  `drive.file` and rejects broader Drive authority.
- OAuth login, status, revoke, and doctor follow the mail-gateway conventions
  while enforcing the stronger scope checks above.
- Metadata/content reads and all list operations are bounded and paginated.
- Upload, replacement, rename, move, and permission operations implement every
  stated path, size, identity, role, and confirmation safeguard.
- Every command returns the structured JSON/exit contract and actionable,
  redacted errors.
- Tests cover command boundaries, scope validation, request construction,
  pagination, local-file safety, destructive-operation safety, and representative
  API models.
- README, this design, and the implementation plan accurately describe setup,
  `drive.file` limitations, kinko-safe configuration, and security boundaries.
- `mise run lint`, `swift test`, `swift build`, executable help checks, and
  `git diff --check` pass without secrets, commits, or pushes.

## Design Review Record

### Self-review

**Decision**: Accepted after revision. The review added exact scope-set rules,
bounded auto-pagination, download/upload root confinement, shared-drive query
rules, permission escalation safeguards, compile-time client separation, and
explicit non-goals for delete/trash/ownership transfer.

### Independent review

**Decision**: Accepted after revision. The independent pass found and resolved:

- **High — writer least privilege was ambiguous**: fixed `drive.file` as the
  only accepted Drive writer scope and documented its app-authorized-file limit.
- **High — permission changes could escalate or become public accidentally**:
  excluded ownership paths, added allowlisted domains/config gating, exact-ID
  confirmation, preflight rejection, and notification requirements.
- **High — existing-resource mutation could act on stale caller state**: made
  observed file modification time and permission role mandatory preconditions.
- **Medium — content transfer and auto-pagination lacked hard ceilings**: made
  byte limits explicit and added configured page/item ceilings and cycle checks.
- **Medium — shared-drive listing could silently scan too broadly**: specified
  explicit drive corpus selection and `incompleteSearch` reporting.
- **Medium — partial-result exit behavior was ambiguous**: defined bounded,
  truncated results as successful JSON with explicit continuation metadata.

No unresolved high- or medium-severity design findings remain.
