# GoogleDocumentsGatewaySDK command facade and role-scoped catalog

**Status**: Facade implementation complete; integrated with v0.3.2 mainline and
public kit pin on `feat/gateway-sdk`; publication decision pending. The original
session-124 no-push boundary applied to its local development run.
**Original Workflow Session**: `codex-design-and-implement-review-loop-session-124`.
**Workflow Mode**: `issue-resolution`
**Issue**: `Add GoogleDocumentsGatewaySDK and command catalog on GatewaySDKKit`
**Issue Number / URL**: Not supplied
**Repository**: `/Users/taco/gits/tacogips/google-documents-gateway-worktrees/gateway-sdk`
**Accepted Design Review**: `comm-001544` (`accepted`; no high or mid design findings)
**Reference Kit**: `/Users/taco/gits/tacogips/gateway-sdk-kit` at
`4d4b56c686f6875defccb54f74e2276022eb524e`; read-only

## Objective

Finish phase 1e as one feature by reconciling the existing implementation with the accepted
design: expose the 57 role-gated commands and three safe role-neutral operations through
role-scoped `GatewaySDKKit` catalogs and `GoogleDocumentsGatewaySDK`; preserve raw argv plus CLI
schema/search/operation modes; enforce construction-only argv rendering, descriptor-bound file
access, finite execution/data bounds, and honest post-dispatch outcomes; add public-path tests and
documentation; then amend the one focused local feature commit without pushing.

## Source-of-truth trace

- `design-docs/specs/design-gateway-sdk.md` is authoritative for scope, catalog contracts,
  facade behavior, filesystem capabilities, response/outcome semantics, tests, and rollout.
- `design-docs/briefs/gateway-sdk-2026-09-04.md` and
  `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md` define the one-feature
  phase boundary. Riela remains an unmodified future consumer.
- `AGENTS.md` and `.codex/skills/swift-coding-agent/SKILL.md` require existing SwiftPM target
  boundaries, focused then full verification, SwiftLint, and all non-generated Swift files under
  1,000 lines.
- `/Users/taco/gits/tacogips/gateway-sdk-kit` defines `GatewaySDK`, catalogs,
  `GatewayArgvBuilder`, SDL/search, and envelope parsing and must remain unchanged at the pinned
  SHA.
- Accepted intentional divergences: catalog tiers are `<service>-<read|write>` rather than
  `GatewayRole.identifier`; `values batch-get --range` is the only repeatable flag; paths remain
  `String`; only runtime-enforced closed sets become enums; no Cursor adapter is added; direct CLI
  file access retains an internal `/` capability while public SDK access defaults to deny-all.
- Accepted risk rule: every remotely mutating or non-idempotent operation is destructive. After
  provider dispatch, transport, status, response-limit, decoding, timeout, or cancellation failure
  returns non-retryable `OUTCOME_UNKNOWN`; response arrival alone does not clear uncertainty.

## Exact feature path allowlist

Final staging may contain exactly these 26 repository-relative paths:

1. `Package.swift`
2. `README.md`
3. `Sources/GoogleDocumentsGatewayCore/GatewayCLI.swift`
4. `Sources/GoogleDocumentsGatewayCore/GatewayRuntime.swift`
5. `Sources/GoogleDocumentsGatewayCore/SDK/GatewayCommandFlagInventory.swift`
6. `Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKCatalogFileSnapshots.swift`
7. `Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKCommandRouter.swift`
8. `Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKCredentialLoading.swift`
9. `Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKExecutionSupport.swift`
10. `Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKFileAccessPolicy.swift`
11. `Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog+Docs.swift`
12. `Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog+DriveRead.swift`
13. `Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog+DriveWrite.swift`
14. `Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog+Sheets.swift`
15. `Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog.swift`
16. `Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsGatewaySDK.swift`
17. `Tests/GoogleDocumentsGatewayCoreTests/CommandCatalogParityTests.swift`
18. `Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKCLITests.swift`
19. `Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKExecutionBoundaryTests.swift`
20. `Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKTestSupport.swift`
21. `Tests/GoogleDocumentsGatewayCoreTests/GoogleDocumentsGatewaySDKFileBoundaryTests.swift`
22. `Tests/GoogleDocumentsGatewayCoreTests/GoogleDocumentsGatewaySDKTests.swift`
23. `design-docs/specs/design-gateway-sdk.md`
24. `impl-plans/active/gateway-sdk.md`
25. `Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKSnapshotCleanupTests.swift`
26. `Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKCredentialPersistenceTests.swift`

## Deliverables

- [x] Exact role-scoped command/type/flag/destructive-metadata catalogs without modifying
      `gateway-sdk-kit`.
- [x] A construction-only `buildArgv` plus bounded catalog variables, rendered tokens, argv,
      request bodies, credentials, provider responses, and page-all accumulation.
- [x] Default-deny, descriptor-relative filesystem capabilities with snapshots bound to the
      authorized directory/file descriptors and transactional output commits.
- [x] Finite deadlines and concurrency, prompt queued cancellation, bounded worker/transport use,
      and overflow-safe response-limit normalization.
- [x] Correct post-dispatch `OUTCOME_UNKNOWN` mapping for every mutating/non-idempotent failure.
- [x] Concrete test-suite splits and public-path regressions covering every carried high/mid
      finding.
- [x] README, progress evidence, one focused amended commit, clean worktree, and no push.

## Tasks

### TASK-GSDK-001: Rebaseline and protect the worktree

**Write Scope**: This plan's Progress Log only.
**Dependencies**: Accepted design review `comm-001544`.
**Parallelizable**: No.

**Work**:

- Record branch, HEAD and parent, upstream/ahead state, tracked and untracked paths, existing dirty
  paths, and the exact feature diff before implementation edits.
- Preserve the accepted dirty design update and exclude unrelated user work from staging.
- Verify the current local HEAD is the single unpushed feature commit intended for amendment.
  Historical evidence must record intermediate amendment `656d5a5`, its reviewed 20-path diff,
  and its no-push state; it is not current-session completion evidence.
- Verify the reference-kit SHA and clean status. Stop rather than modify or accept drift.
- Inspect `Package.swift`, nearby source/tests, `README.md`, `mise.toml`, `.swiftlint.yml`, and all
  Swift file sizes. Treat all historical task checkmarks and command results as context only.

**Completion Criteria**:

- [x] Baseline, dirty-path ownership, exact 26-path allowlist, reference SHA, and no-push state are
      recorded before source edits.
- [x] Every implementation and verification checkbox remains open until current-session evidence
      is logged.

### TASK-GSDK-002: Reconcile package and catalog contracts

**Write Scope**: `Package.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GatewayCommandFlagInventory.swift`, and
`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog*.swift`.
**Dependencies**: TASK-GSDK-001.
**Parallelizable**: Yes, with TASK-GSDK-003 and TASK-GSDK-004; write scopes are disjoint.
**Design Sections**: §§2-4 and §10.

**Work**:

- Preserve the local `GatewaySDKKit` product dependency and future URL-pin comment without adding
  a remote pin or target.
- Verify all six role catalogs contain their exact commands, transitive named types, tiers,
  argument types/requiredness, and only the safe neutral trio.
- Keep `dry-run` only on role-gated commands; neutral commands expose only optional `credential`.
- Drive catalog `isDestructive` from the same complete mutating/non-idempotent inventory used by
  execution outcome classification; do not restore the obsolete narrow mutation set.
- Preserve runtime/catalog flag parity from the shared inventory and existing target/API
  boundaries.

**Completion Criteria**:

- [x] Catalog validation and bidirectional role, flag, requiredness, type-closure, search-isolation,
      and destructive-metadata checks pass for all six roles.
- [x] `auth login`, `auth revoke`, and foreign-role operations/types remain absent.
- [x] The reference kit and `Package.resolved` remain unchanged.

### TASK-GSDK-003: Bound execution, transport, provider responses, and remote outcomes

**Write Scope**:
`Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKExecutionSupport.swift` and
`Sources/GoogleDocumentsGatewayCore/GatewayCLI.swift`.
**Dependencies**: TASK-GSDK-001.
**Parallelizable**: Yes, with TASK-GSDK-002 and TASK-GSDK-004; write scopes are disjoint.
**Design Sections**: §§5.1-5.2, 7, and 8.

**Work**:

- Keep `GatewaySDKExecutionPolicy` and all timeout/concurrency/response-limit normalization in
  `GatewaySDKExecutionSupport.swift`. Clamp finite positive timeouts to `0.01...600` seconds;
  normalize NaN, positive/negative infinity, zero, and negative timeouts to `0.01`; normalize
  concurrency below one to one and above 64 to 64; admit at most 256 queued calls in addition to
  active workers; clamp response limits, including `Int.min`/`Int.max`, to
  `1...(64 * 1024 * 1024)` bytes.
- Make all `limit + 1` calculations checked or saturating so `Int.max` cannot trap.
- Require custom injected SDK transports to conform to
  `GatewayResponseByteLimitedHTTPTransport`; reject cancellable-only and legacy transports before
  dispatch. Enforce the effective finite byte ceiling while receiving every transfer and
  non-transfer response, using the 8 MiB default and 64 MiB maximum, and keep cancellation active
  through bounded parsing.
- Preserve a terminal latch, commit latch, one cancellation token, and bounded-worker limiter.
  Worker `defer` owns capacity release; promptly cancel queued work and per-call deadline sources.
- At least 128 calls against capacity four must never exceed four active workers/transports;
  cancellation of queued calls must start no transport and later calls must make progress.
- Once any mutating/non-idempotent request crosses actual provider dispatch, map thrown transport,
  missing/rejected status, response overflow, malformed response, decoding, timeout, and task
  cancellation to non-retryable `OUTCOME_UNKNOWN`, even after response bytes arrive. Preserve
  retryable `TRANSPORT_FAILURE` for equivalent read-only failures.
- Bound final provider request bodies: non-upload bodies at 2 MiB and upload bodies at the
  validated 64 MiB snapshot maximum.
- Give Drive `--page-all` an operation-wide cumulative retained-byte budget using checked addition,
  per-page/final-serialization checks, and cancellation checkpoints without retaining both an
  unbounded page list and unbounded re-encoding.

**Completion Criteria**:

- [x] Policy normalization is finite, positive where required, overflow-free, and forward-moving.
- [x] Every provider response, including OAuth refresh, each Drive page-all and mutation-preflight
      response, and the accumulated page-all result, is structurally bounded before decoding or
      retention; page collections and tokens are schema-validated, and resumable uploads advance
      only from a validated provider Range acknowledgment.
- [x] Internal decode seams prove structural rejection occurs before raw-argv or Foundation
      provider-response decoding for ordinary, page-all, mutation-preflight, and OAuth refresh paths.
- [x] Post-dispatch mutation failures are always exact non-retryable `OUTCOME_UNKNOWN`; read-only
      failures retain the accepted retryable mapping.
- [x] High-concurrency stress proves bounded active workers/transports, exact `Int.max`
      normalization to 64 workers plus 256 queued calls, saturation rejection, draining, prompt
      queued cancellation, eventual worker exit, and later limiter reuse.

### TASK-GSDK-004: Preserve construction-only invocation, bounded rendering, files, and credentials

**Write Scope**:
`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsGatewaySDK.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKCommandRouter.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKFileAccessPolicy.swift`,
`Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKCatalogFileSnapshots.swift`, and
`Sources/GoogleDocumentsGatewayCore/SDK/GatewaySDKCredentialLoading.swift`, and
`Sources/GoogleDocumentsGatewayCore/GatewayRuntime.swift`.
**Dependencies**: TASK-GSDK-001.
**Parallelizable**: Yes, with TASK-GSDK-002 and TASK-GSDK-003; write scopes are disjoint.
**Design Sections**: §§5-8.

**Work**:

- Keep `buildArgv` construction-only: catalog bind, validate, bounded preflight, and render only.
  It must not consult file capabilities; inspect/open paths; create snapshots/outputs; read
  credentials; authorize; or invoke transport, including for nonexistent/out-of-root file paths.
- Before recursive serialization, iteratively preflight catalog variables with UTF-8 bytes for
  delimiters, separators, escaped keys, and scalars; enforce 128 depth, 16,384 nodes, 64 KiB per
  token, 2 MiB aggregate rendered argv/body limits, and per-node cancellation/deadline checks.
  Wide empty containers and nesting depth 129 must fail safely.
- Defer file capability authorization and snapshot substitution to `invoke`/`execute`. Traverse
  from opened root descriptors without symlink following, retain authorized descriptors, and
  read immutable bounded snapshots from those descriptors. After authorization, replacing either
  the real directory inode or regular-file pathname must not change snapshot bytes.
- Preserve separate default-deny input/output roots, lexical-escape and non-regular rejection,
  2 MiB ordinary body inputs, 64 MiB Drive upload ceiling, transactional no-overwrite/overwrite
  output commits, and cleanup on every unsuccessful exit. If staging unlink fails, retain the
  authorized descriptor in policy-owned cleanup state, expose its recovery path, and support a
  bounded later retry that serializes cleanup ownership, keeps unresolved recovery observable, and
  releases the descriptor only after successful unlink.
- Accept call-scoped inline credential JSON only. Ignore valid
  `OAUTH_CLIENT_SECRET_PATH`/`TOKEN_STORE_PATH` and ambient defaults; constructor-injected profiles
  remain the only file-backed SDK credential path. Bound/decode inline values with cancellation
  checks and never refresh after timeout or rejection.
- Preserve help/version precedence, role-gate-first classification, raw argv limits, schema/search
  purity, operation-run output parity, and CLI-only internal `/` file authority. Raw argv accepts
  only a streaming flat JSON string array before decoding and checks cancellation during traversal.

**Completion Criteria**:

- [x] File-bearing `buildArgv` succeeds under `.denyAll` without filesystem, credential,
      authorizer, or transport calls.
- [x] Wide/deep/large catalog variables, rendered tokens, argv, and bodies fail within finite
      byte/node/depth/deadline bounds.
- [x] Snapshot contents remain bound to retained descriptors across directory-inode and leaf-path
      replacement after authorization.
- [x] Valid environment-selected credential files produce exact `AUTH_REQUIRED` exit 4, zero
      transport calls, and leave the limiter reusable.
- [x] Overwrite publication retains its authorized parent, verifies the expected destination
      identity at atomic commit, and rejects a deterministic destination swap without staging leaks.

### TASK-GSDK-005: Revalidate exhaustive catalog behavior

**Write Scope**:
`Tests/GoogleDocumentsGatewayCoreTests/CommandCatalogParityTests.swift` only.
**Dependencies**: TASK-GSDK-002 and TASK-GSDK-004 public contracts frozen.
**Parallelizable**: Yes, with TASK-GSDK-006 and TASK-GSDK-007; write scopes are disjoint.
**Design Section**: §9 catalog tests.

**Work**:

- Cover exact command counts, neutral shape, auth exclusions, tier/provider values, bidirectional
  flag/name parity, requiredness/nullability, enum closure, search isolation, broad destructive
  classification, and `dry-run` placement for all roles.
- Generate deterministic valid dry-run fixtures for all 57 role-gated commands and reject one
  appended undeclared option per command.
- Keep this suite catalog-only; do not place filesystem, transport, execution, or CLI regressions
  here.

**Completion Criteria**:

- [x] Every command succeeds in valid dry-run form without credentials or transport.
- [x] Any catalog/runtime, role/type, or destructive-inventory drift fails the suite.

### TASK-GSDK-006: Split suites and add public-path boundary regressions

**Write Scope**:
`Tests/GoogleDocumentsGatewayCoreTests/GoogleDocumentsGatewaySDKTests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GoogleDocumentsGatewaySDKFileBoundaryTests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKSnapshotCleanupTests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKExecutionBoundaryTests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKCredentialPersistenceTests.swift`,
`Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKCLITests.swift`, and
`Tests/GoogleDocumentsGatewayCoreTests/GatewaySDKTestSupport.swift`.
**Dependencies**: TASK-GSDK-003 and TASK-GSDK-004.
**Parallelizable**: Yes, with TASK-GSDK-005 and TASK-GSDK-007; write scopes are disjoint.
**Design Section**: §9 facade, file-boundary, execution-boundary, support, and CLI ownership map.

**Work**:

- Unconditionally split the baseline 898-line SDK suite and 899-line CLI suite before adding
  regressions. Put each behavioral assertion in its exact design-owned test file; put shared
  non-test spies/fixtures only in `GatewaySDKTestSupport.swift`, with no `@Test` declarations.
- Preserve facade coverage for raw execute, schema/search, role errors, exact argv and live requests
  for `values get`, repeated range values, `files list`, destructive delete, and spreadsheet
  batch-update.
- Put construction-only, descriptor-bound snapshots, directory and file inode replacement,
  capability denial, symlink/non-regular/size bounds, output commit races, and cleanup tests in
  `GoogleDocumentsGatewaySDKFileBoundaryTests.swift`; keep snapshot-cleanup lifetime and
  post-dispatch cleanup-outcome regressions in `GatewaySDKSnapshotCleanupTests.swift`.
- Put all policy-normalization cases, `Int.min`/`Int.max` response limits, transfer/non-transfer
  ceiling enforcement, at-least-128-call limiter stress, queued cancellation, terminal races,
  catalog/body bounds, page-all budget, inline/path credential behavior, and transport-disposition
  tests in `GatewaySDKExecutionBoundaryTests.swift`.
- For timed-out inline credential decoding, use an expired refreshable token, retain the refresh
  transport spy, wait for the timeout envelope, release the decoder, wait for worker exit, assert
  zero refresh/provider transport calls, then prove limiter reuse.
- For environment credential-path rejection, provide valid regular secret/token files that would
  authorize if read; invoke the public SDK and require exact `AUTH_REQUIRED`, exit 4, zero transport
  calls, and later limiter reuse.
- Exercise post-dispatch thrown transport, missing/rejected status, response overflow, malformed
  decoding, timeout, and task cancellation for completed mutations through public SDK paths and
  require non-retryable `OUTCOME_UNKNOWN`. Pair each relevant case with read-only behavior.
- Use end-to-end `runBoundedEnvelope` tests for deadline/task cancellation, inline credential
  decoding, and limiter release. Keep low-level output-writer/commit-latch fault injection in the
  file-boundary suite as explicitly accepted by the design.
- Put file-backed token persistence/cancellation-result-boundary coverage in the focused
  `GatewaySDKCredentialPersistenceTests.swift` suite so every non-generated Swift file remains
  below 1,000 lines.

**Completion Criteria**:

- [x] Every carried high/mid finding has a deterministic regression at its assigned public or
      accepted low-level boundary.
- [x] No behavioral test is duplicated across files; support contains fixtures only.
- [x] Every non-generated Swift file is below 1,000 lines.
- [x] `GoogleDocumentsGatewaySDKTests` and `GatewaySDKCLITests` each pass ten consecutive
      no-rebuild reruns, and all newly split suites pass focused runs.

### TASK-GSDK-007: Update public documentation

**Write Scope**: `README.md` only.
**Dependencies**: TASK-GSDK-002 through TASK-GSDK-004 public behavior frozen.
**Parallelizable**: Yes, with TASK-GSDK-005 and TASK-GSDK-006; write scopes are disjoint.
**Design Sections**: §§1, 5-6, 8, and 10.

**Work**:

- Preserve the Swift construction/invocation example, raw argv, and all three SDK CLI subcommands.
- Document default-deny roots, CLI-only `/` authority, finite variable/body/response/deadline limits,
  inline-only call environments, and post-dispatch `OUTCOME_UNKNOWN` semantics.
- State precisely that custom transports must implement
  `GatewayResponseByteLimitedHTTPTransport`, which extends
  `GatewayCancellableHTTPTransport`; cancellable-only transports are rejected before dispatch.
- Keep catalog defense-in-depth, runner authority, no-Cursor-adapter, and future-Riela boundaries.

**Completion Criteria**:

- [x] Public examples and collaborator requirements match compiled public names and tested runtime
      behavior.

### TASK-GSDK-008: Verify, record, stage, and commit

**Write Scope**: This plan's Progress Log, Git index, and one focused amended feature commit
containing only the 26-path allowlist.
**Dependencies**: TASK-GSDK-005, TASK-GSDK-006, and TASK-GSDK-007.
**Parallelizable**: No.

**Work**:

- Run every command in Verification in the current session and record exit status, relevant test
  count/result, and any gap. Historical passes do not close a current gate.
- Compare tracked plus untracked paths with the baseline and exact allowlist. Stage explicit
  pathspecs only and inspect staged names/content/whitespace before committing.
- Amend only the verified local unpushed feature commit, without AI attribution. Do not push, tag,
  publish, or modify sibling/reference repositories.
- Record the exact committed diff path count/list, clean status, branch/no-push status,
  reference-kit SHA/cleanliness, and unresolved TODOs in this Progress Log. Because the final
  commit SHA is created by committing this log, the Step 6 workflow payload is the authoritative
  final-SHA record; each log revision records the superseded pre-amend SHA. Stop if
  history/publication state is not the TASK-GSDK-001 baseline.

**Completion Criteria**:

- [x] All current-session focused, stability, full, lint, help, size, whitespace, dependency,
      allowlist, commit, clean-tree, and no-push gates pass.
- [x] Exactly one focused amended feature commit contains exactly the 26 allowed paths.

## Dependency graph and safe parallelism

1. TASK-GSDK-001 gates all work.
2. TASK-GSDK-002, TASK-GSDK-003, and TASK-GSDK-004 may run concurrently because their write
   scopes are disjoint.
3. TASK-GSDK-005 follows frozen catalog/facade contracts; TASK-GSDK-006 follows execution/facade
   behavior; TASK-GSDK-007 follows all public behavior. These three tasks may run concurrently
   because their write scopes are disjoint.
4. TASK-GSDK-008 is the final serial gate.

## Verification commands

- [x] `swift test --filter CommandCatalogParityTests`
- [x] `swift test --filter GoogleDocumentsGatewaySDKTests`
- [x] `swift test --filter GoogleDocumentsGatewaySDKFileBoundaryTests`
- [x] `swift test --filter GatewaySDKSnapshotCleanupTests`
- [x] `swift test --filter GatewaySDKExecutionBoundaryTests`
- [x] `swift test --filter GatewaySDKCredentialPersistenceTests`
- [x] `swift test --filter GatewaySDKCLITests`
- [x] `for suite in GoogleDocumentsGatewaySDKTests GatewaySDKCLITests; do for run in {1..10}; do mise exec -- swift test --skip-build --filter "$suite" || exit 1; done; done`
- [x] `mise run build`
- [x] `mise run test`
- [x] `mise run lint`
- [x] `mise run gateway:help`
- [x] `swift run google-documents-gateway --help`
- [x] `find Sources Tests -type f -name '*.swift' -print0 | xargs -0 wc -l | awk '$2 != "total" && $1 >= 1000 { print; failed=1 } END { exit failed }'`
- [x] `git diff --check`
- [x] For every untracked non-ignored file: `git diff --no-index --check -- /dev/null <path>`
- [x] `test "$(git -C /Users/taco/gits/tacogips/gateway-sdk-kit rev-parse HEAD)" = 4d4b56c686f6875defccb54f74e2276022eb524e`
- [x] `test -z "$(git -C /Users/taco/gits/tacogips/gateway-sdk-kit status --short)"`
- [x] `git status --short --branch`
- [x] `git diff --cached --check`
- [x] `git diff --cached --name-only HEAD^` exactly matches the 26-path allowlist before commit;
      `git diff --cached --name-only` records only the amendment delta.
- [x] `git diff --name-only HEAD^ HEAD` exactly matches the 26-path allowlist after commit.
- [x] `git show --stat --oneline --decorate --no-renames HEAD`
- [x] `test -z "$(git status --porcelain)"`

## Completion criteria

- [x] All 57 role-gated commands and exactly three safe neutral operations have accepted role,
      types, flags, requiredness, and broad destructive metadata.
- [x] Catalog invoke, construction-only argv, approved raw argv, and CLI operation mode converge on
      the existing runner without widening role or filesystem authority.
- [x] Every file, variable, token, flat raw argv, body, response, page-all aggregate, worker, and
      deadline resource has the accepted finite bound and cancellation checkpoints before decoding.
- [x] Valid-sized fabricated operations enter the execution limiter before lookup and retain the
      exact kit `unknownOperation` envelope; oversized names return only the bounded generic
      `INPUT_TOO_LARGE` envelope without echoing caller-controlled input.
- [x] SDK file-backed and raw inline request JSON are structurally preflighted at 128 nesting
      levels and 16,384 nodes before Foundation decoding, with cancellation releasing the limiter.
- [x] File authorization is descriptor-bound and transactional; rejected/failed calls either clean
      staging output or return its recovery path with retained cleanup ownership.
- [x] Every post-dispatch mutating/non-idempotent failure is non-retryable `OUTCOME_UNKNOWN` and
      every allowed read-only retry mapping remains intact.
- [x] Concrete split suites cover every prior high/mid finding; focused/stability/full/lint/help and
      under-1,000-line gates pass after the Step 6 revision.
- [x] Default parallel discovery passed five consecutive `mise run test` executions after every
      mandatory fixture handshake uses the shared five-second bound off the Swift Testing executor.
- [x] README, accepted design, implementation, tests, and Progress Log agree after final evidence.
- [x] `gateway-sdk-kit`, Riela, provider request semantics, packaging, and unrelated user work are
      unchanged.
- [x] The final feature commit contains exactly the 26 allowed paths, the worktree is clean, and no
      push occurred after the Step 6 revision.

## Addressed review feedback

- `PRIOR-01` (`impl-plans/active/gateway-sdk.md:125`, mid): TASK-GSDK-003 assigns normalization
  to the exact owner `GatewaySDKExecutionSupport.swift` and includes it in the allowlist.
- `PRIOR-02` (`impl-plans/active/gateway-sdk.md:264`, mid): TASK-GSDK-006 unconditionally names
  `GoogleDocumentsGatewaySDKFileBoundaryTests.swift`, `GatewaySDKExecutionBoundaryTests.swift`,
  and fixture-only `GatewaySDKTestSupport.swift`; all are in the exact 26-path allowlist.
- `PRIOR-03` (`impl-plans/active/gateway-sdk.md:274`, mid): the stability command reruns both
  `GoogleDocumentsGatewaySDKTests` and `GatewaySDKCLITests` ten times without rebuilding.
- `PRIOR-04` (`GatewaySDKCLITests.swift:359`, mid): TASK-GSDK-006 requires NaN, both infinities,
  zero/negative timeouts, zero/negative capacity, and extreme response-limit cases.
- `PRIOR-05` (`impl-plans/active/gateway-sdk.md:493`, mid): TASK-GSDK-001 records historical
  amendment `656d5a5`, its reviewed 20-path diff, and no-push state; TASK-GSDK-008 separately
  records current final commit/diff/clean/no-push evidence.
- `PRIOR-06` (`GatewaySDKCLITests.swift:483`, mid): TASK-GSDK-006 retains refresh/provider spies,
  uses an expired refreshable token, waits for worker exit after decoder release, asserts zero
  transport calls, and proves limiter reuse.
- `PRIOR-07` (`GatewaySDKExecutionSupport.swift:390`, mid): TASK-GSDK-003 bounds every transfer
  and non-transfer response and keeps cancellation active through parsing.
- `PRIOR-08` (`GatewaySDKExecutionSupport.swift:179`, mid): TASK-GSDK-003 clamps extreme response
  limits and makes `limit + 1` overflow-safe.
- `PRIOR-09` (`design-gateway-sdk.md:75`, mid): TASK-GSDK-002 and TASK-GSDK-003 consistently use
  the accepted complete mutating/non-idempotent inventory and reject response-arrival-wins logic.
- `PRIOR-10` (`GoogleDocumentsGatewaySDKTests.swift:515`, mid): TASK-GSDK-004/006 require both
  directory-inode and regular-file-path replacement after authorization and prove retained original
  bytes.
- `PRIOR-11` (`GatewaySDKCLITests.swift:392`, mid): TASK-GSDK-003/006 require at least 128 calls
  against capacity four, prompt queued cancellation, bounded worker/transport counts, and reuse.
- `PRIOR-12` (`GatewaySDKCLITests.swift:640`, mid): TASK-GSDK-004/006 use valid credential files
  and require exact `AUTH_REQUIRED`, exit 4, zero transport calls, and limiter reuse.
- `PRIOR-13` (`GoogleDocumentsGatewaySDK.swift:94`, mid): TASK-GSDK-004 makes `buildArgv`
  construction-only and tests file-bearing operations under `.denyAll` without path access.
- `PRIOR-14` (`README.md:187`, mid): TASK-GSDK-007 documents the exact required
  `GatewayResponseByteLimitedHTTPTransport` contract and cancellable-only rejection.
- `PRIOR-15` (`GatewaySDKExecutionSupport.swift:281`, high): TASK-GSDK-003/006 map every listed
  post-dispatch mutating failure to non-retryable `OUTCOME_UNKNOWN` and test read-only controls.
- `PRIOR-16` (`GoogleDocumentsGatewaySDK.swift:91`, mid): TASK-GSDK-004/006 bound total variables,
  nodes/depth, rendered tokens/argv, and final request bodies with cancellation checkpoints.
- `PRIOR-17` (`GatewayCLI.swift:593`, mid): TASK-GSDK-003/006 impose an operation-wide page-all
  byte budget, checked retention/serialization, and cancellation checkpoints.
- `PRIOR-18` (`GoogleDocumentsGatewaySDK.swift:374`, mid): TASK-GSDK-004/006 count structural
  bytes/nodes iteratively and reject wide empty containers and depth 129 before recursive render.

## Risks and mitigations

- **Near-limit test files**: unconditional responsibility-based splits and the under-1,000-line
  gate prevent regressions and avoid conditional undeclared paths.
- **Remote outcome misreporting**: one shared operation-risk inventory plus mutation/read-only
  paired tests prevents unsafe retries after provider dispatch.
- **Memory/work amplification**: iterative structural accounting, checked addition, receive-time
  response limits, cumulative page budgets, and finite nodes/depth bound all data paths.
- **Filesystem TOCTOU**: descriptor-relative no-follow traversal and reads from retained
  descriptors bind snapshots to authorized inodes despite pathname replacement.
- **Limiter starvation or worker growth**: bounded workers, queued cancellation, worker-owned
  release, and 128-call stress make capacity and reuse observable.
- **Credential leakage or ambient authority**: inline-only environments and valid-file negative
  tests prove path variables/defaults are ignored without printing secrets.
- **Dirty-worktree contamination**: baseline ownership plus explicit 26-path staging protects
  unrelated work and the accepted dirty design.
- **Reference/history drift**: exact SHA, clean-state, commit ancestry, and no-push checks stop the
  workflow instead of mutating or silently accepting drift.

## Progress Log

- 2026-09-06 Step 4 (`codex-design-and-implement-review-loop-session-118`): design review
  `comm-001544` accepted `design-docs/specs/design-gateway-sdk.md` with no high or mid findings.
  Recreated this implementation plan from that accepted design, reopened every task/gate, assigned
  all 18 carried findings to explicit production/test paths, made the three test split/support
  paths unconditional, and expanded the exact staging allowlist from the historical 20 paths to
  the accepted 23 paths.
- Historical commit evidence from workflow session 117: intermediate amended commit `656d5a5`
  had a reviewed 20-path feature diff and remained local/unpushed. The current Step 4 baseline is
  HEAD `b163ce7c074352dd8e7264117fcd1f8f0f5915ce` with only
  `design-docs/specs/design-gateway-sdk.md` dirty at plan creation; TASK-GSDK-001 must independently
  verify ancestry, publication state, exact diff, and dirty-path ownership before implementation.
- Later entries must record task ID, changed paths, exact commands/results, unresolved gaps,
  allowlist changes, committed diff, clean status, no-push state, and the superseded pre-amend
  SHA; the Step 6 workflow payload is authoritative for the resulting final SHA. A checkbox may
  be marked complete only after current-session evidence is logged.
- 2026-09-06 Step 6: reconciled the accepted design before edits and implemented the remaining
  cumulative page-all serialization check in `GatewayCLI.swift`; added the unconditional
  `GatewaySDKExecutionBoundaryTests.swift`, `GoogleDocumentsGatewaySDKFileBoundaryTests.swift`,
  and fixture-only `GatewaySDKTestSupport.swift` split paths. The new public-boundary coverage
  proves all policy normalization cases (including NaN/infinities and Int extremes), a 128-call
  capacity-four limiter ceiling and reuse, bounded non-transfer responses, mutating parse
  uncertainty, construction-only denied-file argv, and retained-descriptor bytes across both
  directory and regular-file pathname replacement. Current-session focused suites, 10x stability
  reruns for both legacy suites, `mise run build`, `mise run test`, `mise run lint`, both help
  commands, size, reference-kit SHA/cleanliness, and `git diff --check` passed. No unresolved
  implementation gap remains; staging/amendment evidence is pending TASK-GSDK-008.
- 2026-09-06 TASK-GSDK-008: explicitly staged the exact allowlist, passed the staged whitespace
  check and gitleaks staged-secret scan, and amended the one local feature commit. The committed
  diff reported exactly the 23-path allowlist and passed `git diff --check`; the worktree was
  clean. `feat/gateway-sdk` has no configured upstream, so no push was possible or attempted.
  The final evidence-only amendment SHA is reported in this workflow step's result.
- 2026-09-06 Step 6 revision: self-review `comm-001549` reopened TASK-GSDK-006 and TASK-GSDK-008.
  `GatewaySDKExecutionLimiter` now returns a cancellable queued operation and the invocation latch
  cancels it on deadline/task cancellation; the execution suite includes 128 queued cancellations
  proving zero admitted transports before reuse. Catalog variable preflight now accounts for the
  enclosing map and uses one aggregate node counter across all variables. Behavioral test
  registration is reassigned to the facade, file-boundary, execution-boundary, and CLI suite
  ownership map without duplicate `@Test` registration. The previous final SHA
  `0abcdabcc5755f64ceabb6e16b46dbe032113385` was superseded by the final Step 6 amendment.
  All focused, stability, full, lint, help, size, whitespace, reference-kit, allowlist,
  clean-tree, and no-push gates passed; the resulting amend SHA is reported by the Step 6
  workflow payload because this progress log is itself part of that amended commit.
- 2026-09-06 Step 6 revision 2: physically moved every file-boundary assertion into
  `GoogleDocumentsGatewaySDKFileBoundaryTests.swift`, every execution/credential/limiter assertion
  into `GatewaySDKExecutionBoundaryTests.swift`, retained facade-only assertions in
  `GoogleDocumentsGatewaySDKTests.swift`, retained CLI-only assertions in `GatewaySDKCLITests.swift`,
  and centralized shared fixture types in `GatewaySDKTestSupport.swift` with no `@Test`
  declarations. Catalog source-key accounting now uses JSON-encoded keys (quotes and escapes
  included), with an escaped-key aggregate-bound regression. Commit
  `890eb5fcd2b62ab5aae152a77a647274a0704145` is the fully verified first revision amendment;
  this final plan/evidence amendment supersedes it. All TASK-GSDK-001 through TASK-GSDK-008
  criteria and verification gates are checked from current-session evidence; the resulting final
  SHA is reported by the Step 6 workflow payload because this progress log is part of the amend.
- 2026-09-06 Step 6 revision 3: self-review `comm-001553` found one output-commit/cancellation
  regression left as an unregistered CLI helper. Moved it intact to
  `GoogleDocumentsGatewaySDKFileBoundaryTests.swift` as the individual
  `sdkOutputCommitAndCancellationShareOneResultBoundary` test, preserving committed, uncommitted,
  and provider-failure output cleanup coverage. Commit
  `b82b782cd92b2dca8a37a53e4d1f0081b1789805` is superseded by the final amendment; focused,
  full, lint, help, size, whitespace, allowlist, reference-kit, clean-tree, and no-push evidence
  is recorded by this Step 6 result because this log is part of the amended commit.
- 2026-09-06 Step 6 revision 4: test-integrity review `comm-001556` reopened four boundary
  regressions. `CommandCatalogParityTests.swift` now owns literal accepted role-command,
  option, and mutation inventories instead of reading production classifiers. The execution suite
  synchronizes all 132 limiter submissions before cancelling 128 queued calls and asserts prompt
  completion; covers thrown, missing-response, overflow, rejected-status, and malformed-response
  outcomes for both mutation and read-only calls; and proves through the SDK that rendered argv
  aggregation, post-construction provider-body expansion, and cancellation during iterative
  catalog traversal stop before transport. Internal test seams observe submission/traversal only;
  production defaults remain no-op. Commit `4b11237f960fa85edc782270bc9b5ddf38d77c0a` is
  superseded by the final amendment, whose focused/full/lint/allowlist/clean/no-push evidence is
  reported by this Step 6 result because this log is part of the amend.
- 2026-09-06 Step 6 revision 5: self-review `comm-001558` required exact outcome and remaining
  deadline coverage. The post-dispatch mutation/read matrix now asserts mutation exit 5 and the
  exact non-retryable reconciliation envelope, plus read exit codes. The execution suite proves
  deadline publication while iterative catalog traversal remains paused and proves both task
  cancellation and deadline interrupt page-all accumulation before a blocked second page can
  complete. Commit `0206de49fe36235bfa02577cb1d2a60b11bbef28` is superseded by the final
  amendment; its verification, allowlist, clean-tree, and no-push evidence is reported by this
  Step 6 result because this log is amended with the feature commit.
- 2026-09-06 Step 6 revision 6: self-review `comm-001560` found that the page-all fixture blocked
  inside transport rather than at the local accumulation boundary. The SDK now forwards a
  fixture-only page-all accumulation observer to `GatewayCommandRunner`; the regression pauses
  after retaining the first real page and before the next cancellation check, then proves both
  task cancellation and deadline return before a second request can begin. Commit
  `a2c2f026380f057b8a74ac693baf0da01615b530` is superseded by the final amendment; its focused,
  full, lint, allowlist, clean-tree, and no-push evidence is reported by this Step 6 result because
  this log is amended with the feature commit.
- 2026-09-06 Step 6 revision 7: self-review `comm-001562` found that observing probe exit alone
  could race the resumed page-all worker. The page-all regression now shares a capacity-one
  limiter with a subsequent dry-run SDK invocation; its successful completion proves the cancelled
  worker has returned before asserting no second provider request occurred. Commit
  `8c44624c66212f3f99fc85f119c3cb0bac5530e2` is superseded by the final amendment; its focused,
  full, lint, allowlist, clean-tree, and no-push evidence is reported by this Step 6 result because
  this log is amended with the feature commit.
- 2026-09-06 Step 6 revision 8: test-integrity review `comm-001565` found a permissive
  success-or-unknown assertion after mutating response admission. The response-admission fixture
  now pauses immediately after a successful DELETE response is admitted; the test cancels before
  local parsing or envelope publication, requires exit 5 and the exact non-retryable
  `OUTCOME_UNKNOWN` envelope, then proves the paused worker exits before capacity-one limiter
  reuse. Commit `25c60855967fe9e8ace1026600849dd4e62ecdc6` is superseded by the final amendment;
  its focused, full, lint, allowlist, clean-tree, and no-push evidence is reported by this Step 6
  result because this log is amended with the feature commit.
- 2026-09-06 Step 6 revision 9: Step 7 review `comm-001569` found that generic catalog-source
  preflight incorrectly applied the single-token limit to repeatable list values. Source preflight
  now applies only the 2 MiB aggregate bound; command-normalized argv validation applies the 64
  KiB ceiling to each emitted token and retains the aggregate argv bound. Execution-boundary
  coverage proves two 40 KiB `values batch-get` ranges build and dry-run successfully, while an
  oversized inline JSON token fails through both `buildArgv` and `invoke` before transport.
  Commit `126613a82bbd5f5e75b79546231c86cce0a9e8ef` is superseded by the final amendment; its
  focused, full, lint, allowlist, clean-tree, and no-push evidence is reported by this Step 6
  result because this log is amended with the feature commit.
- 2026-09-06 Step 6 revision 10: Step 7 review `comm-001573` found that catalog key accounting
  serialized unbounded keys, wide traversal queued children before capacity checks, and SDK-only
  final-body/page-all budgets affected direct runner compatibility. Key accounting now checks
  escaped scalars incrementally against the remaining budget with cancellation; child counts are
  rejected before traversal-stack growth; runner final-body and page-all aggregate limits apply
  only when the SDK supplies a bounded execution budget. Execution regressions cover oversized
  escaped keys, a pre-stack-rejected wide container, direct-runner final-body compatibility, and
  direct page-all compatibility beyond the SDK aggregate budget. TASK-GSDK-008 now explicitly
  designates the workflow payload as the authoritative final-SHA record because this progress log
  is committed in the final amendment. Commit `3df3751738ff3c76a9afe063a943a2fd430b92c1` is
  superseded by the final amendment; focused, full, lint, allowlist, clean-tree, reference-kit,
  and no-push evidence is reported by its Step 6 result.
- 2026-09-06 Step 6 revision 11: self-review `comm-001575` found that the oversized-key and
  wide-container regressions observed only eventual rejection. Added a fixture-only escaped-scalar
  counter and use the existing traversal seam to require that escaped-key counting stops exactly
  at the aggregate budget and a rejected wide container visits only its root before child-stack
  growth. Commit `d20d9b2beccc836ddf4b01adb140c161becce4f5` is superseded by the final
  amendment; focused, full, lint, allowlist, clean-tree, reference-kit, and no-push evidence is
  reported by its Step 6 result because this log is part of the amended feature commit.
- 2026-09-06 Step 6 revision 12: Step 7 review `comm-001579` reopened TASK-GSDK-004, TASK-GSDK-007,
  and TASK-GSDK-008 for overwrite destination races and incomplete SDK documentation. Overwrite
  publication now retains its authorized parent descriptor, records the approved regular-file
  identity, atomically swaps the staged output with the destination, validates the displaced
  entry, and swaps back on any pathname replacement. The file-boundary regression deterministically
  replaces an approved destination after staging and proves rejection, retained replacement bytes,
  and staging cleanup. README now documents finite catalog/body/response limits, inline-only SDK
  credential environments with ignored path variables and constructor-only file-backed profiles,
  and non-retryable post-dispatch `OUTCOME_UNKNOWN`. All focused suites, three 10-run no-build
  stability loops, build, 128-test full suite, lint, both help commands, test discovery, size,
  whitespace, disabled-test, reference-kit, allowlist, staged-secret, clean-tree, and no-push
  checks passed. Commit `f0a88267ac698ba8ee6d156d3eb3546ca750df6a` is superseded by the final
  amendment; its final SHA is authoritative in the Step 6 workflow payload.
- 2026-09-06 Step 6 revision 13: self-review `comm-001581` found that an unsuccessful cleanup of
  the displaced pre-overwrite output could be ignored after `RENAME_SWAP`, and that the preceding
  workflow payload contained a truncated/incorrect final SHA. Overwrite publication now rolls back
  when removal of the displaced entry fails, retaining deferred cleanup ownership; a deterministic
  file-boundary regression requires rollback, two cleanup attempts, preserved approved bytes, and
  no staging artifact. This amendment supersedes
  `ae0378a193087dcaa6e3da592c456130c508c907`; the Step 6 payload emitted after its commit records
  the exact final SHA required by TASK-GSDK-008. Focused, stability, full, lint, help, discovery,
  size, whitespace, secret, allowlist, reference-kit, clean-tree, and no-push gates are rerun and
  recorded with that payload.
- 2026-09-06 Step 6 revision 14: Step 7 review `comm-001585` found that a cancelled queued
  `BlockOperation` still strongly retained its call closure until a saturated limiter admitted it.
  `GatewaySDKExecutionLimiter` now stores each closure in cancellation-cleared locked indirection;
  terminal cancellation drops request, environment, facade, latch, and dependency state before the
  retained queue operation can run. The execution-boundary regression saturates capacity one,
  cancels a queued call-state token, proves its deallocation while the active worker remains
  blocked, then releases and drains that worker. Commit `9bb9884c32dcf2349ed5f83cb8ec0fcc05db0073`
  is superseded by the final amendment; focused, stability, full, lint, help, discovery, size,
  whitespace, secret, allowlist, reference-kit, clean-tree, and no-push evidence is reported by
  the exact final-SHA Step 6 workflow payload because this progress log is committed with it.
- 2026-09-06 Step 6 revision 15: test-integrity review `comm-001588` found load-sensitive polling
  in the file-boundary snapshot cancellation regression. `BlockingSDKFixtureTransport` now signals
  deterministic provider entry and cancellation/deadline termination. The regression requires
  entry before cancellation or deadline, then capacity-one dry-run reuse after termination to prove
  the worker returned and snapshot cleanup completed without timing polls. The previous commit
  `a7dcd807fd0ea5c9cf9b3d4421578d54b4262588` is superseded by the final amendment; focused,
  file-boundary/full stability, build, lint, help, discovery, size, whitespace, secret, allowlist,
  reference-kit, clean-tree, and no-push evidence is reported by the exact final-SHA Step 6 payload.
- 2026-09-06 Step 6 revision 16: self-review `comm-001590` found that the first remediation still
  allowed short deadlines to race provider entry or explicit task cancellation. The explicit
  cancellation path now uses a five-second non-competing deadline after provider-entry
  synchronization; the deadline path uses a two-second bounded execution window, then requires
  exact `OUTCOME_UNKNOWN`, provider termination, capacity-one reuse, and snapshot
  cleanup. Fixture signal waits are bounded at five seconds rather than one-second load-sensitive
  waits. This amendment supersedes `3fbc94b076e3686f6967adae32bc2d4c25a7b6c3`; focused,
  stability, full, lint, help, discovery, size, whitespace, secret, allowlist, reference-kit,
  clean-tree, and no-push evidence is reported by the exact final-SHA Step 6 payload.
- 2026-09-06 Step 6 revision 17: Step 7 review `comm-001594` found that catalog file preparation
  preceded required-variable/type binding and that read-only injected transports could surface
  non-transport `GatewayError` values as local failures. Catalog requests now render and validate
  original variables before authorizing or snapshotting any file, then render again after snapshot
  substitution; the operation-run router exposes the same dependency injection used to prove both
  paths leave authorization and snapshot counters at zero for invalid bindings. Bounded transport
  now preserves intentional `transportFailure` messages but normalizes every other post-dispatch
  error to retryable `TRANSPORT_FAILURE`. Focused, full, lint, allowlist, clean-tree, and no-push
  evidence is recorded by the exact final-SHA Step 6 workflow payload after this amendment.
- 2026-09-06 Step 6 revision 18: self-review `comm-001596` found that raw argv preparation had
  accidentally applied catalog binding both before deciding whether a file boundary existed and
  again after snapshot substitution. Only raw requests that carry a file input now bind before
  authorization; raw non-file commands continue unchanged to `GatewayCommandRunner`, preserving
  its validation envelope exactly. Removing the post-snapshot rebuild also removes the only
  throwing path that could retain private snapshots before ownership reached the caller's cleanup
  defer. A regression compares an invalid non-file raw SDK request with direct runner output and
  proves neither path admits authorization or transport. This amendment supersedes
  `f860f02328e288e715a418bb8cff2e09b2f549fe`; focused, stability, full, lint, help, discovery,
  size, whitespace, secret, allowlist, reference-kit, clean-tree, and no-push evidence is
  reported by the exact final-SHA Step 6 workflow payload.
- 2026-09-06 Step 6 revision 19: self-review `comm-001598` found that raw snapshot cleanup was
  inferred from the shared prepared-argument defer but not directly exercised. A deterministic
  raw `execute` regression now creates a private batch-update snapshot, injects a post-dispatch
  transport failure, and proves the owner-only recorded snapshot is removed after the failure
  envelope. This amendment supersedes `bf76dcb4c6fc931b10e8cc93ec623d0b28c6e0c7`; focused,
  stability, full, lint, help, discovery, size, whitespace, secret, allowlist, reference-kit,
  clean-tree, and no-push evidence is reported by the exact final-SHA Step 6 workflow payload.
- 2026-09-06 Step 6 revision 20: the first full-suite stability rerun exposed a timing-sensitive
  pre-existing bounded-execution test: polling could let a queued binding execute before the
  active preparation worker had entered. `PreparationProbe` now signals deterministic worker
  entry, and the test waits on that signal before asserting the queued deadline boundary. This
  amendment supersedes the revision 19 worktree; final verification evidence is reported by the
  exact final-SHA Step 6 workflow payload.
- 2026-09-06 Step 6 revision 21: self-review `comm-001600` found that worker entry alone did not
  retain limiter capacity after the old 80ms sleep elapsed. The active preparation worker now waits
  on a release gate; the test observes the queued terminal envelope while capacity is still held,
  then releases and awaits the active operation. This amendment supersedes the revision 20
  worktree; final verification evidence is reported by the exact final-SHA Step 6 workflow payload.
- 2026-09-06 Step 6 revision 22: adversarial review `comm-001605` found three production-boundary
  gaps. Overwrite publication now performs its final destination identity check before `RENAME_SWAP`;
  no validation can fail after publication, and a failed rollback retains the displaced prior inode
  while reporting non-retryable `OUTCOME_UNKNOWN` for operator recovery. Catalog snapshots retain
  bounded bytes captured from the authorized descriptor and provide them directly to SDK and
  `operation run` runner execution,
  so a replacement of the private snapshot pathname cannot change the request body or trigger an
  unbounded reopen; descriptor-relative cleanup is checked and its failure is surfaced to the SDK
  caller. The execution limiter now permits at most 256 waiting calls in addition to active workers,
  rejecting overload before queue admission and cancelling deadline state. File and execution
  boundary regressions cover failed overwrite rollback/recovery, post-capture snapshot replacement,
  and finite-queue overload plus limiter reuse. This amendment supersedes
  `5f5d07395d11e76302964ff004808cf0ae416be4`; focused, stability, full, lint, help, discovery,
  size, whitespace, secret, allowlist, reference-kit, clean-tree, and no-push evidence is reported
  by the exact final-SHA Step 6 workflow payload.
- 2026-09-06 Step 6 revision 23: self-review `comm-001607` corrected the authoritative staging
  allowlist to 24 paths by adding `Sources/GoogleDocumentsGatewayCore/GatewayRuntime.swift`, the
  necessary owner of bounded snapshot-byte body construction. Overwrite publication now validates
  the displaced inode after `RENAME_SWAP`; a destination replacement in the validation-to-swap
  interval preserves recovery data and reports non-retryable `OUTCOME_UNKNOWN` instead of success.
  Snapshot cleanup failures now supersede preparation or post-snapshot rendering failures while
  retaining cleanup state until its retry attempt. File-boundary regressions cover the new
  overwrite interval and observable cleanup failure. This amendment supersedes the revision 22
  worktree; focused, stability, full, lint, help, discovery, size, whitespace, secret, 24-path
  allowlist, reference-kit, clean-tree, and no-push evidence is reported by the exact final-SHA
  Step 6 workflow payload.
- 2026-09-06 Step 6 revision 24: self-review `comm-001609` found that a post-run snapshot cleanup
  failure could replace a dispatched mutating result with `INVALID_ARGUMENT`, and that an
  unrecoverable cleanup failure could retain the private snapshot-directory descriptor after state
  destruction. SDK raw and catalog execution now preserve exact non-retryable `OUTCOME_UNKNOWN`
  whenever the recorded dispatch crossed a mutating/non-idempotent boundary; local pre-dispatch
  cleanup failures retain their local envelope. Snapshot cleanup still reports failed unlinking to
  the caller, but final destruction always closes its directory descriptor. File-boundary
  regressions cover successful, provider-rejected, and transport-failed dispatched mutations,
  non-dispatched cleanup behavior, and descriptor release after an unrecoverable unlink failure.
  The focused `GatewaySDKSnapshotCleanupTests.swift` split keeps every Swift file under 1,000 lines,
  expanding the final allowlist to 25 paths. This amendment supersedes the revision 23 worktree;
  final verification evidence is reported by the exact final-SHA Step 6 workflow payload.
- 2026-09-06 Step 6 revision 25: self-review `comm-001611` found that `operation run` could
  replace a post-dispatch mutating result with a local cleanup `INVALID_ARGUMENT`, and that the
  previous revision had been committed separately rather than as the plan-required amended feature
  commit. Operation-run now wraps its transport with the same remote-dispatch recording boundary,
  preserves exact non-retryable `OUTCOME_UNKNOWN` after a destructive request begins, and retains
  local cleanup failures for dry runs. Snapshot-cleanup coverage includes successful,
  provider-rejected, transport-failed, and already-uncertain operation-run cases plus the dry-run
  control. The then-current unpushed feature commit is amended to one 25-path diff so the recorded
  `HEAD^..HEAD` allowlist commands are truthful; this revision supersedes
  `951eb5ff56bf2e51f87967ce6adbf369acb2e9de`.
- 2026-09-06 Step 6 revision 26: self-review `comm-001613` found a stale 24-path completion
  statement and missing current-revision records for the focused facade suite and dedicated
  facade/CLI stability loop. The completion criterion now agrees with the 25-path allowlist;
  `GoogleDocumentsGatewaySDKTests` and ten no-build reruns each for
  `GoogleDocumentsGatewaySDKTests` and `GatewaySDKCLITests` pass. This amendment supersedes
  `8629bd33cb34bac50ed435dfca7d78519af5b677`; the exact final SHA, clean-tree, and no-push
  evidence are reported by the final Step 6 workflow payload.
- 2026-09-06 Step 6 revision 27: Step 7 review `comm-001617` found trapping arithmetic when
  `maximumConcurrentOperations` is `Int.max` and a stale 23-path design rollout allowlist. The
  limiter now uses checked addition and saturates its finite pending capacity at `Int.max`; a
  public-facade dry-run regression constructs that policy and proves forward progress. The design
  rollout list now matches this plan and the committed 25-path feature scope by explicitly naming
  `GatewayRuntime.swift` and `GatewaySDKSnapshotCleanupTests.swift`. Focused execution tests,
  build, full suite, lint, whitespace, allowlist, and clean-tree evidence are rerun before the
  final amendment; no push occurs.
- 2026-09-06 Step 6 revision 28: test-integrity review `comm-001638` found that the FIFO
  diagnostic regression accepted a timeout exit in place of the required authentication result.
  The regression now keeps both FIFO writer probes active, requires exact `AUTH_REQUIRED` exit 4
  for `config validate`, `auth status`, and `doctor`, proves neither FIFO is opened, retains zero
  provider transport calls, and preserves capacity-one limiter reuse. Focused execution tests,
  full suite, lint, scope, and clean-tree checks are rerun before the final amendment; no push
  occurs.
- 2026-09-06 Step 6 revision 29: adversarial review `comm-001643` found unreconciled retries of
  rejected destructive resumable chunks, non-cancellable ordinary-response processing, and raw
  argv memory amplification. Bounded SDK uploads now stop after a rejected final chunk rather
  than resend it and return exact `OUTCOME_UNKNOWN`; the direct runner retains its established
  retry behavior. Ordinary bounded responses now check cancellation after receipt and decode and
  before serialization, while a streaming UTF-8 structural preflight caps nesting at 128 and
  structural values at 16,384 before Foundation decoding. Raw argv similarly streams and caps
  root-array elements at 16,384 before decoding. Regressions prove a rejected final chunk is not
  retried, wide raw argv is rejected, and wide provider JSON is rejected before Foundation
  decoding. Focused, build, full-suite, lint, size, scope, secret, and clean-tree evidence is
  rerun before the final amendment; no push occurs.
- 2026-09-06 Step 6 revision 30: self-review `comm-001645` found two remaining current-facing
  references to a superseded 23-path staging scope. Updated the addressed-feedback and
  dirty-worktree mitigation statements to the authoritative 25-path allowlist; historical
  revision records remain unchanged. `git diff --check` and a targeted stale-current-claim search
  pass before the final amendment; no push occurs. The exact final SHA and clean-tree evidence are
  reported by the final Step 6 workflow payload because this log is part of that amendment.
- 2026-09-06 Step 6 revision 31: Step 7 review `comm-001649` found that Drive `--page-all`
  decoded each successful provider page before applying the SDK structural limit. The paginated
  path now runs the cancellable bounded JSON structural preflight before `JSONSerialization` for
  every successful page. `sdkPageAllRejectsWideProviderPageBeforeAccumulation` supplies a
  16,385-value `files list` page and requires `RESPONSE_LIMIT_EXCEEDED`, one transport call, and
  zero accumulation events. Focused execution tests, full suite, lint, size, and whitespace checks
  pass before the final amendment; no push occurs.
- 2026-09-06 Step 6 revision 32: Step 7 review `comm-001653` reopened TASK-GSDK-003 because
  successful Drive mutation-preflight responses decoded before structural preflight. The preflight
  now checks cancellation after receipt, bounds JSON structure before Foundation decoding, and
  checks cancellation again after decoding. `sdkMutationPreflightRejectsWideProviderResponseBeforeDecoding`
  requires `RESPONSE_LIMIT_EXCEEDED` and exactly one preflight request for a 16,385-value response.
  Refresh deadline coverage now waits for deterministic transport entry and termination signals
  instead of racing scheduled workers. Focused execution tests, full suite, lint, size, and
  whitespace checks pass before the final amendment; no push occurs.
- 2026-09-06 Step 6 revision 33: test-integrity review `comm-001656` reopened the pre-decode
  regression evidence. Internal raw-document and provider-response decode seams now count entry
  deterministically. Wide raw argv, ordinary provider JSON, Drive page-all pages, and Drive
  mutation-preflight responses each require zero decoder entries alongside their existing limit
  result assertions. Focused structural-boundary tests, the execution and CLI suites, full suite,
  lint, size, and whitespace checks pass before the final amendment; no push occurs.
- 2026-09-06 Step 6 revision 34: adversarial review `comm-001661` reopened resumable upload,
  page-all success integrity, and SDK OAuth refresh handling. Resumable 308 replies now validate
  the acknowledged Range, advance only to its confirmed next byte, and accept an updated approved
  Location; missing or invalid progress stops without another chunk. Page-all requires the
  operation collection array and string paging tokens on every page. Bounded OAuth refresh checks
  cancellation and shared JSON structure before its injected token decoder, then checks
  cancellation again. Regressions cover partial/no-Range upload recovery, malformed first/later
  pages, and a wide refresh response with zero token-decoder calls plus limiter reuse. Focused,
  full-suite, lint, size, whitespace, scope, and clean-tree checks pass before the final
  amendment; no push occurs.
- 2026-09-06 Step 6 revision 35: adversarial review `comm-001666` found that nested raw argv
  could reach Foundation decoding, failed output-staging cleanup could be silently discarded, and
  `Int.max` concurrency removed the limiter's practical bound. Raw argv now uses a streaming flat
  JSON-string-array validator before decoding, including structural, token, aggregate, and
  cancellation checks. Failed staging cleanup now returns a recovery path and retains ownership;
  failed overwrite rollback continues to report its recovery artifact. Public concurrency is
  clamped to 64 workers and 256 waiting calls, including when callers supply `Int.max`.
  Regressions cover nested/node-flood raw documents with zero decoder entries, cancellation before
  raw decode, persistent cleanup failure across write/sync/cancellation/no-overwrite/rollback
  paths, and normalized limiter capacity with reuse. Focused, full-suite, lint, size, whitespace,
  scope, and clean-tree checks pass before the final amendment; no push occurs.
- 2026-09-06 Step 6 revision 36: self-review `comm-001668` required proof and contract alignment
  for retained cleanup ownership, `Int.max` saturation, and in-flight raw traversal cancellation.
  `GatewaySDKFileAccessPolicy` now keeps failed staging cleanup in a descriptor-bound registry,
  exposes recoveries, and releases each descriptor only after `retryPendingOutputCleanup()` unlinks
  it. The `Int.max` limiter regression suspends, saturates all 64 active plus 256 queued slots,
  observes overload rejection and bounded active execution, then drains and reuses the limiter.
  A synchronized 16,385-node raw preflight cancels after traversal begins and proves zero decoder
  entries. The design, README, and task criteria now state the exact 64-worker/256-waiter and
  observable cleanup-recovery contracts. Focused, full-suite, lint, build, help, reference,
  size, whitespace, scope, and clean-tree checks pass before the final amendment; no push occurs.
- 2026-09-06 Step 6 revision 37: self-review `comm-001670` found that the raw traversal test
  collapsed cancellation into generic failure and cleanup retries briefly hid unresolved artifacts.
  The raw node-flood regression now requires the exact cancellation transport failure and zero
  decoder calls. Cleanup retries retain entries while unlinking, serialize concurrent callers, and
  remove/close only successful entries; a blocked-unlink regression proves concurrent query/retry
  still sees the recovery, then verifies eventual removal. Design and task criteria now make that
  atomic visibility explicit. Focused, full-suite, lint, build, help, reference, size, whitespace,
  scope, and clean-tree checks pass before the final amendment; no push occurs.
- 2026-09-06 Step 6 revision 38: self-review `comm-001672` found that the concurrent cleanup
  recovery fixture used one-second waits and could silently unblock cleanup before its in-flight
  assertions under load. The fixture now uses the established five-second synchronization window
  and returns unlink failure if test-owned release does not arrive, preserving recovery ownership
  rather than completing cleanup. Focused file-boundary, stability, full-suite, lint, size,
  whitespace, scope, and clean-tree checks pass before the final amendment; no push occurs.
- 2026-09-06 Step 6 rerun (session 120): rechecked the accepted design and all carried high/mid
  findings. Drive mutation preflight now observes cancellation immediately before and after
  Foundation decoding, after structural preflight. Descriptor-bound filesystem traversal observes
  the call cancellation token at every root/intermediate/leaf boundary. Cleanup retries retain
  entries during unlink, serialize concurrent callers, and now treat an explicit public retry as
  the caller's post-reconciliation cleanup decision for a local `OUTCOME_UNKNOWN` overwrite;
  its envelope preserves a machine-readable `recovery_path`. The file-boundary regression proves
  that retry clears the retained descriptor only after successful unlink. Current-session focused,
  full, lint, build, help, size, whitespace, reference, scope, and clean-tree evidence follows
  before the final amendment; no push occurs.
- 2026-09-06 Step 6 session-120 verification: `swift test --filter
  GatewaySDKExecutionBoundaryTests` passed 35 tests; `swift test --filter
  GoogleDocumentsGatewaySDKFileBoundaryTests` passed 23 tests; and `swift test --filter
  GatewaySDKCLITests` passed 14 tests. `mise run build`, `mise run test` (150 tests), `mise run
  lint` (exit 0; one feature-introduced non-serious `GatewayCLI` type-body-length warning), `mise run
  gateway:help`, and `swift run google-documents-gateway --help` passed. `git diff --check`, the
  under-1,000-line gate, and reference-kit SHA/clean-status checks passed. The local feature
  commit is amended only after this plan entry is staged; no push occurs.
- 2026-09-06 Step 6 session-120 review revision (`comm-001680`): an uncertain local overwrite
  publication now transitions the commit latch to terminal while it is still locked, before
  `writeOutput` registers descriptor-owned recovery. Therefore a waiting task/deadline
  cancellation cannot publish `TRANSPORT_FAILURE` in place of the recovery-bearing
  `OUTCOME_UNKNOWN` envelope. `sdkOverwriteReportsOutcomeUnknownAndRetainsRecoveryWhenRollbackFails`
  deterministically blocks failed rollback cleanup, starts cancellation in the held commit window,
  then requires `OUTCOME_UNKNOWN`, `recovery_path`, and pending cleanup ownership. Focused,
  full, lint, build, help, size, whitespace, reference, scope, and clean-tree evidence follows
  before the amendment; no push occurs.
- 2026-09-06 Step 6 session-120 review-revision verification: `swift test --filter
  GoogleDocumentsGatewaySDKFileBoundaryTests` passed 23 tests and `swift test --filter
  GatewaySDKExecutionBoundaryTests` passed 35 tests. `mise run build`, `mise run test` (150
  tests), and `mise run lint` passed; lint retains the pre-existing non-serious
  `GatewayCLI` type-body-length warning. Whitespace and under-1,000-line gates passed. The local
  feature commit is amended after this entry is staged; no push occurs.
- 2026-09-06 Step 6 session-123 rerun: addressed all carried mid findings from
  `codex-design-and-implement-review-loop-session-122`: output cleanup retry now requires the
  stable recovery UUID and cannot unlink another request's artifact
  (`GatewaySDKFileAccessPolicy.swift`); snapshot unlink failure transfers the live
  descriptor-bound cleanup state to the SDK-owned registry, exposes a stable recovery UUID, and
  supports targeted retry without abandoning private input (`GatewaySDKCatalogFileSnapshots.swift`,
  `GoogleDocumentsGatewaySDK.swift`); and refreshed file-backed tokens persist only inside the
  cancellation commit boundary (`GatewaySDKCredentialLoading.swift`). The persistence regression
  moved to `GatewaySDKCredentialPersistenceTests.swift`, expanding the allowlist to 26 paths to
  keep `GatewaySDKExecutionBoundaryTests.swift` at 999 lines. Current focused suites passed:
  snapshot cleanup (4), credential persistence (1), file boundary (23), and execution boundary
  (35); legacy facade and CLI suites each passed ten no-build reruns. `mise run build`, `mise run
  test` (151 tests), `mise run lint` (exit 0; one feature-introduced non-serious GatewayCLI
  type-body-length warning), both help commands, `git diff --check`, the under-1,000-line gate,
  and reference-kit SHA/clean checks passed. Author self-check found no unresolved high/mid
  findings, unrelated paths, or verification gaps. The one local feature commit is amended after
  explicit 26-path staging; no push occurs.
- 2026-09-06 Step 6 session-124 implementation self-check: confirmed the accepted design remains
  the implementation contract and revalidated the session-123 remediation without scope expansion.
  Stable UUID-targeted recovery now prevents one output cleanup retry from unlinking another
  request's artifact; failed private input snapshot cleanup retains its descriptor-bound state in
  the SDK registry until the caller retries that exact recovery; and refreshed file-backed tokens
  cross the cancellation commit boundary before persistence. Focused suites passed: snapshot
  cleanup (4), credential persistence (1), file boundary (23), execution boundary (35), facade
  (4), and CLI (14). `swift test` passed the full 151-test suite; `mise run build`, `mise run
  lint` (exit 0; one feature-introduced non-serious `GatewayCLI` type-body-length warning), `mise run
  gateway:help`, and `swift run google-documents-gateway --help` passed. `git diff --check`, the
  under-1,000-line gate, reference-kit SHA `4d4b56c686f6875defccb54f74e2276022eb524e` and clean
  status checks passed before the scoped amendment. No unresolved high or mid findings, unrelated
  paths, or verification gaps remain. The authorized local feature commit is amended with the
  explicit 26-path allowlist; no push occurs.
- 2026-09-06 Step 6 session-124 test-integrity revision (`comm-001686`): addressed both carried
  mid findings without widening the public API. `sdkSnapshotCleanupRetriesOnlyTheRequestedPublicRecovery`
  creates two failed regular snapshots through `GoogleDocumentsGatewaySDK`, exercises
  `pendingSnapshotCleanupRecoveries`, retries one public recovery UUID, proves the other remains
  owned and present, then clears it independently. `sdkFileBackedTokenPersistenceCompletesAfterCommitBeatsCancellation`
  pauses inside the admitted `GatewaySDKCancellation.commit` closure, initiates task cancellation,
  then proves cancellation loses, the refreshed store persists, the public SDK invocation succeeds,
  and the provider request completes. The existing cancellation-wins persistence regression remains.
  `mise exec -- swift test --filter GatewaySDKSnapshotCleanupTests` passed 4 tests and
  `mise exec -- swift test --filter GatewaySDKCredentialPersistenceTests` passed 2 tests;
  `mise run test` passed 152 tests; `mise run build`, `mise run lint`, `git diff --check`, and the
  under-1,000-line gate passed. SwiftLint retains only the feature-introduced non-serious GatewayCLI
  type-body-length warning. No unresolved high or mid findings or verification gaps remain; amend
  the authorized 26-path local feature commit and do not push.
- 2026-09-06 Step 6 session-124 descriptor-lifetime revision (`comm-001688`): retained the
  public two-recovery facade regression and restored the removed descriptor-lifetime proof.
  `sdkSnapshotCleanupRetriesOnlyTheRequestedPublicRecovery` injects two distinct authorized
  directory descriptors and a deterministic close probe. It proves neither descriptor closes
  while both recoveries are retained; retrying the first public UUID closes only its descriptor;
  retrying the second closes both descriptors exactly once. Focused snapshot cleanup, full
  `mise run test`, `mise run build`, `mise run lint`, whitespace, under-1,000-line, reference-kit,
  scope, and clean-tree evidence pass before the final amendment. SwiftLint retains only the
  feature-introduced non-serious GatewayCLI type-body-length warning; no push occurs.
- 2026-09-06 Step 6 session-124 adversarial revision (`comm-001692`): removed invocation-wide
  cancellation commitment from file-backed token persistence. The authorizer now checks
  cancellation before and after the atomic local replacement, so persistence may complete while a
  waiting task/deadline cancellation still prevents subsequent provider preflight and dispatch.
  `sdkCancellationAfterCredentialPersistenceStopsDestructiveDispatch` uses an expired
  constructor-injected Drive-write credential, waits until the refreshed token is stored, requests
  cancellation in a deterministic post-persistence window, and proves exit 5
  `TRANSPORT_FAILURE` with only the OAuth refresh transport call and zero folder-create dispatches.
  The cancellation-before-persistence regression remains. Focused credential persistence (2) and
  snapshot cleanup (4), full `mise run test` (152 tests), `mise run build`, `mise run lint`,
  whitespace, under-1,000-line, reference-kit, scope, and clean-tree evidence pass before the
  authorized local feature-commit amendment. SwiftLint retains only the pre-existing non-serious
  `GatewayCLI` type-body-length warning; no unresolved high or mid findings, no verification gaps,
  and no push.
- 2026-09-06 Step 6 session-124 test-integrity revision (`comm-001694`): the destructive-dispatch
  regression now waits, with a five-second bound, for `task.cancel()` to return before releasing
  the post-persistence barrier. A `defer` releases the barrier on every early test exit, preventing
  a blocked worker. The test therefore establishes cancellation state before allowing the
  authorizer's post-persistence check and requires persisted credentials, exit 5
  `TRANSPORT_FAILURE`, and exactly one OAuth refresh call (zero folder-create dispatches). Focused
  credential persistence (2) and snapshot cleanup (4), full `mise run test` (152 tests),
  `mise run build`, `mise run lint`, whitespace, under-1,000-line, reference-kit, scope, and
  clean-tree evidence pass before the authorized local feature-commit amendment. SwiftLint retains
  only the feature-introduced non-serious `GatewayCLI` type-body-length warning; no unresolved high or
  mid findings, no verification gaps, and no push.
- 2026-09-06 Step 6 session-124 adversarial revision (`comm-001698`): resumable Drive uploads now
  accept a 2xx final response only for the chunk ending at the complete input length; a premature
  2xx stops transmission and returns `OUTCOME_UNKNOWN`. The default facade cleanup registry is a
  documented process-lifetime recovery owner, and short-lived registries transfer retained states
  to it on deinitialization, preserving descriptor-relative retry by the same UUID through a new
  facade. File-backed credential refreshes are single-flight per standardized token-store path;
  waiters reread under the lock and reuse a fresh store rather than issuing or persisting another
  refresh. Regressions cover premature `files upload` and `files replace-content` completion,
  recovery after facade release, and two concurrent public SDK calls with one OAuth refresh and a
  consistent persisted token. The plan header now names session-124 and the authoritative feature
  allowlist remains 26 paths. Focused suites, full `mise run test`, build, lint, whitespace,
  under-1,000-line, reference-kit, scope, and clean-tree evidence pass before the authorized local
  feature-commit amendment; no unresolved high or mid findings, no verification gaps, and no push.
  One initial parallel full-suite run recorded timing-sensitive failures in existing limiter and
  admission tests; the immediate rerun passed all 155 tests.
- 2026-09-07 Step 6 session-124 review revision (`comm-001701`): same-token-store refresh locking
  now polls with a five-millisecond bound and checks `GatewaySDKCancellation` before and after
  lock acquisition, so a cancelled/deadline waiter exits rather than retaining execution-limiter
  capacity. `sdkCancelledSingleFlightRefreshWaiterReleasesLimiterCapacity` blocks one public SDK
  refresh, proves a second call is waiting on that store, cancels it, and requires a queued
  public dry-run to complete while the first refresh is still blocked; it also requires exactly
  one OAuth refresh. Focused credential persistence, full `mise run test`, build, lint,
  whitespace, under-1,000-line, reference-kit, scope, and clean-tree evidence pass before the
  authorized local feature-commit amendment; no unresolved high or mid findings, no verification
  gaps, and no push.
- 2026-09-07 Step 6 session-124 test-integrity revision (`comm-001703` / `TEST-INTEGRITY-005`):
  replaced every remaining one-second fixture synchronization bound in
  `GatewaySDKTestSupport.swift` and `GoogleDocumentsGatewaySDKFileBoundaryTests.swift` with the
  documented five-second `gatewaySDKTestSynchronizationTimeout`. The existing semaphore entry
  handshakes remain mandatory before tests release blocked work or assert behavior, while their
  bounded window now tolerates Swift Testing's default parallel discovery load. Focused execution
  boundary (35), file boundary (23), and credential persistence (4) suites passed; five consecutive
  default `mise run test` executions passed. The follow-on build, lint, whitespace, under-1,000-
  line, reference-kit, scope, and clean-tree checks are recorded with the authorized local
  feature-commit amendment. No unresolved high or mid finding remains; no push occurs.
- 2026-09-07 Step 6 session-124 test-integrity revision (`comm-001705` / `TEST-INTEGRITY-006`):
  completed the fixture-handshake audit by replacing the remaining one-second waits in
  `GatewaySDKCLITests.swift` and `GatewaySDKExecutionBoundaryTests.swift` with
  `gatewaySDKTestSynchronizationTimeout`. The intentional 50-millisecond negative assertion that
  a blocked worker has not exited remains unchanged. CLI and execution-boundary suites plus five
  consecutive default `mise run test` executions are required before this amendment; no unresolved
  high or mid finding remains and no push occurs.
- 2026-09-07 Step 6 session-124 stability follow-up: default parallel discovery can schedule
  product work behind a test that synchronously waits on the Swift Testing executor. Added
  `gatewaySDKTestHandshake`, which performs every blocking positive fixture handshake on a
  user-initiated dispatch queue, and updated the credential-persistence, execution-boundary, and
  file-boundary tests to await it. The 50-millisecond negative assertion remains bounded at 50
  milliseconds but also runs through that helper. The page-all cancellation fixture starts its
  blocked invocation in a detached task so it cannot inherit a saturated test executor. This
  preserves the behavioral assertions while preventing test-worker starvation; CLI,
  execution-boundary, credential-persistence, and five consecutive isolated default-suite checks
  provide the current-session evidence for the amended commit.
- 2026-09-07 Step 6 session-124 test-integrity revision (`comm-001707` / `TEST-INTEGRITY-007`):
  `CredentialSecretFIFOProbe` replaced its 0.2-second waits and readiness sleep with the shared
  synchronization bound. This was further corrected by `TEST-INTEGRITY-008` because the initial
  pre-open signal did not prove the writer observer had entered a FIFO operation.
- 2026-09-07 Step 6 session-124 test-integrity revision (`comm-001709` / `TEST-INTEGRITY-008`):
  `CredentialSecretFIFOProbe` now signals only after a real nonblocking FIFO writer-open observes
  `ENXIO`; it then keeps polling so any unbounded reader rendezvous is recorded. This establishes
  an active observer without a readiness sleep or a pre-syscall signal, and teardown stops the
  observer without opening a cleanup reader. The remaining fixture five-second literals in test
  support, credential-persistence, and file-boundary suites now use
  `gatewaySDKTestSynchronizationTimeout`, so all mandatory fixture handshakes share one bound.
  `mise exec -- swift test --filter GatewaySDKExecutionBoundaryTests` passed 35 tests; five
  consecutive default `mise run test` executions each passed all 156 tests. `mise run build`,
  `mise run lint` (one feature-introduced non-serious `GatewayCLI` type-body-length warning),
  whitespace, shared-timeout audit, and the under-1,000-line gate also pass before the authorized
  local amendment; no push occurs.
- 2026-09-07 Step 6 session-124 test-integrity revision (`comm-001711` / `TEST-INTEGRITY-009`):
  `BlockingSDKFixtureTransport.waitForEntry` and `waitForTermination` now default to
  `gatewaySDKTestSynchronizationTimeout` rather than independent five-second literals. The
  timeout audit now rejects both direct five-second semaphore waits and five-second
  `TimeInterval` default parameters. `mise exec -- swift test --filter
  GoogleDocumentsGatewaySDKFileBoundaryTests` passed 23 tests and `mise run test` passed all 156
  tests before the authorized local amendment; no push occurs.
- 2026-09-07 Step 6 session-124 adversarial revision (`comm-001715`): operation-name routing now
  enters the limiter/deadline before catalog or option-inventory lookup and uses the same 64 KiB
  token bound as catalog argv. Input capabilities reject regular files with `st_nlink != 1` before
  snapshot, credential, or transport work, preventing approved-root hard-link aliases. README now
  documents targeted output and snapshot cleanup recovery collections and UUID retry APIs. The
  feature introduced the non-serious `GatewayCLI` type-body-length warning by increasing its body
  from 754 to 804 lines; the authoritative amended feature diff remains the exact 26-path
  allowlist, while earlier 24/25-path records describe superseded interim amendments. Focused
  facade (7) and file-boundary (23) suites plus default `mise run test` (158 tests), build, lint,
  whitespace, and under-1,000-line checks pass before the authorized local amendment; no push
  occurs.
- 2026-09-07 Step 6 session-124 test-integrity revision (`comm-001717` / `TEST-INTEGRITY-010`):
  the bounded-routing regression now holds a valid-sized fabricated operation behind the suspended
  limiter, then proves its exact kit `unknownOperation` envelope after resume. It separately pins
  the oversized-name generic `INPUT_TOO_LARGE` envelope, bounded raw-output behavior, and
  absence of the supplied name from its message and raw output. Focused facade and default full
  suite verification pass before the authorized local amendment; no push occurs.
- 2026-09-07 Step 6 session-124 adversarial revision (`comm-001721`): bounded SDK execution now
  passes cancellation through request-body validation. File-backed catalog JSON and raw inline
  `--json-values` structurally preflight at 128 nesting levels and 16,384 nodes before their
  injected Foundation decoder is entered. Regressions prove wide/deep file and raw JSON reject
  with zero decoder, credential, and transport activity; a paused preflight cancels, exits, and
  releases its one-slot limiter for a succeeding dry-run. The local commit message and verified
  feature diff both identify the authoritative 26-path scope. The runner and facade helpers were
  responsibility-split so SwiftLint is clean; no push occurs.
- 2026-09-07 Step 6 session-124 adversarial revision (`comm-001725`): output staging cleanup now
  holds the terminal cancellation boundary while a failed unlink registers its descriptor-owned
  recovery, and every cleanup envelope includes machine-readable `recovery_path`. Credential
  loading limits direct and decoded inline OAuth/token fields to 64 KiB, rechecks cancellation
  while constructing refresh form data, and serializes file-backed refreshes by `fstat` device and
  inode using a cross-process advisory lock. Regressions cover cancellation while staging unlink
  is blocked, an oversized plain `OAUTH_CLIENT_ID` before transport with limiter reuse, and two
  parent-symlink aliases of one expired token file performing exactly one refresh. Focused file,
  execution-boundary, and credential-persistence suites plus the complete default suite, build,
  lint, whitespace, size, scope, reference-kit, and clean-tree checks are required before the
  authorized local amendment; no push occurs.

## 2026-09-23 public dependency integration

The operator asked for the facade to resolve Riela's missing public dependency.
The retained `feat/gateway-sdk` branch was reconciled with v0.3.2 `main`,
including its XDG-state token migration. The one merge conflict in
`GatewayCLI.swift` preserves cancellation-aware bounded SDK token reads and
keeps synchronous legacy migration on the direct CLI path. A deterministic
queued-binding test amendment is `8617ce9`; the mainline merge is `92261e5`.
The manifest now pins public `GatewaySDKKit` 0.1.0 at revision
`4d4b56c686f6875defccb54f74e2276022eb524e`, with no local path dependency.

On the merged, URL-pinned tree, `mise run build` passed, `mise run test` passed
170 tests, `mise run lint` reported zero violations, and
`mise run gateway:help` passed for all six role executables. The focused
pre-merge `GatewaySDKExecutionBoundaryTests` passed 35 tests. Both
`git diff --check` and `git diff --cached --check` passed during merge resolution.
Publication and the downstream Riela pin remain separate, unverified steps;
this entry does not claim either is complete.
