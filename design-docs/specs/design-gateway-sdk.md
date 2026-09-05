# Design: command catalog and GoogleDocumentsGatewaySDK on GatewaySDKKit

Status: reconciled to issue-resolution intake `comm-001539` and every unresolved high/mid
finding carried forward into workflow session 118 (2026-09-06). Contract:
`design-docs/briefs/gateway-sdk-2026-09-04.md` (ONE feature). Issue reference:
"Add GoogleDocumentsGatewaySDK and command catalog on GatewaySDKKit" on `feat/gateway-sdk`
in this worktree; no remote issue number or URL was supplied.
Kit reference (read-only): `/Users/taco/gits/tacogips/gateway-sdk-kit` (product `GatewaySDKKit`, Swift 6, macOS 14).

## 1. Scope and non-goals

Add, inside `GoogleDocumentsGatewayCore`: a declared command catalog per role, a
`GoogleDocumentsGatewaySDK` facade conforming to the kit's `GatewaySDK` protocol, and three
new CLI subcommands (`schema print`, `schema search`, `operation run`) reachable from all six
role binaries. No GraphQL layer, no changes to provider request semantics, OAuth protocol,
packaging, or any existing subcommand's output. The SDK execution wrapper adds bounded,
cancellable transport and local-file behavior without changing direct-CLI behavior. Tier
enforcement stays in `GatewayCommandRunner`
(`FORBIDDEN_COMMAND` gate); the catalog is additionally scoped per role so the SDK never
widens a tier.

This repository introduces no Cursor adapter; external adapters consume only the public
`GoogleDocumentsGatewaySDK` facade, and Riela integration remains out of scope for this phase.

The normative risk classification is intentionally broad: every remotely mutating or
non-idempotent operation is destructive. After such a request crosses the provider-dispatch
boundary, no local timeout, cancellation, transport, response-limit, status-validation, or
decoding failure may imply that retry is safe. All such failures return non-retryable
`OUTCOME_UNKNOWN`. Read-only operations remain retryable `TRANSPORT_FAILURE` where appropriate.

## 2. Package dependency

`Package.swift` gains:

- `.package(path: "../../gateway-sdk-kit")` — one-line comment that the operator switches
  this to a URL pin later.
- product `"GatewaySDKKit"` (package `gateway-sdk-kit`) on target `GoogleDocumentsGatewayCore`
  and on `GoogleDocumentsGatewayCoreTests` (tests import the kit types directly).

The kit is dependency-free, so `Package.resolved` gains no remote pins.

## 3. File layout (all new files under `Sources/GoogleDocumentsGatewayCore/SDK/`)

| File | Contents |
|---|---|
| `GoogleDocumentsCommandCatalog.swift` | `extension GatewaySchemaCatalog { public static func googleDocuments(role: GatewayRole) -> GatewaySchemaCatalog }`, tier/domain helpers, role-neutral operations, shared enum `GatewayNamedType`s, small argument-declaration helpers |
| `GoogleDocumentsCommandCatalog+Docs.swift` | docs read/write operation declarations |
| `GoogleDocumentsCommandCatalog+Sheets.swift` | sheets read/write operation declarations |
| `GoogleDocumentsCommandCatalog+DriveRead.swift` | drive read operation declarations |
| `GoogleDocumentsCommandCatalog+DriveWrite.swift` | drive write operation declarations |
| `GoogleDocumentsGatewaySDK.swift` | the facade |
| `GatewaySDKCommandRouter.swift` | CLI subcommand handling for `schema print` / `schema search` / `operation run` |
| `GatewaySDKExecutionSupport.swift` | cancellation, bounded-worker limiter, execution-policy normalization, response-limited transport, and remote-dispatch disposition |
| `GatewaySDKFileAccessPolicy.swift` | explicit input/output capabilities and output commit behavior |
| `GatewaySDKCatalogFileSnapshots.swift` | descriptor-relative authorization, inode-bound reads, and private snapshot lifecycle |
| `GatewaySDKCredentialLoading.swift` | inline-only call-environment credential decoding and constructor-profile loading |
| `GatewayCommandFlagInventory.swift` | the per-command allowed-options table extracted verbatim from `GatewayCLI.swift:134-202` as `internal enum GatewayCommandFlagInventory { static let allowedOptions: [String: Set<String>] }` so `validate(command:options:)` and the parity tests read one source of truth (pure refactor; behavior identical) |

`GatewayCLI.swift` changes are minimal: (a) `validate` reads the extracted inventory, (b) a
single interception call into `GatewaySDKCommandRouter` after the `--help` / `--version`
checks and before `ParsedArguments`, (c) the usage string appends one `SDK:` line listing the
new subcommands (the brief requires `--help` to list them).

## 4. Catalog

### 4.1 Root fields

`GatewaySchemaCatalog(provider: "google-documents-gateway", tier: "<service>-<read|write>",
operations: ..., types: ...)`. Tier is `"\(role.service.rawValue)-\(role.accessMode.rawValue)"`
("docs-read" ... "drive-write") per the brief. Note this deliberately differs from
`GatewayRole.identifier` ("docs-reader" style); do not reuse `identifier` for the tier.

`types` is role-scoped just like `operations`: include exactly the non-built-in named types
referenced by that role catalog's arguments, with transitive dependencies if a future input
object is added. Concretely, `docs-read` carries `SuggestionsViewMode`; `sheets-write`
carries `MajorDimension` and `ValueInputOption`; `drive-write` carries `PermissionType` and
`PermissionRole`; and the other three catalogs have no custom types. Schema print/search
must not reveal unrelated service or role enums.

### 4.2 Operations

One `GatewayOperation(kind: .command)` per command in
`GatewayCapabilityCatalog.commands(for: role)` (docs 1+2, sheets 7+10, drive 18+19 = 57),
plus role-neutral `config validate`, `auth status`, `doctor` (each with one optional
`credential: String`) in every role catalog. `auth login` / `auth revoke` are excluded on
purpose (no SDK-driven interactive auth). `name` = the command string ("values get"), `tier` =
the catalog tier, `domain` = `role.service.rawValue`, `result` = nil (commands return opaque
JSON; the kit's SDL prints them under `type Command`), `summary` one line, and
`isDestructive` true for every remotely mutating or non-idempotent operation. One shared
operation-risk inventory drives this metadata and post-dispatch remote-outcome uncertainty:
create, update, clear, copy, upload, replace, move, rename, trash/untrash/delete, permission,
comment/reply, and revision mutations are all approval-gated. Local download/export output is a
separate filesystem-capability side effect, not a remote destructive catalog operation.

### 4.3 Argument typing rules (traceable to runtime evidence)

Source of truth for flag NAMES per role-gated capability command:
`GatewayCommandFlagInventory.allowedOptions` (ex-`GatewayCLI.swift:134-202`). For each such
command, every declared argument name, including `dry-run`, must equal that command's allowlist
entry in both directions. `dry-run` is optional `Boolean` only on role-gated capability commands
so SDK callers can plan them without credentials. This is the normative resolution of the
earlier public-catalog contradiction: "every command" means every role-gated capability
command, not the role-neutral trio. The role-neutral `config validate`, `auth status`, and
`doctor` declarations expose exactly optional `credential: String`; they do not declare
`dry-run` or any other argument.

- `Boolean` ONLY for the parser's bare flags (`ParsedArguments`, GatewayCLI.swift:734-738):
  `dry-run`, `overwrite`, `page-all`, `online`, `acknowledge-broad-access`,
  `acknowledge-permanent-delete`, `confirm-clear`, `keep-forever`, `publish`. The kit's
  `GatewayArgvBuilder` renders `.bool(true)` as a bare `--flag` and omits `false`/`null`,
  matching the parser exactly. Any value-taking flag typed `Boolean` would emit a bare flag
  the parser rejects ("Missing value") — this is the single most dangerous typing mistake.
- `include-tabs-content` takes a value validated to "true"/"false" by the builder
  (GatewayRequestBuilder.swift:29-31) → type `String`, description "true|false".
- `Int` for `page-size` (1...1000), `max-pages` (1...100), `max-bytes` (>= 0), `sheet-id`,
  `metadata-id`. `max-bytes` is non-negative for downloads and is additionally capped at
  `67108864` for `files upload` / `files replace-content`, matching
  `GatewayInputValidator.maximumDriveUploadBytes`. Constraints go in the description.
- `[String]` only for `range` on `values batch-get` — the sole flag the runtime reads as a
  collection (`options["range"] ?? []`, GatewayRequestBuilder.swift:88). Everywhere else the
  runtime reads `.last`, so everything else is scalar.
- `JSON` for inline-JSON flags only: `--json` (docs create/batch-update) and `--json-values`
  (values append/update). The argv builder renders object/array values as compact JSON text,
  which is exactly what the parser expects as the flag value.
- `--input-file` and `--input` are file PATHS read by the runtime → type `String`. The brief's
  "batch-update request bodies" arrive via these path flags; declaring them `JSON` would be
  wrong (resolved analysis question).
- Enum named types ONLY where the runtime enforces values: `SuggestionsViewMode`
  (DEFAULT_FOR_CURRENT_ACCESS|SUGGESTIONS_INLINE|PREVIEW_SUGGESTIONS_ACCEPTED|
  PREVIEW_WITHOUT_SUGGESTIONS), `MajorDimension` (ROWS|COLUMNS), `ValueInputOption`
  (RAW|USER_ENTERED), `PermissionType` (user|group|domain|anyone), and `PermissionRole`
  (reader|commenter|writer, used only by `role`). `expected-role` stays `String`: the runner
  compares it to observed provider state but does not restrict it to the three writable
  roles. Other flags the runtime passes through unvalidated, such as `action`, stay `String`
  with Google's accepted values in the description, so the SDK is never stricter than the
  CLI.
- Everything else is `String`.

### 4.4 Required-ness per command

Every unconditional requirement uses both `isRequired: true` and an outer
`.nonNull(baseType)` `GatewayTypeRef`. This keeps kit binding validation and printed SDL in
agreement because `GatewaySDLPrinter` renders requiredness from the type reference, not from
`isRequired`. Optional and conditionally required arguments use `isRequired: false` and a
nullable outer type. These markings mirror the runtime's unconditional requirements
(validators at GatewayCLI.swift:216-390 plus builder `required(...)` calls). Cross-flag rules
that the kit model cannot express (exactly-one-of, at-least-one-of, dry-run-skipped confirm
equality) remain optional with the rule spelled out in each description.

Docs read — `document get`: document-id req; include-tabs-content, suggestions-view-mode opt.
Docs write — `document create`: title/json/json-file all opt, "exactly one of" in descriptions;
`document batch-update`: document-id req; text/json/json-file exactly-one-of, opt.

Sheets read — `spreadsheet get`: spreadsheet-id req. `spreadsheet get-by-data-filter`,
`values batch-get-by-data-filter`, `developer-metadata search`: spreadsheet-id + input-file
req. `values get`: spreadsheet-id + range req. `values batch-get`: spreadsheet-id req, range
req `[String]` (repeatable, outer non-null, description requires at least one value; the
runner rejects an omitted or empty list).
`developer-metadata get`: spreadsheet-id + metadata-id req.
Sheets write — `spreadsheet create`: title req. `spreadsheet batch-update`: spreadsheet-id
and input-file req; confirm-spreadsheet-id optional in the catalog but required to equal
spreadsheet-id when dry-run is absent. `sheet copy-to`: spreadsheet-id, sheet-id,
destination-spreadsheet-id req.
`values append`/`values update`: spreadsheet-id + range req; values/json-values/input-file
exactly-one-of; major-dimension (only with values/json-values), value-input-option opt enums.
`values clear`: spreadsheet-id and range req; confirm-range optional in the catalog but
required to equal range when dry-run is absent. `values batch-update` /
`values batch-update-by-data-filter`: spreadsheet-id +
input-file req, value-input-option opt. `values batch-clear` /
`values batch-clear-by-data-filter`: spreadsheet-id + input-file req; confirm-clear
(Boolean) optional in the catalog but required when dry-run is absent.

Drive read — `about get`: none. `changes start-token`: drive-id opt. `changes list`:
page-token req; page-size, page-all, max-pages, drive-id opt. `shared-drives list` /
`files list`: query, page-size, page-token, page-all, max-pages (+ drive-id for files list)
opt. `shared-drives get`: drive-id req. `files get`: file-id req. `files download`: file-id,
output (must not already exist unless overwrite), max-bytes req; overwrite opt.
`files export`: file-id, mime-type, output, max-bytes req; overwrite opt. `permissions get`:
file-id + permission-id req. `comments get`: file-id + comment-id req. `replies get`:
file-id + comment-id + reply-id req. `revisions get`: file-id + revision-id req.
`revisions download`: file-id, revision-id, output, max-bytes req; overwrite opt. list
commands (`permissions|comments|replies|revisions list`): file-id req (+ comment-id for
replies), paging flags opt.
Drive write — `folders create`: name req; parent-id opt. `files upload`: input + max-bytes
req; name, parent-id, mime-type opt. `files copy`: file-id + confirm-file-id (equal) req;
name, parent-id opt. `files replace-content`: file-id, confirm-file-id,
expected-modified-time, input, max-bytes req. `files rename`: file-id, confirm-file-id,
expected-modified-time, name req. `files move`: file-id, confirm-file-id,
expected-modified-time req; add-parents/remove-parents at-least-one-of, opt. `files trash` /
`files untrash`: file-id, confirm-file-id, expected-modified-time req. `files delete`: those
plus acknowledge-permanent-delete (Boolean) req. `permissions create`: file-id, type, role
req; email (req when type user|group), domain (req when type domain),
acknowledge-broad-access (req when type domain|anyone) opt with rules in descriptions.
`permissions update`: file-id, permission-id, confirm-permission-id, expected-role, role req.
`permissions delete`: file-id, permission-id, confirm-permission-id, expected-role req.
`comments create`: file-id + content req. `comments update`: + comment-id +
confirm-comment-id req. `comments delete`: file-id, comment-id, confirm-comment-id req.
`replies create`: file-id + comment-id req; content/action at-least-one-of opt.
`replies update`: file-id, comment-id, reply-id, confirm-reply-id, content req.
`replies delete`: same minus content. `revisions update`: file-id, revision-id,
confirm-revision-id req; keep-forever/publish (Boolean) at-least-one-of opt.

The three Sheets confirmation flags above are intentionally optional because the existing
runner permits them to be absent under `--dry-run`; their descriptions carry the conditional
rule and the runner remains authoritative for non-dry-run enforcement. All Drive confirmation
and acknowledgement flags remain required because Drive validation runs even under dry-run.
The implementer verifies each required marking against `validate*` and the builder's
`required(...)` calls while writing the declarations; the flag-parity dry-run test then proves
every marking end to end. No command is intentionally open-ended.

## 5. Facade

```swift
public struct GoogleDocumentsGatewaySDK: GatewaySDK {
  public let provider = "google-documents-gateway"
  public let tier: String                    // "docs-read" | ... | "drive-write"
  public let catalog: GatewaySchemaCatalog
  public let role: GatewayRole
  // stored, not exposed: authorizer: GatewayAuthorizing?, transport: GatewayHTTPTransport,
  // credentialProfile: GatewayCredentialProfile?

  public init(
    role: GatewayRole,
    authorizer: GatewayAuthorizing? = nil,
    transport: GatewayHTTPTransport = URLSessionGatewayTransport(),
    credentialProfile: GatewayCredentialProfile? = nil,
    fileAccessPolicy: GatewaySDKFileAccessPolicy = .denyAll,
    executionPolicy: GatewaySDKExecutionPolicy = .init()
  )

  public func execute(
    document: String, variables: [String: GatewayJSONValue], environment: [String: String]
  ) async -> GatewayEnvelope

  public func invoke(
    _ request: GatewayOperationRequest, environment: [String: String]
  ) async -> GatewayEnvelope

  /// Sync argv construction for the CLI and for callers that want argv without running it.
  public func buildArgv(operation: String, variables: [String: GatewayJSONValue]) throws -> [String]
}
```

- Defaults mirror `GatewayCommandRunner.init` except `environment`: the runner is constructed
  PER CALL inside `execute` with the call's `environment` (kit contract: "the only environment
  the call may observe"). Never default to `ProcessInfo.processInfo.environment`; the kit's
  one-argument `invoke` passes `[:]`, which yields `MissingCredentialAuthorizer` →
  `AUTH_REQUIRED` for network commands and full functionality for `--dry-run` — intended.
- `buildArgv` is construction-only. It performs catalog lookup, binding/type validation,
  finite structural/byte preflight, and deterministic token rendering; it does not consult
  `GatewaySDKFileAccessPolicy`, inspect or open a path, create a snapshot or output, read
  credentials, authorize, or call transport. Consequently file-bearing operations can always
  be rendered under the public default `.denyAll` policy. Filesystem authorization and snapshot
  substitution occur only when `invoke` or `execute` prepares rendered argv for dispatch.
- `execute` parses `document` with `GatewayJSONValue.parse`. A JSON array whose elements are
  all strings enters the SDK raw-argv policy before runner dispatch: standalone `--help`/`-h`,
  `--version`, and empty argv retain their existing usage/version behavior; embedded help and
  `auth login`/`auth revoke` are rejected with `FORBIDDEN_COMMAND`, exit 2, before any credential
  or browser path. When a role-local catalog command declares `input`, `input-file`, or
  `json-file`, the facade parses
  only enough to require a bounded regular file and substitute a private snapshot. Other
  policy-approved argv is forwarded unchanged. The runner result maps through
  `GatewayEnvelope(parsingCLIOutput: result.stdout, exitCode: result.exitCode)`. Anything else
  (GraphQL text, non-array JSON, array with non-string elements, empty string) returns
  `GatewayEnvelope(errors: [.init(message: ..., code: "UNSUPPORTED_DOCUMENT")], exitCode: 2,
  rawOutput: "")` without touching the runner. Non-empty `variables` alongside an argv document
  are ignored (the kit's command path always sends `[:]`); documented in the doc comment.
- `schemaSDL` and `searchSchema` use the kit defaults. `invoke` intentionally overrides the
  kit default to honor the accepted role-error contract without widening the public catalog.
  For an operation present in the role catalog it performs the same
  `GatewayArgvBuilder` validation and catalog-file snapshot preparation, then dispatches
  directly to the runner so a snapshot is not materialized twice. If the name is absent from
  the role catalog but present in the internal union of the 57 role-gated capability commands,
  it sends only the command-name argv directly to the runner; the runner rejects it at its role
  gate before flag validation and returns the canonical `FORBIDDEN_COMMAND` envelope, exit 2.
  A name absent from both sets returns kit `unknownOperation`, exit 2. The internal union is
  name-only, is never exposed through `catalog`, SDL, or search, and does not include
  `auth login` or `auth revoke`. Builder/type errors for allowed operations still map through
  `GatewayEnvelope.failure` exactly as the kit default does. The kit's one-argument `invoke`
  convenience dispatches through this two-argument witness.
- Sendable: struct of Sendable members (`GatewayAuthorizing`/`GatewayHTTPTransport` are
  Sendable protocols); `GatewaySchemaCatalog` is Codable+Sendable.
- Tier enforcement remains in the runner (`FORBIDDEN_COMMAND`). The per-role catalog is
  defense in depth and never exposes another role's operations or types. The `invoke`
  override deliberately routes a recognized but out-of-role command name to that gate so the
  accepted Step 1 error contract is preserved; no variables or forbidden-operation metadata
  are rendered first. Policy-approved raw argv passed to `execute` reaches the same gate,
  proving that neither invocation path can widen the role.

### 5.1 Catalog file trust boundary

Catalog-driven file arguments (`input`, `input-file`, and `json-file`) and Drive transfer
`output` arguments cross a filesystem trust boundary. A public `GatewaySDKFileAccessPolicy`
holds separate caller-approved input and output roots; both root sets default to empty. The SDK
must reject a file-bearing request before opening an input, creating an output, authorizing, or
calling transport unless the relevant path is explicitly authorized. Operation invocation and
recognized role-local raw argv apply the same policy:

- Resolve paths relative to an opened approved-root descriptor. Reject lexical escapes, ambient
  standard input (`-`), symlinks in every path component, FIFOs, devices, sockets, directories,
  and any source that cannot be opened and verified as a regular file from the same descriptor.
- Open an input once without following links and validate the opened descriptor, so a path
  replacement between validation and read cannot redirect the operation. Read until EOF or
  limit plus one, including across short reads; the extra byte distinguishes an exact-limit
  input from an oversized input without an unbounded allocation.
- Retain every directory descriptor used for authorization until the child descriptor is open,
  then bind the operation to the verified leaf descriptor and read only from it. Replacing a
  real authorized directory inode or regular-file pathname after the leaf is opened cannot
  change the bytes copied into the snapshot. A deterministic test hook after leaf `fstat` and
  before the first read proves both directory- and file-inode replacement cases consume the
  originally opened inode rather than reopening by pathname.
- Apply the existing 2 MiB body ceiling to `input-file` and `json-file`. For Drive `input`, use
  the caller's required `max-bytes` value and reject values outside 0...67108864 before reading.
- Copy accepted bytes into a private owner-only temporary snapshot, pass only that snapshot to
  the runner, and remove every snapshot after success or failure. This gives validation and
  execution one immutable view of the input.
- For `files upload`, derive any omitted `name` and `mime-type` from the original source path
  before substitution. Snapshot naming must not change upload metadata or content type.
- Treat `files download`, `files export`, and `revisions download` as local side-effecting
  operations even though their remote semantics are non-destructive. A no-overwrite write is
  staged privately and linked into place only after the complete write and synchronization;
  overwrite is staged beside a verified, single-link regular target and committed by atomic
  rename. Every unsuccessful path before commit—including write, quota, synchronization,
  timeout, and task cancellation—removes the staging file and must leave no newly created
  destination. Once commit starts, cancellation cannot win the commit latch: the operation
  reports the committed result rather than reporting failure after publishing output.

The direct CLI retains its established stdin and file behavior. Its command router explicitly
constructs `operation run` with an internal command-line policy whose input and output root is
`/`; that policy is the CLI host's authorization and is never selected by the public SDK
initializer. The stricter default-deny isolation otherwise applies to SDK catalog invocation
and SDK raw argv for recognized role-local catalog commands. This is an intentional host-safety
boundary, not a request-builder change.

### 5.2 Bounded asynchronous execution

The public facade is asynchronous even though the existing runner is synchronous. Every
`execute` and `invoke` call runs runner work off the caller's cooperative executor, behind a
per-facade concurrency limiter. The execution policy has a strictly positive, finite deadline
and a positive capacity. Normalization is exact: finite positive timeouts clamp to
`0.01...600` seconds; NaN, positive/negative infinity, zero, and negative timeouts become
`0.01`; concurrency values less than one become one and values above 64 become 64; each facade
admits at most 64 active workers plus 256 queued calls; and response limits clamp to
`1...(64 * 1024 * 1024)` bytes. Comparisons and `addingReportingOverflow` checks happen before
arithmetic, so `Int.min`/`Int.max` cannot trap and the receive-time `limit + 1` sentinel is safe.

- Queued acquisition and running file, credential, authorization, and transport work observe one
  cancellation token. Task cancellation or deadline expiry prevents queued work from starting and
  publishes `TRANSPORT_FAILURE` (exit 5), except a post-dispatch mutating/non-idempotent request
  publishes non-retryable `OUTCOME_UNKNOWN`; an output commit already admitted by the §5.1 commit
  latch finishes and reports its committed result.
- One execution latch accepts exactly the first terminal event: worker result, task cancellation,
  or deadline. A late worker or timer result cannot resume the continuation twice or replace the
  published envelope. Its cancellable deadline source is cancelled on every terminal result, so
  completed calls do not retain facade, credential, transport, or cancellation state until the
  configured deadline. File commit uses the narrower latch described in §5.1.
- The limiter owns a bounded waitlist and admits at most `maximumConcurrentOperations` workers;
  queued calls do not each consume a blocked thread. Cancellation removes a queued call promptly
  without starting its worker. Capacity is released in a worker `defer` on every exit, including validation errors,
  cancellation, deadline, credential failures, and transport failures. Deadline publication
  does not pretend the slot is free while arbitrary work continues: the default transport is
  cancellable, injected transports/authorizers must honor the token, and legacy synchronous
  implementations fail before dispatch.
- Raw argv documents are bounded to 2 MiB, 16,384 root-array elements, and each decoded token
  to 64 KiB. A streaming count with cancellation checkpoints rejects wide arrays before JSON
  decoding can materialize duplicate value and String-argv graphs. Inline
  `OAUTH_CLIENT_SECRET_JSON` and `TOKEN_STORE_JSON` are UTF-8 encoded only after a 2 MiB
  byte-length check, then decoded with cancellation checks immediately before and after the
  decoder. File-backed credentials retain the same 2 MiB limit and cancellation behavior.
  Cancellation/oversize failures occur before refresh transport and cannot retain limiter
  capacity after the worker exits.
- Catalog variables and rendered argv use the same 64 KiB per-rendered-token and 2 MiB aggregate
  limits. The variable aggregate includes UTF-8 names, canonical value encodings, and container/
  separator overhead, and the argv aggregate includes every rendered token; all totals use checked
  addition. JSON preflight iteratively counts delimiters, separators, escaped keys, and values
  before rendering, with per-node cancellation checks and finite 128-level/16,384-node limits.
  `invoke` performs preflight and rendering inside the one call deadline; synchronous `buildArgv`
  has the same finite byte/node/depth bounds and construction-only contract. Every
  non-upload request body is checked against the 2 MiB ceiling after its final provider JSON
  construction, including scalar and inline JSON branches that do not read a file. Upload request
  bodies are bounded by the validated 64 MiB input snapshot ceiling, so no request-body path is
  unbounded.
- Every provider response has an 8 MiB default retained-byte ceiling (configuration is clamped
  to a finite 64 MiB maximum), including non-transfer responses. URLSession enforces the ceiling
  internally. Every custom injected SDK transport must conform to
  `GatewayResponseByteLimitedHTTPTransport`, which extends `GatewayCancellableHTTPTransport`, and
  must enforce the supplied deadline, cancellation token, and receive-time byte limit while
  retaining at most `limit + 1` bytes as overflow evidence. A transport that implements only
  `GatewayCancellableHTTPTransport`, or neither protocol, is rejected before dispatch.
  Bounded response processing stream-checks JSON structure with cancellation checkpoints before
  decoding, rejects nesting deeper than 128 levels or more than 16,384 structural values, and
  checks cancellation after receipt, after decode, and before serialization.
  Paginated Drive `--page-all` collection uses the same value as an operation-wide cumulative
  retained-byte budget in addition to the per-response limit. Each page is charged with checked
  addition before retention; final merged serialization must also fit the budget. The loop checks
  cancellation before planning, before each dispatch, after receipt, after JSON parsing, before
  retaining a page, and before final serialization, and never keeps both an unbounded page list
  and an unbounded re-encoding.
- Once a mutating/non-idempotent provider request crosses its dispatch boundary, every subsequent
  transport throw, missing/rejected status, oversized body, malformed body, decoding failure,
  deadline, or cancellation is non-retryable `OUTCOME_UNKNOWN`, even if provider response bytes
  arrived before local parsing completed. Successful local completion may return success, but
  response arrival alone never clears the uncertain-dispatch disposition. Read-only requests
  normalize raw transport errors to retryable `TRANSPORT_FAILURE`.

## 6. CLI subcommands

Routing: in `GatewayCommandRunner.run`, after the existing `--help`/`--version` branches
(their precedence is preserved byte-for-byte, so `schema search x --help` still prints usage)
and before `ParsedArguments`:

```swift
if let sdkResult = GatewaySDKCommandRouter.handle(arguments: arguments, runner: self) {
  return sdkResult
}
```

`handle` returns nil unless `arguments` starts with `["schema", "print"]`,
`["schema", "search"]`, or `["operation", "run"]` — names that collide with no existing
command group, so every existing path is untouched. The router builds the role's catalog once
per call via `GatewaySchemaCatalog.googleDocuments(role: runner.role)`.

- `schema print` → prints `catalog.sdl()` verbatim (contains `type Command`), exit 0. Extra
  arguments → `INVALID_ARGUMENT` failure JSON, exit 2.
- `schema search <regex> [--kinds command,enumeration,...] [--include-referenced-types]
  [--limit N]` → runs `GatewaySchemaSearch`; prints the `[Match]` array as pretty JSON
  with sorted keys, exit 0 (empty array for no matches). `--kinds` values map to
  `GatewayDefinitionKind` raw values; unknown kind, missing regex, bad `--limit`, or an
  invalid regex (`GatewaySDKError.invalidPattern`) → `INVALID_ARGUMENT` failure JSON, exit 2.
  `--limit` must be a base-10 integer greater than or equal to zero, preventing a negative
  value from reaching the kit's collection prefix operation. Unknown options, duplicate
  value options, and trailing positionals are rejected.
- `operation run <name...> --variables <json> | --variables-file <path>` → the operation name
  is every token after `run` up to the first `--` token, joined with spaces (so both
  `operation run "values get"` and `operation run values get` work). Variables JSON must be an
  object; decoded to `[String: GatewayJSONValue]`. Exactly one of `--variables` and
  `--variables-file` is required, their `--flag=value` spellings are also accepted, duplicate
  sources are rejected, and variables-file reads use the existing 2 MiB input limit plus the
  descriptor-based regular-file and bounded-read policy in §5.1. The router classifies the
  operation name before parsing inline variables or opening a variables file: an unknown name
  returns `INVALID_ARGUMENT`, while a recognized out-of-role name is sent name-only to the
  runner and returns `FORBIDDEN_COMMAND`. Neither rejection may touch the variables source.
  Argv is
  built through the facade
  (`sdk.buildArgv`, i.e. `GatewayArgvBuilder` + binding validation) and executed with
  `runner.run(arguments:)`; stdout and exit code are returned verbatim, so output matches the
  existing `{ok, ...}` conventions. `GatewaySDKError`s (unknown operation, missing required
  variable, type mismatch) and unreadable variables files map to the existing failure shape
  `{"ok":false,"error":{"code":"INVALID_ARGUMENT","message":...}}`, exit 2 (resolved analysis
  question: runner-shaped output, no envelope re-encoding).

Usage line appended to `usage` (GatewayCLI.swift:109-113):
`SDK: schema print | schema search <regex> [--kinds k1,k2] [--include-referenced-types] [--limit N] | operation run <name> --variables JSON|--variables-file PATH`.

## 7. Data flow

riela / SDK caller → `GoogleDocumentsGatewaySDK.invoke(request, environment:)` → facade
classifies allowed / known-forbidden / unknown operation name → allowed requests validate
against the per-role catalog and `GatewayArgvBuilder` renders argv without filesystem access →
dispatch preparation authorizes declared paths and creates bounded private snapshots from the
same retained descriptor that passed authorization.
SDK filesystem capability roots are explicit and default-deny: input files and local Drive transfer
outputs must be descendants of caller-approved roots, traversed descriptor-relatively without
symlink following. Call-scoped SDK environments accept inline credential JSON only; file-backed
credentials require a constructor-injected trusted profile and never fall back to host-home state.
Outputs are separately side-effecting operations;
no-clobber writes use descriptor-relative exclusive creation, and overwrite targets are verified
single-link regular files before descriptor-relative temporary-file replacement. Known-forbidden names go directly to
the runner's role gate →
per-call `GatewayCommandRunner(role:authorizer:transport:credentialProfile:environment:)`
→ existing parse/gate/validate/plan/transport pipeline → `{ok,...}` stdout →
`GatewayEnvelope(parsingCLIOutput:exitCode:)` → caller. CLI `operation run` shares the same
argv construction but returns the runner's stdout directly. Raw `execute` decodes the argv JSON,
applies the raw-argv policy and any role-local catalog snapshot substitution, then dispatches to
the same per-call runner. `schema print`/`schema search` are pure catalog reads with no state and
no network. SDK runner work executes through a bounded-worker limiter with a per-call deadline and
task-cancellation propagation; cancellation or deadline expiry returns a transport-failure envelope
without retaining private snapshots unless a remote mutation was dispatched, in which case it
returns `OUTCOME_UNKNOWN`. Injected SDK transports must implement the response-byte-limited
cancellable contract and stop their own work on the supplied cancellation token or deadline;
legacy or cancellable-only transports fail before dispatch rather than retaining limiter capacity
or completing later side effects.

## 8. Errors and edge cases

- Non-argv document → `UNSUPPORTED_DOCUMENT`, exit 2 (kit has no such error case; the facade
  constructs the envelope itself).
- Builder/binding failures for allowed operations inside `invoke` →
  `GatewayEnvelope.failure(error, exitCode: 2)` (kit behavior; message is the
  `GatewaySDKError` description). Recognized out-of-role names instead produce the runner's
  `FORBIDDEN_COMMAND`; genuinely unknown names retain kit `unknownOperation`.
- Runner errors (FORBIDDEN_COMMAND, INVALID_ARGUMENT, AUTH_REQUIRED, TRANSPORT_FAILURE...)
  surface through envelope parsing of the `{ok:false,error:{code,message}}` shape with the
  original exit codes.
- File-boundary failures use the runner's canonical error contract: malformed or non-regular
  sources return `INVALID_ARGUMENT`; limit-plus-one inputs return `INPUT_TOO_LARGE`. SDK invoke,
  raw execute, and `operation run` must agree with direct-runner serialization where the runner
  defines that failure.
- An input or output path outside its explicitly approved capability root returns
  `INVALID_ARGUMENT` before filesystem or network side effects. Empty policies deny all file
  inputs and outputs.
- Timeout and task cancellation return `TRANSPORT_FAILURE`, exit 5, unless an output commit has
  already acquired the commit latch or a remotely mutating/non-idempotent request has crossed
  dispatch. The latter returns non-retryable `OUTCOME_UNKNOWN`, exit 5, for every later failure.
  Exactly one envelope is published, and eventual cooperative worker exit releases the limiter slot.
- Failed local output writes remove staging artifacts and never leave a newly created
  no-overwrite destination. If unlinking a private staging artifact fails, the SDK returns its
  recovery path and retains descriptor-bound cleanup ownership for `retryPendingOutputCleanup()`;
  one retry owns cleanup at a time and unresolved recoveries remain observable until an explicit
  caller retry succeeds or the policy is released. A local overwrite publication whose outcome is
  uncertain returns `OUTCOME_UNKNOWN` with its machine-readable `recovery_path`; the policy keeps
  that descriptor-bound recovery until the caller has reconciled the outcome and explicitly
  retries cleanup. Once that local publication becomes uncertain, it is terminal against task or
  deadline cancellation before the commit latch is released, so cancellation cannot replace its
  recovery-bearing `OUTCOME_UNKNOWN` envelope. A
  successfully committed output is never paired with a cancellation failure envelope.
- Oversized inline or file-backed credential JSON returns `INPUT_TOO_LARGE`; cancellation during
  credential decoding returns `TRANSPORT_FAILURE`. Neither path starts refresh transport.
- Call-scoped `environment` recognizes inline `OAUTH_CLIENT_SECRET_JSON` and `TOKEN_STORE_JSON`
  only. `OAUTH_CLIENT_SECRET_PATH`, `TOKEN_STORE_PATH`, home-directory defaults, and other ambient
  credential paths are ignored by the SDK even when they identify valid authorizing files;
  file-backed credentials are accepted only through constructor-injected `credentialProfile`.
- `.bool(false)` / `.null` variables omit the flag entirely; a required Boolean set to false
  therefore fails at the runner (e.g. "Batch clear requires --confirm-clear") on real runs
  while dry-run passes — matches CLI semantics.
- Repeated-flag rendering only matters for `values batch-get` `range`; single values coerce
  to one-element lists in the kit type check.
- Empty argv array in `execute` → runner prints usage with exit 0 (the explicitly allowed
  raw-argv policy case, same as the CLI with no arguments).
- Sheets confirm-equality checks are skipped under dry-run; drive confirm/acknowledge checks
  always run — fixture generators must mirror confirm-* values from their source flags and
  always satisfy drive rules.
- `files upload`/`files replace-content`/`--input-file` bodies are built before the dry-run
  branch (GatewayCLI.swift:58-61), so fixtures need real temp files; `--output` paths must not
  exist.
- Secrets: argv never carries tokens (runner rejects token arguments by design); catalog
  excludes `auth login`/`auth revoke`; `schema`/`operation` subcommands add no credential
  surface.

## 9. Tests (all swift-testing, in `Tests/GoogleDocumentsGatewayCoreTests/`)

At the Step 2 baseline, `GoogleDocumentsGatewaySDKTests.swift` is 898 lines and
`GatewaySDKCLITests.swift` is 899 lines. Both are split unconditionally before adding the new
regressions. The headings below are the exclusive ownership map: every test requirement belongs
to exactly one named file, shared non-test fixtures belong only to `GatewaySDKTestSupport.swift`,
and no production or test Swift file may reach 1000 lines.

`CommandCatalogParityTests.swift` — per all six roles:
1. `catalog.validate() == []`; provider/tier strings; role-neutral trio present; `auth login`
   / `auth revoke` absent.
2. Names both directions: catalog command names ⊇ `GatewayCapabilityCatalog.commands(for:)`;
   every non-role-neutral catalog name ∈ `commands(for:)` (never widens a tier).
3. Named-type closure equals the non-built-in types referenced by that role's operation
   arguments. Assert the exact current sets: docs-read has `SuggestionsViewMode`;
   sheets-write has `MajorDimension` and `ValueInputOption`; drive-write has `PermissionType`
   and `PermissionRole`; all other roles have none. Schema search finds the local enum and
   returns no match for a foreign-role enum.
4. Requiredness parity: every unconditional argument has `isRequired == true` and an outer
   non-null type; every optional or conditional argument has both signals false/nullable.
   Assert representative SDL contains `!` for required flags and omits it for Sheets
   dry-run-conditional confirmations.
5. Flag parity both directions per command against
   `GatewayCommandFlagInventory.allowedOptions` (`@testable import`): declared argument names
   plus nothing else equal the allowlist. Separately assert that each role-neutral command
   declares exactly optional `credential: String`; no inert parser flags are exposed.
6. Dry-run fixtures: for every role-gated command, variables from all required arguments plus
   one optional (deterministic value generator; exactly-one/at-least-one groups always select
   one valid member; Sheets dry-run-conditional confirmations may be omitted; Drive confirm-*
   values mirror source flags; temp files for input/input-file; fresh non-existent output
   paths; enum first values; `page-token` etc.)
   → `invoke` with `dry-run: true` through the SDK → envelope `ok`, `data.dryRun == true`.
   An extra undeclared flag appended to the same argv → `INVALID_ARGUMENT` from the runner.

`GoogleDocumentsGatewaySDKTests.swift` — through existing-style fake transports:
- `values get` invoke (dry-run): argv and planned method/path/query asserted from the dry-run
  payload; plus one non-dry-run `values get` with an injected authorizer + fixture transport
  asserting the real request URL (pattern of GatewayTests.swift:60).
- Repeatable flag: `values batch-get` with two `range` values → two `--range` pairs in argv
  and two `ranges` query items. (The brief's bullet says "files list (repeatable flag)"; the
  runtime has no repeatable files-list flag — `range` on `values batch-get` is the only
  collection read. `files list` is still covered by an invoke test with query/page-size.
  Deviation documented here on purpose.) An omitted range fails kit required-variable
  validation; an empty range array reaches the runner and fails `INVALID_ARGUMENT`, so the
  documented at-least-one constraint is executable despite the kit having no list-length
  schema constraint.
- `files delete`: missing `confirm-file-id` → missing-required envelope (exit 2, no
  execution); complete confirm/acknowledge set + dry-run → ok.
- `spreadsheet batch-update`: first, a dry-run with JSON body in a temp `input-file` proves
  `bodyValuesRedacted == true` and the batchUpdate path. Second, a non-dry-run invoke with an
  injected authorizer and fake transport plus a separate `buildArgv` assertion proves the
  exact argv, `POST https://sheets.googleapis.com/v4/spreadsheets/<id>:batchUpdate`, and the
  unmodified validated JSON body.
- Writer command (`values update`) passed to catalog-driven `invoke` on a `sheets-read` SDK
  → runner-shaped `FORBIDDEN_COMMAND` envelope, exit 2, before variable binding, authorization,
  or transport. The same command passed as raw argv to `execute` yields the same code and exit
  status. A fabricated command name still yields kit `unknownOperation`, exit 2.
- Policy-approved `execute` argv without snapshot substitution preserves the runner's raw output
  and exit code for the same argv and environment. Catalog file inputs instead compare against
  the runner invoked with the facade's private snapshot; rejected raw-policy inputs never reach
  the runner.
- GraphQL text document → `UNSUPPORTED_DOCUMENT`, exit 2. Non-string-array JSON likewise.

`GoogleDocumentsGatewaySDKFileBoundaryTests.swift` — filesystem construction, input snapshots,
and output commit behavior:

- A construction-only regression calls `buildArgv` for file-bearing operations under `.denyAll`
  with nonexistent and out-of-root paths, asserts the expected path tokens are rendered unchanged,
  and proves filesystem, credential, authorizer, and transport spies all remain untouched.
- File-boundary regressions cover stdin, symlink/non-regular sources, short reads, exact-limit and
  limit-plus-one inputs, snapshot cleanup, byte-for-byte binary Drive uploads, and preservation of
  filename-derived upload name/MIME defaults. Authorizer and transport spies remain untouched on
  every pre-dispatch rejection.
- Inode-binding regressions authorize and open a real regular leaf, pause after `fstat`, replace
  first its directory inode and then its file pathname with different valid contents, and prove the
  private snapshot still contains the bytes of the retained original descriptor in both cases.
- Capability regressions prove the default policy denies inputs and outputs, separate approved
  roots admit only descendants, every approved-root ancestor plus intermediate and leaf symlink is rejected,
  and download/export
  cannot create or replace a path outside the output capability.
- Low-level output-writer and commit-latch regressions directly inject write, quota,
  synchronization, cancellation-token, and commit-admission events before and after exclusive
  no-replace rename and overwrite `renameat`. They do not invoke `runBoundedEnvelope`; they assert
  that successful cleanup leaves neither staging artifacts nor a newly created no-overwrite
  destination, persistent unlink failure exposes a retained recovery and retry clears it, and a
  cancellation event after commit begins returns the successful output.

`GatewaySDKExecutionBoundaryTests.swift` — deadlines, cancellation, credentials, transport,
response disposition, catalog/request bounds, page-all accumulation, and limiter behavior:

- Bounded-envelope regressions race worker completion, deadline, and task cancellation and assert
  one continuation result, no late-result replacement, and no execution after queued cancellation.
  A high-concurrency stress case submits at least 128 calls against capacity four, proves active
  worker and transport counts never exceed four, promptly cancels a large queued subset without
  starting transport for them, and proves later calls complete after every cancellation/error path.
- Credential regressions exercise both `OAUTH_CLIENT_SECRET_JSON` and `TOKEN_STORE_JSON` at the
  exact 2 MiB boundary and limit plus one. Timeout cases use an expired refreshable token, retain
  the refresh-transport spy, pause decoding until after the timeout result, release the decoder,
  and assert zero refresh/provider transport calls after worker exit plus successful limiter reuse.
  A public SDK regression points `OAUTH_CLIENT_SECRET_PATH` and `TOKEN_STORE_PATH` at valid files
  that would authorize if consumed and requires exact `AUTH_REQUIRED` exit 4, zero transport calls,
  and successful subsequent limiter reuse.
- Execution-policy tests cover NaN, positive/negative infinity, zero, and negative timeout;
  zero/negative and `Int.max` concurrency; and `Int.min`/`Int.max` response limits. They assert
  the exact 64-worker/256-waiter normalization, saturation rejection, drain/reuse, bounded active
  workers, and overflow-free `limit + 1` retention for transfer and non-transfer responses.
  Catalog-bound tests cover empty-container node floods, depth 129,
  16,385 nodes, oversized scalar variables, rendered tokens, aggregate argv, and final request
  bodies, plus cancellation/deadline during iterative traversal and page-all accumulation.
- Every mutating or non-idempotent catalog operation is marked destructive and a cancellation
  after dispatching one returns `OUTCOME_UNKNOWN`, exit 5. Remote-response arrival is recorded
  separately from local completion, so bounded parsing remains deadline-cancellable.
  Dispatch classification follows explicit operation semantics rather than HTTP method alone, so
  read-only POST endpoints retain the retryable `TRANSPORT_FAILURE` cancellation envelope.
  Provider-response arrival is recorded separately from local completion: parsing and envelope
  publication remain deadline-cancellable, and cancellation after dispatch retains the
  non-retryable `OUTCOME_UNKNOWN` result even when a response has arrived.
- Transport-disposition regressions cover post-dispatch thrown transport, rejected/missing status,
  non-transfer response overflow, and malformed decoding for a completed mutation; every case is
  exact `OUTCOME_UNKNOWN`, exit 5, and non-retryable. Equivalent read-only failures remain
  `TRANSPORT_FAILURE` where retry is permitted.
- End-to-end SDK tests exercise `runBoundedEnvelope` rather than only the low-level output writer:
  deadline/task cancellation during no-overwrite output, execution/commit latches, inline
  credential decode cancellation, and limiter-capacity release are observable through returned
  envelopes and subsequent operations.

`GatewaySDKTestSupport.swift` — non-test support only:

- Shared thread-safe authorizer and transport spies; response-byte-limited and blocking transports;
  cancellation, deadline, and dispatch observers; credential decoders and expired-token fixtures;
  descriptor-operation and snapshot hooks; output writers; locks/counters; scratch-directory and
  bounded-data helpers; and deterministic request/response fixtures used by the behavioral test
  files in this section. This file declares no `@Test` and does not own behavioral assertions.

`GatewaySDKCLITests.swift` — via `GatewayCommandRunner.run`:
- `schema print` output contains `type Command` and a role-appropriate command name; identical
  across the six roles only in shape, not content.
- `schema search` regex hit as JSON, `--kinds` filtering, `--limit`, invalid regex →
  `INVALID_ARGUMENT` exit 2.
- `operation run values get --variables {...} ` (dry-run) output equals the direct
  `run(arguments:)` output for the built argv; unknown operation and bad variables file →
  exit 2 failure shape; `--variables-file` happy path; usage string lists the SDK line.
- Unknown and recognized out-of-role operations are classified before variables-file opening;
  bounded-reader tests cover short reads and limit-plus-one rejection.
- Existing subcommand regression is carried by the untouched existing suites (64 tests).

## 10. Rollout

All task-owned changes land as one focused commit on `feat/gateway-sdk`. Before staging, compare
the complete tracked-plus-untracked worktree against the Step 1 inventory and use this exact
allowlist: `Package.swift`, `README.md`, `Sources/GoogleDocumentsGatewayCore/GatewayCLI.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog+Docs.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog+Sheets.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog+DriveRead.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog+DriveWrite.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsGatewaySDK.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKCommandRouter.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKExecutionSupport.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKFileAccessPolicy.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKCatalogFileSnapshots.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKCredentialLoading.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GatewayCommandFlagInventory.swift`,
`Sources/GoogleDocumentsGatewayCore/GatewayRuntime.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/CommandCatalogParityTests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GoogleDocumentsGatewaySDKTests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GoogleDocumentsGatewaySDKFileBoundaryTests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKCLITests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKExecutionBoundaryTests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKSnapshotCleanupTests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKTestSupport.swift`,
`design-docs/specs/design-gateway-sdk.md`, and
`impl-plans/active/gateway-sdk.md`. Preserve and report any unrelated user change instead of
including it. The implementation plan assigns execution-policy normalization to a task whose write
scope explicitly includes `Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKExecutionSupport.swift`,
records the previous session's amended commit `656d5a5`, its reviewed 20-path diff, and its no-push
state as historical evidence, and records reference repository HEAD
`4d4b56c686f6875defccb54f74e2276022eb524e` and reopen every revalidation task until its command
has passed in the current workflow. Final verification runs, explicitly:

- `mise run build`
- `mise run test`
- `mise run lint`
- `swift test --filter GoogleDocumentsGatewaySDKTests`
- `swift test --filter GatewaySDKCLITests`
- `for suite in GoogleDocumentsGatewaySDKTests GatewaySDKCLITests; do for run in {1..10}; do swift test --skip-build --filter "$suite" || exit 1; done; done`
- `swift run google-documents-gateway --help`
- `git -C /Users/taco/gits/tacogips/gateway-sdk-kit rev-parse HEAD`
- `git status --short`

After verification and the authorized commit, the implementation plan records the final commit
SHA, the exact committed diff paths, `git status --short` as clean, and `git status --branch --short`
showing the local no-push state. No push, no tags, and no modification to `/Users/taco/gits/tacogips/gateway-sdk-kit` or
`/Users/taco/gits/tacogips/google-documents-gateway`.
README gains an "SDK" section: Swift example (construct facade for `sheets-read`, `invoke`
`values get`, print envelope) and the three CLI subcommands with sample output. Every file
stays under 1000 lines using the explicitly named production and test split paths above.
