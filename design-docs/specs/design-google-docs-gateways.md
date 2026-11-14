# Permission-Separated Google Docs Gateways

> Historical initial-design record. The additive API coverage expansion is
> specified in `api-coverage.md`, which supersedes this document where the
> supported batch request set differs.

> Implementation reconciliation (2026-08-13): this file preserves the
> pre-implementation design and review record. The delivered shared module is
> named `AppCore`; it uses lossless structured provider JSON rather than an
> exhaustive Docs DTO graph, and does not add generic automatic GET retries.
> The completed implementation and verification record is
> `impl-plans/active/google-docs-gateways.md`.

**Status**: Accepted
**Feature ID**: `google-docs-gateways`
**Workflow Mode**: `issue-resolution`
**Issue Reference**: `workflow-input: Implement permission-separated Google Docs Sheets and Drive gateway clients`

## Summary

This feature adds two Swift 6 command-line executables for Google Docs:

- `google-docs-gateway-reader` retrieves document content with the exact
  `documents.readonly` OAuth scope.
- `google-docs-gateway-writer` creates documents and submits batch updates with
  the exact write-capable `documents` OAuth scope.

Each binary is bound at construction time to one role. The reader command tree
cannot represent mutations, and neither binary accepts a credential or token
for the other role. Shared authentication, configuration, HTTP transport,
structured JSON, errors, and dependency-injection facilities are integration
dependencies supplied by the package-level implementation; this feature owns
only Docs-specific policy, commands, requests, models, tests, and documentation.

Sheets, Drive, and their four executables belong to sibling fanout features and
are not specified by this design.

## Context and References

Codex-agent references used by this feature:

- [`../mail-gateway`](../../../mail-gateway): shared-core/thin-executable
  structure, installed-app OAuth with loopback callback and PKCE, per-profile
  token stores, configuration overrides, `auth status`, `doctor`, structured
  command results, stable exit codes, redaction, and request-protocol tests.
- [`googleworkspace/cli`](https://github.com/googleworkspace/cli):
  service/resource command naming, JSON request bodies, machine-readable output,
  setup guidance, and actionable Google API errors.
- [Google Docs scope definitions](https://developers.google.com/workspace/docs/api/auth),
  [documents.get](https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/get),
  [documents.create](https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/create),
  and [documents.batchUpdate](https://developers.google.com/workspace/docs/api/reference/rest/v1/documents/batchUpdate):
  authoritative scope, parameter, request, and response contracts.

The external CLI informs conventions; this package does not invoke or depend on
it.

## Goals

- Ship `google-docs-gateway-reader` and `google-docs-gateway-writer` from the
  Swift package.
- Make the role boundary explicit in executable names, help, parsing,
  credential selection, actual token grants, dispatch, and tests.
- Retrieve complete single-tab and multi-tab Docs documents.
- Create documents and apply representative Docs API batch updates.
- Return one stable structured JSON envelope on success and one actionable,
  redacted structured JSON error on failure.
- Integrate with shared OAuth bootstrap, doctor, transport, and test seams using
  Swift 6 concurrency-safe contracts.
- Keep every Swift source file below 1000 lines.

## Non-Goals

- Sheets, Drive, or a combined cross-service token.
- A generic Google Discovery API passthrough.
- Google Drive folder placement, file listing, export, permissions, or sharing.
- Docs comments, suggestions mutation, revision history, or merge workflows.
- Service accounts, domain-wide delegation, device-code auth, daemon mode, or a
  visual document editor.
- Committing, pushing, or storing credentials in the repository.

## Product Surface

### Capability and Scope Matrix

| Executable | Business commands | Exact OAuth scope |
|---|---|---|
| `google-docs-gateway-reader` | `document get` | `https://www.googleapis.com/auth/documents.readonly` |
| `google-docs-gateway-writer` | `document create`, `document batch-update` | `https://www.googleapis.com/auth/documents` |

Both binaries also expose the common operational surface required by the shared
core:

```text
--help
--version
config validate
auth login --credential <id>
auth status --credential <id>
auth revoke --credential <id>
doctor [--credential <id>] [--online]
```

The writer OAuth scope can read Docs at the provider level, but the writer CLI
intentionally omits reader business commands. A caller that needs both roles
uses distinct profiles/token stores and invokes both executables.

### Commands

#### `document get`

```bash
google-docs-gateway-reader document get \
  --document-id DOC_ID \
  --include-tabs-content true \
  [--suggestions-view-mode DEFAULT_FOR_CURRENT_ACCESS]
```

- `--document-id` is required.
- `--include-tabs-content` accepts `true|false` and defaults to `true` so
  multi-tab content is not silently omitted.
- With `true`, the returned Docs resource uses the API's `tabs` tree; callers
  must traverse nested child tabs. Legacy top-level body/header/footer fields
  are not treated as the complete document representation.
- With `false`, the API's legacy first-tab fields are returned as provided. This
  opt-out exists for compatibility and is called out in help.
- `--suggestions-view-mode`, when supplied, is validated against the stable Docs
  enum and encoded as `suggestionsViewMode`.

#### `document create`

```bash
google-docs-gateway-writer document create \
  --json '{"title":"Runbook"}'
```

- Accepts exactly one of `--json <object>` or `--json-file <path|->`.
- The request must contain a non-empty `title`; unsupported top-level fields are
  rejected for this closed request model.
- Returns the created Docs `Document` resource. Folder placement is omitted
  because that is a Drive concern.

#### `document batch-update`

```bash
google-docs-gateway-writer document batch-update \
  --document-id DOC_ID \
  --json-file ./batch-update.json
```

- `--document-id` and one body source are required.
- The body must contain a non-empty `requests` array and may contain
  `writeControl`.
- Requests are sent in order. The gateway validates the supported JSON shape,
  size, and required discriminators but leaves document indices and operation
  semantics to the Docs API.
- The initial implementation supports representative request variants needed to
  prove the contract: insert text, delete content range, replace all text, update
  text style, insert table, and update document style. Unknown request variants
  fail locally with `INVALID_ARGUMENT`; adding variants is additive.
- The response preserves ordered replies and `writeControl`.

### Input Rules

- Resource identifiers use named flags and are percent-encoded as path
  components rather than interpolated directly.
- Body input accepts exactly one of `--json` or `--json-file`; `--json-file -`
  reads standard input.
- JSON body bytes are size-limited before decoding and never echoed in errors.
- Boolean flags require explicit `true` or `false`.
- Help and parse failures require no configuration, token, or network access.

## Architecture

### Owned SwiftPM Surface

This feature contributes the following logical files/targets; exact splits may
follow nearby repository conventions while retaining these responsibilities:

```text
Sources/
  DocumentGatewayCore/
    Docs/DocsCommands.swift
    Docs/DocsAPIModels.swift
    Docs/DocsRequestBuilder.swift
    Docs/DocsService.swift
    Docs/DocsScopePolicy.swift
  GoogleDocsGatewayReader/main.swift
  GoogleDocsGatewayWriter/main.swift
Tests/
  DocumentGatewayCoreTests/
    DocsCommandBoundaryTests.swift
    DocsRequestBuilderTests.swift
    DocsAPIModelTests.swift
    DocsScopePolicyTests.swift
```

`Package.swift` exposes the two executable products and their targets. Each
`main.swift` is a thin adapter that passes an immutable `GatewayMode` into the
shared CLI; no runtime flag can change role or service.

```swift
enum GatewayRole: String, Codable, Sendable { case reader, writer }

struct DocsGatewayMode: Equatable, Sendable {
  let role: GatewayRole
  let executableName: String
  let requiredScopes: Set<String>
}
```

The shared package contract must provide service identity as `docs`, config and
credential selection, OAuth bootstrap/refresh, structured CLI results, HTTP
transport, correlation IDs, JSON loading, and errors. This feature consumes
those interfaces and must not duplicate them. If a sibling feature lands first,
Docs adapts to the accepted shared names without weakening its role or scope
rules.

### Testable Dependencies and Concurrency

Docs services depend on shared `Sendable` abstractions equivalent to:

```swift
protocol HTTPTransport: Sendable {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

protocol OAuthGrantValidating: Sendable {
  func validateGrant(for token: OAuthToken) async throws -> VerifiedGrant
}
```

Production uses the shared `URLSession` transport. Tests inject actor-isolated
capture transports and grant validators. DTOs are immutable `Sendable` values;
mutable shared state is isolated in actors. Unchecked sendability is restricted
to small lock-protected platform wrappers and justified inline.

### Docs Request and Model Strategy

- `DocsRequestBuilder` owns base URL, safe path/query encoding, authorization,
  content type, user agent, timeout, and request body encoding.
- GET may retry boundedly on transport failures, 429, and retryable 5xx status.
- Create and batch update are not automatically retried because replay can
  duplicate or reorder mutations.
- `Retry-After` and Google request identifiers are captured by the shared
  transport/error layer.
- Success output preserves the complete, size-bounded provider JSON tree as the
  envelope's `data`; it is never produced by re-encoding a partial DTO. Typed
  projections decode document identity/title, tabs and nested tabs, structural
  elements, text runs, batch replies, and write control only for validation and
  internal access. This keeps unmodeled and future document/reply fields intact.
- Request discriminators are explicit enums rather than unchecked string maps.
  A shared lossless `JSONValue` represents provider responses and preserves
  object keys, arrays, scalar values, and nulls through output serialization.

## Authentication and Authorization

### Google Cloud Prerequisites

Before `auth login`, the operator must:

1. Select or create a Google Cloud project.
2. Enable the Google Docs API (`docs.googleapis.com`).
3. Configure the OAuth consent screen/branding, audience, and publishing status.
4. Add the authorizing account as a test user when the app is in testing mode.
5. Declare only the role scope used by the selected binary:
   `documents.readonly` for reader or `documents` for writer.
6. Create and download an OAuth 2.0 client of type **Desktop app**.
7. Store the client file and token-store destination outside the repository with
   user-only permissions, or inject them through kinko without exposing values.

Both Docs scopes are classified by Google as sensitive. Public applications may
need OAuth verification; local testing can show an unverified-app warning and is
subject to Google test-user and publishing restrictions.

`config validate` checks local configuration and desktop-client shape without a
network call. `doctor` reports consent/test-user limitations as setup guidance,
recognizes Google's `accessNotConfigured` response, and returns a safe Docs API
enable URL. It cannot determine Cloud Console consent configuration locally.
`doctor --online` performs a read-only provider probe only after token grant
validation and never mutates a document.

### Configuration

Default configuration is `$XDG_CONFIG_HOME/document-gateway/config.toml`, with
`--config` and `DOCUMENT_GATEWAY_CONFIG` overrides:

```toml
[[credentials]]
id = "docs-reader-personal"
service = "docs"
role = "reader"
oauth_client_secret_path = "/private/path/google-desktop-client.json"
token_store_path = "/private/path/tokens/docs-reader.json"

[[credentials]]
id = "docs-writer-personal"
service = "docs"
role = "writer"
oauth_client_secret_path = "/private/path/google-desktop-client.json"
token_store_path = "/private/path/tokens/docs-writer.json"
```

Following the sibling convention, these values may be overridden by:

```text
DOCUMENT_GATEWAY_CREDENTIAL_<NORMALIZED_ID>_OAUTH_CLIENT_SECRET_PATH
DOCUMENT_GATEWAY_CREDENTIAL_<NORMALIZED_ID>_OAUTH_CLIENT_SECRET_JSON
DOCUMENT_GATEWAY_CREDENTIAL_<NORMALIZED_ID>_TOKEN_STORE_PATH
DOCUMENT_GATEWAY_CREDENTIAL_<NORMALIZED_ID>_TOKEN_STORE_JSON
```

Environment values take precedence over TOML. Documentation names variables but
never prints values. A selected profile must match service `docs` and the
invoking binary role before token loading. Profile IDs and normalized environment
suffixes are unique, and reader/writer profiles use distinct token-store paths.

### OAuth Bootstrap

`auth login` follows the sibling installed-app flow:

1. Load an `installed` Desktop-app client JSON.
2. Select the exact scope from compiled Docs role policy; configuration and CLI
   flags cannot supply or broaden scopes.
3. Generate state plus PKCE verifier/challenge with secure randomness.
4. Bind an ephemeral `127.0.0.1` callback by default. Explicit redirects must be
   HTTP loopback URLs with an explicit port.
5. Open the browser unless disabled, then wait with a bounded timeout.
6. Verify callback state and exchange the code.
7. Read the authoritative `scope` grant in the token response and require exact
   equality with role policy before saving.
8. Require a refresh token for a newly created profile; if Google omits it,
   leave any existing valid store untouched and return an actionable auth error.
9. Persist the token store atomically with user-only permissions and return only
   redacted metadata.

The authorization URL sets `access_type=offline` and `prompt=consent`, matching
the sibling's deliberate re-consent policy so a new login can return a refresh
token. It sets `include_granted_scopes=false` explicitly: incremental
authorization could combine previous grants and violate exact role scope. Tests
assert these parameters, URL encoding, a successful refresh-token response, and
the non-destructive failure path when a refresh token is absent.

The token store records schema version, profile ID, service, role, exact
normalized verified scopes, token type, expiry, refresh-token presence, and
token values. Access and refresh token values never appear in output or errors.

### Actual Grant Enforcement

Scope enforcement occurs at independent boundaries:

1. The executable supplies immutable Docs reader/writer mode.
2. The parser registers only that mode's commands.
3. The credential profile and token-store identity must match service and role.
4. A CLI-created token must carry the exact grant verified from Google's token
   exchange. A refresh response with a `scope` value must match; if omitted, the
   last authoritative verified grant is retained.
5. Imported or environment-injected token material is untrusted until an online
   Google OAuth grant-inspection call verifies audience, expiry, and actual
   scopes before the first Docs request. Access tokens are sent only to Google's
   HTTPS OAuth endpoint, using a non-logging request path; tokens never appear in
   URLs, diagnostics, captured test descriptions, or retry logs.

An exact comparison is deliberate. A writer token is rejected by the reader
even if Google would permit the read. Missing, extra, unavailable, or changed
scope grants produce `AUTH_SCOPE_MISMATCH` and direct the operator to re-run
`auth login` with the correct binary/profile. If an imported token cannot be
authoritatively inspected, provider operations fail closed with `AUTH_REQUIRED`;
local `auth status` reports `UNKNOWN` rather than `READY`.

### Auth Status and Doctor

`auth status` is local and reports profile ID, configured service/role, token
state (`MISSING`, `READY`, `EXPIRED`, `SCOPE_MISMATCH`, `INVALID`, `UNKNOWN`),
expiry, refresh-token presence, and redacted scope identifiers. For imported
tokens it reports `UNKNOWN` until online grant inspection succeeds; it never
claims online validity from editable metadata alone.

`doctor` checks configuration resolution, Desktop-app client shape, file
permissions, token decodeability, service/role/scope metadata agreement, refresh
readiness, and secret redaction. `doctor --online` additionally performs actual
grant inspection and a read-only Docs API reachability probe. Both return a JSON
check list and distinct CLI/config/auth/provider exit codes.

## Structured JSON and Errors

Every business success writes exactly one JSON object plus a newline to stdout:

```json
{
  "ok": true,
  "service": "docs",
  "role": "reader",
  "operation": "document.get",
  "data": {},
  "requestId": "local-correlation-id"
}
```

Failures write no success output and one JSON object plus a newline to stderr:

```json
{
  "ok": false,
  "error": {
    "code": "AUTH_SCOPE_MISMATCH",
    "message": "Stored token does not match Docs reader scope policy",
    "details": {"credentialId": "docs-reader-personal"},
    "provider": {"status": 403, "reason": "insufficientPermissions"},
    "retryable": false
  },
  "requestId": "local-correlation-id"
}
```

Stable codes include `INVALID_ARGUMENT`, `CONFIG_INVALID`,
`CREDENTIAL_NOT_FOUND`, `CREDENTIAL_ROLE_MISMATCH`, `AUTH_REQUIRED`,
`AUTH_SCOPE_MISMATCH`, `AUTH_CALLBACK_FAILED`, `PROVIDER_API_ERROR`,
`PROVIDER_RATE_LIMITED`, and `UNEXPECTED_ERROR`.

Provider parsing retains safe HTTP status, Google status/reason, message,
request identifier, and API-enable URL when present. It excludes authorization
headers, document request/response bodies, OAuth response bodies, token strings,
client-secret content, and kinko values.

Exit codes follow the sibling convention: `0` success, `1` general error, `2`
invalid CLI use, `3` configuration error, `4` authentication/bootstrap error,
`5` local operation error, and `6` provider API error.

## Security Constraints

- Reader executable code registers no create or batch-update route.
- Writer executable never accepts a reader profile/token as a fallback.
- Docs scope policy is compiled code, not user configuration.
- Help, validation, status, and offline doctor issue no Docs API requests.
- Client and token files stay outside version control and use `0600` permissions
  where supported; token writes are atomic and do not follow symlinks.
- Body input is size-bounded and never echoed in error details.
- Logs and JSON never include OAuth secrets, document bodies, or kinko values.
- Create and batch-update transport is not automatically retried.

## Testing Strategy

- Assert the exact command tree for both binaries and verify every writer verb is
  rejected by the reader before credential load or transport access.
- Assert exact role scopes, profile selection, missing/extra scope rejection,
  writer-token rejection in reader, verified-vs-imported token states, online
  grant inspection, refresh scope preservation, and changed-grant rejection.
- Test OAuth URL/PKCE construction, offline/consent/non-incremental parameters,
  missing-refresh-token non-destructive failure, state validation, Desktop-app
  client parsing, token-store permissions, revoke, redaction, status, and doctor
  outcomes using fakes only.
- Test `document get` request encoding and response decoding for a legacy
  single-tab response, a `tabs`-based single-tab response, and nested multi-tab
  documents. Assert `includeTabsContent=true` is the default request and that
  unmodeled fields in documents, nested tabs, replies, and write control survive
  unchanged in output.
- Test create and every supported batch request variant, ordered requests and
  replies, write control, percent encoding, malformed/oversized JSON, and API
  error decoding with an injected capture transport.
- Assert GET retry behavior and that create/batch-update never auto-retry.
- Snapshot or structurally assert help plus success/error JSON contracts.

No automated test requires live credentials. Optional live smoke tests are
manual, opt-in, use dedicated non-production documents, and never print secrets.

## Package Integration and Documentation

- `Package.swift` adds the two Docs executable products/targets and connects them
  to the shared core.
- `README.md`, `design-docs/specs/architecture.md`, and
  `design-docs/specs/command.md` gain Docs setup, commands, scope boundaries,
  multi-tab behavior, kinko-safe examples, and troubleshooting.
- `mise.toml` gains Docs run/help tasks without embedded secrets.
- Package-level Homebrew work must include the two Docs binaries; changes to
  cross-service packaging remain coordinated shared work, not this design's
  ownership.

## Verification and Acceptance

The Docs feature is accepted only when these commands pass:

```bash
mise run lint
mise run test
mise run build
swift run google-docs-gateway-reader --help
swift run google-docs-gateway-writer --help
```

Acceptance also requires:

- Both Docs executables build and expose only their declared business commands.
- Reader mutation attempts fail locally with no credential or network access.
- Reader and writer request and authoritatively verify their exact scopes.
- Docs operations return structured JSON and actionable redacted errors.
- Tests cover command boundaries, scope/grant validation, request construction,
  representative Docs models, multi-tab retrieval, OAuth/status/doctor, and
  mutation retry policy.
- Documentation accurately describes setup, role boundaries, exact scopes, and
  the imported-token fail-closed policy.
- No secret is printed, committed, embedded, or needed for verification.
- No commit or push occurs in this issue-resolution workflow.

## Risks and Mitigations

- **Multi-tab omissions**: request `includeTabsContent=true` by default, document
  the tabs tree, and cover nested tabs in model/request tests.
- **Forged or stale imported token metadata**: never trust editable scope labels;
  inspect actual grants online before provider use and fail closed if unknown.
- **Broad batch-update schema**: support an explicit representative variant set,
  reject unknown variants locally, and expand additively with focused tests.
- **Shared-core integration drift**: keep Docs policy and adapters isolated,
  consume accepted shared protocols, and test behavior rather than concrete
  sibling implementation names.
- **Sensitive-scope setup failures**: document API enablement, consent audience,
  test users, verification status, and actionable `accessNotConfigured` errors.
- **Swift 6 isolation regressions**: use immutable `Sendable` DTOs, actor-isolated
  mutable fakes/stores, and compile in Swift 6 language mode from the start.

## Open Decisions

None for this bounded Docs feature. Drive placement, broader batch request
variants, comments, service accounts, and combined credentials require separate
design approval.
