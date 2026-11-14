# Human-Readable Request Input

**Status**: Implementation revised; review and live verification pending
**Workflow Mode**: `issue-resolution`
**Issue Reference**: `workflow-input:human-readable-request-input-ux`
**Design Reference**: `design-docs/specs/design-human-readable-request-input.md#command-contract`
**Risk**: High; retain adversarial review through completion

## Purpose

Add bounded, readable input flags for common Docs, Sheets, and Drive writes
without weakening the six fixed executable roles, exact OAuth scopes,
fail-closed validation, structured output, dry-run redaction, mutation
preconditions, or advanced raw-input compatibility.

## Reference trace and intentional divergences

Use `googleworkspace/cli` commit
`a3768d0e82ad83cca2da97724e46bea4ff0e6dbd` as a behavioral reference only:

- `/tmp/googleworkspace-cli.tFfy8o/crates/google-workspace-cli/src/helpers/sheets.rs`
  informs comma-split `--values`, JSON row `--json-values`, and generated
  Sheets value bodies.
- `/tmp/googleworkspace-cli.tFfy8o/crates/google-workspace-cli/src/helpers/docs.rs`
  informs direct `--text` conversion to one end-of-body `insertText` request.
- `/tmp/googleworkspace-cli.tFfy8o/crates/google-workspace-cli/src/helpers/drive.rs`
  informs upload name and parent inference from explicit flags and file paths.
- `/tmp/googleworkspace-cli.tFfy8o/crates/google-workspace-cli/src/executor.rs`
  contains the reference upload MIME resolution flow delegated to by the Drive
  helper.

The gateway will not add helper commands, discovery-driven dispatch, a generic
provider API, a dependency on the Rust CLI, or a Cursor adapter. Instead, new
flags remain inside existing curated writer commands and fixed Swift capability
catalogs. Unlike the reference, the gateway will reject malformed or ambiguous
input, preserve `RAW` as the Sheets default, validate MIME syntax before I/O,
and use one resolved MIME type consistently for Drive metadata and media
headers. These divergences preserve the accepted least-privilege and
fail-closed design.

## Deliverables

- [x] Docs `--title` and `--text` sources with raw JSON/file compatibility.
- [x] Sheets `--values`, `--json-values`, and `--major-dimension` sources for
      `values append` and `values update`, with existing `--input-file` support.
- [x] Drive upload name, parent, and MIME inference/override, plus folder parent
      support, with consistent resumable-upload metadata and media typing.
- [x] Redacted dry runs, focused parsing/body/boundary/compatibility tests, and
      discoverable README/help examples.
- [ ] Updated design reference note, completed implementation plan progress
      log, safe live smoke evidence, and an accepted focused commit and push
      that excludes the unrelated `mise.toml` change.

## Tasks

### TASK-HRI-001: Establish shared source-selection and parsing rules

**Write Scope**: `Sources/AppCore/GatewayCLI.swift`,
`Sources/AppCore/GatewayRuntime.swift`, and a focused new `Sources/AppCore/`
file if separation is needed to keep every Swift file below 1,000 lines.

**Parallelizable**: No

**Dependencies**: Accepted design.

**Work**:

- Extend only the existing writer command option allowlists.
- Reject duplicate singular source flags and require exactly one source for
  each Docs or Sheets command before token loading or transport.
- Add bounded parsers for Sheets comma rows, typed JSON rows, and
  `ROWS|COLUMNS`; preserve literal whitespace and the documented scalar rules.
- Centralize source selection so convenience and raw inputs converge on the
  existing service validators and 2 MiB provider-body ceiling.
- Ensure invalid-input messages identify flags or JSON locations without
  echoing titles, text, values, raw bodies, file contents, or credentials.
- Do not alter `GatewayCapabilityCatalog`, executable products, or role scopes
  except for regression assertions proving they remain unchanged.

**Completion Criteria**:

- [x] Source combinations and duplicate singular flags fail locally with
      structured `INVALID_ARGUMENT` output.
- [x] Parsing occurs before credentials or HTTP access.
- [x] Existing raw source forms retain their accepted body semantics.
- [x] No Swift file exceeds 1,000 lines.

### TASK-HRI-002: Generate and validate Docs and Sheets bodies

**Write Scope**: `Sources/AppCore/GatewayRuntime.swift` and any parser file
introduced by TASK-HRI-001.

**Parallelizable**: No

**Dependencies**: TASK-HRI-001.

**Work**:

- Generate `{"title": TITLE}` for Docs create while preserving the original
  non-empty title value.
- Generate one end-of-body Docs `insertText` batch request for `--text` and
  route it through the existing closed request-variant validator.
- Generate Sheets `ValueRange` objects from `--values` or `--json-values`,
  owning `range` and `majorDimension` from flags while retaining raw
  `--input-file` bodies unchanged.
- Preserve `--value-input-option RAW|USER_ENTERED` as a request query option
  with `RAW` default and leave multi-range/data-filter commands raw-only.
- Apply the same body-size checks and provider validation to generated and raw
  representations.

**Completion Criteria**:

- [x] Generated Docs and Sheets bodies match equivalent accepted raw bodies.
- [x] Invalid row shapes, nested containers, empty rows, invalid dimensions,
      and non-finite numbers fail before authentication.
- [x] Complex operations remain available through existing raw inputs only.

### TASK-HRI-003: Add Drive metadata and media inference

**Write Scope**: Drive-specific portions of
`Sources/AppCore/GatewayCLI.swift`, `Sources/AppCore/GatewayRuntime.swift`, and
Drive upload tests.

**Parallelizable**: No

**Dependencies**: TASK-HRI-001; inspect reference `helpers/drive.rs` and
`executor.rs` MIME flow before editing.

**Work**:

- Add optional `--parent-id` to folder creation and optional `--name`,
  `--parent-id`, and `--mime-type` to file upload.
- Default upload name from a usable final path component; reject empty names
  and control characters.
- Resolve MIME by explicit valid media type, then documented case-insensitive
  extension mapping, then `application/octet-stream`; do not sniff bytes.
- Build upload metadata independently from bounded media bytes and include the
  resolved type consistently in metadata, `X-Upload-Content-Type`, and upload
  chunk `Content-Type`.
- Preserve the 64 MiB gateway ceiling, explicit `--max-bytes`, approved session
  hosts, retry bounds, `drive.file` scope, and existing mutation safeguards.

**Completion Criteria**:

- [x] Drive metadata contains the resolved name, optional one-element parents
      array, and resolved MIME type.
- [x] Initial and chunk upload headers use the same validated MIME type.
- [x] Unknown extensions use `application/octet-stream`; malformed or
      injection-bearing values fail locally.
- [x] No broader Drive authority or generic metadata input is introduced.

### TASK-HRI-004: Preserve redaction, boundaries, and compatibility with tests

**Write Scope**: `Tests/AppCoreTests/DocsTests.swift`,
`Tests/AppCoreTests/SheetsTests.swift`, `Tests/AppCoreTests/DriveTests.swift`,
`Tests/AppCoreTests/GatewayTests.swift`, and
`Tests/AppCoreTests/APICoverageTests.swift`.

**Parallelizable**: No

**Dependencies**: TASK-HRI-002 and TASK-HRI-003.

**Work**:

- Cover every convenience parser, mutual exclusion, duplicate sources,
  generated body, scalar type, size bound, MIME/name validation, and raw-input
  compatibility case.
- Compare generated and raw provider bodies semantically, including range and
  dimension ownership.
- Assert all new direct input flags cause `bodyValuesRedacted: true` and dry run
  performs no token load, file-byte disclosure, or transport call.
- Regress reader/writer command separation, fixed six products, exact OAuth
  scopes, destructive confirmations, upload host/precondition protections, and
  unchanged JSON result/error envelope shapes.
- Add help assertions for every new flag and raw escape hatch.

**Completion Criteria**:

- [x] Focused tests prove generated/raw equivalence and new-source redaction.
- [x] Existing raw-input and role-boundary tests remain green.
- [x] No test fixture records credentials or live document contents.

### TASK-HRI-005: Update discoverability and design traceability

**Write Scope**: `README.md`, relevant `design-docs/specs/` command documents,
and `design-docs/specs/design-human-readable-request-input.md`.

**Parallelizable**: Yes, after TASK-HRI-001 freezes command names and flag
semantics; write scope is disjoint from TASK-HRI-004.

**Dependencies**: TASK-HRI-001.

**Work**:

- Lead README and executable help examples with readable Docs, Sheets, and
  Drive forms, then show raw inputs as advanced alternatives.
- Document the exact Sheets comma limitations, JSON typing, `RAW` default,
  Drive MIME precedence/fallback, and non-sniffing behavior.
- Correct the design reference trace to cite `executor.rs` for the reference
  MIME resolution flow and identify strict MIME validation plus consistent
  metadata/media typing as intentional gateway divergences.
- Keep documentation free of machine-local credential paths or values; the
  pinned `/tmp/googleworkspace-cli.tFfy8o` path remains only as an explicit
  workflow reference required by the accepted design.

**Completion Criteria**:

- [x] All new flags and raw escape hatches are discoverable from help and
      README examples.
- [x] The Step 3 low-severity reference finding is addressed explicitly.
- [x] Documentation remains under the repository-prescribed directories.

### TASK-HRI-006: Run local and safe live verification

**Write Scope**: No product-source writes; only progress/evidence updates in
this plan after verification.

**Parallelizable**: No

**Dependencies**: TASK-HRI-002 through TASK-HRI-005.

**Work**:

- Run focused tests first, then SwiftLint, the complete test suite, build, help
  smoke checks, whitespace checks, and worktree inspection.
- Use kinko-injected credentials without printing environment or token-store
  values.
- Write uniquely marked text to the existing Docs document and an isolated
  range in the existing Sheets spreadsheet; verify with matching reader roles,
  then delete only the inserted Docs range and clear only the exact test range.
- Upload a uniquely named temporary Drive file, verify it through the reader,
  then trash only that newly observed file using confirmation and observed
  modified-time precondition. Never delete or trash pre-existing resources.
- Record command outcomes and resource cleanup status without recording secret
  values or business content.

**Completion Criteria**:

- [x] Local quality gates pass: `swift test --filter HumanReadableInputTests`,
      `mise run lint`, `mise run test`, `mise run build`, all six help checks,
      and `git diff --check` passed.
- [ ] Docs, Sheets, and Drive readable paths pass live smoke verification.
- [ ] Created live state is cleaned up narrowly and recoverably; any failed
      cleanup is reported with the created resource ID for manual recovery.
- [ ] `mise.toml` remains unchanged by feature work.

### TASK-HRI-007: Review, commit, and push accepted feature files

**Write Scope**: Git index and repository history for accepted feature files.

**Parallelizable**: No

**Dependencies**: TASK-HRI-006 and accepted adversarial implementation review.

**Work**:

- Review the final diff for generated/raw equivalence, redaction, exact scopes,
  Drive MIME consistency, raw compatibility, and live cleanup evidence.
- Stage only accepted feature source, tests, README, design, and plan files;
  explicitly exclude the pre-existing `mise.toml` modification.
- Run the pre-commit safety check required by repository policy, create a
  focused commit without AI attribution, push the current branch, and verify
  the remote commit.

**Completion Criteria**:

- [ ] No unresolved high or mid review findings remain.
- [ ] The focused commit excludes `mise.toml` and unrelated work.
- [ ] Push succeeds and the remote commit ID is recorded in the progress log.

## Dependencies

1. TASK-HRI-001 establishes source ownership and parser contracts.
2. TASK-HRI-002 and TASK-HRI-003 implement service behavior after shared rules
   are stable.
3. TASK-HRI-004 validates both service paths and cross-cutting invariants.
4. TASK-HRI-005 may run alongside TASK-HRI-004 only after flag semantics freeze.
5. TASK-HRI-006 requires all code, tests, and documentation.
6. TASK-HRI-007 requires successful verification and accepted review.

## Verification commands

```bash
swift test --filter DocsTests
swift test --filter SheetsTests
swift test --filter DriveTests
swift test --filter GatewayTests
swift test --filter APICoverageTests
mise run lint
mise run test
mise run build
swift run google-docs-gateway-reader --help
swift run google-docs-gateway-writer --help
swift run google-sheet-gateway-reader --help
swift run google-sheet-gateway-writer --help
swift run google-drive-gateway-reader --help
swift run google-drive-gateway-writer --help
git diff --check
git status --short
```

Live commands must use the existing kinko injection workflow and must not echo,
dump, or serialize credential environment variables. Record sanitized commands
or command templates in the progress log when the exact invocation includes
credential plumbing.

## Overall completion criteria

- [ ] Accepted Docs, Sheets, and Drive readable inputs work through existing
      curated writer operations.
- [ ] Advanced raw inputs retain compatible semantics and share validation with
      generated bodies.
- [ ] Dry runs redact all direct/raw body sources and perform no auth or I/O.
- [ ] Six executable boundaries, capability catalogs, exact scopes, structured
      envelopes, and mutation safeguards remain unchanged.
- [ ] Focused tests, full lint/test/build, all help checks, and safe live smoke
      tests pass with cleanup recorded.
- [ ] Documentation and plan trace the pinned reference behavior and accepted
      intentional divergences.
- [ ] Accepted changes are committed and pushed without the unrelated
      `mise.toml` modification.

## Progress log expectations

For each task, append a dated entry with status, files changed, verification
commands and outcomes, review findings resolved, and remaining risks. For live
verification, record only resource IDs created by the test, cleanup disposition,
and sanitized outcomes. Never record credentials, token-store JSON, direct text,
cell values, file bytes, or other secret/sensitive inputs.

## Progress Log

- 2026-08-14: Plan created from the accepted design and Step 3 review. Recorded
  the non-blocking `executor.rs` MIME-reference correction for TASK-HRI-005 and
  preserved the unrelated `mise.toml` modification outside feature scope.
- 2026-08-14: Completed TASK-HRI-001 through TASK-HRI-005 in
  `GatewayCLI.swift`, `GatewayRuntime.swift`, `README.md`, and
  `HumanReadableInputTests.swift`. Added bounded Docs title/text, Sheets row
  inputs, Drive metadata/MIME inference, shared dry-run redaction, and help
  examples. `swift test --filter HumanReadableInputTests` passed. Full local
  quality gates and safe live smoke verification remain TASK-HRI-006.
- 2026-08-14: TASK-HRI-006 local quality gates passed. Docs live smoke was
  blocked before verification/cleanup: scoped kinko injection returned
  `AUTH_REQUIRED`, and the full existing kinko profile returned a sanitized
  provider failure. No successful provider response or created resource was
  observed; Sheets and Drive live smoke remain pending credential/provider
  remediation.
- 2026-08-14: Addressed Step 6 self-review findings. Sheets writer help now
  documents `--major-dimension`; raw `--input-file` rejects that helper-only
  flag; focused tests prove generated/raw Sheets body equivalence, title and
  JSON-row/Drive dry-run redaction, unknown-extension fallback, invalid upload
  names, and source ownership. `swift test --filter HumanReadableInputTests`
  passed with eight tests.
- 2026-08-14: Addressed Step 6 test-integrity findings. Added fail-on-call
  authorization/transport probes to Docs, Sheets, and Drive dry-run coverage,
  including raw Docs and Sheets sources. Added generated body-size, malformed
  JSON-row, empty Docs source, inferred root-path upload-name, explicit Drive
  name/MIME override, and complete writer-help coverage. The root upload path
  now fails local name validation. `swift test --filter
  HumanReadableInputTests` passed 10 tests and `swift test --skip-build`
  passed all 49 tests. `mise run lint` reported 0 violations before the local
  runner timed out after completion; live provider smoke remains blocked.
- 2026-08-14: Addressed Step 7 review findings in `GatewayCLI.swift`,
  `GatewayRuntime.swift`, and `HumanReadableInputTests.swift`. Readable values
  beginning with `--` now use documented `--option=value` syntax; MIME types
  use ASCII RFC token validation; dry-run redaction derives from whether the
  validated command has a request body, so bodyless query-only reads remain
  unredacted. Added focused regression coverage for all three cases. `swift
  test --filter HumanReadableInputTests` passed 13 tests. `swift test
  --skip-build` passed all 52 tests before the command wrapper timed out during
  post-test build planning. `mise run lint` reported 0 violations in 24 files,
  and `swift build` passed.
  Docs, Sheets, and Drive live smoke remains blocked before provider success,
  with no created resource requiring cleanup. Commit and push remain pending
  accepted review; `mise.toml` remains excluded.
- 2026-08-14: Addressed Step 6 self-review test determinism finding in
  `HumanReadableInputTests.swift`. MIME dry-run coverage now uses a temporary
  upload file and redaction coverage uses a UUID-derived temporary output path;
  both paths are cleaned with `defer`. `swift test --filter
  HumanReadableInputTests` passed 13 tests and `swift test --skip-build` passed
  all 52 tests before the command wrapper timed out during post-test build
  planning. `mise run lint` reported 0 violations in 24 files before its
  command wrapper timed out after completion.
- 2026-08-14: Addressed the Step 6 test-integrity review in
  `HumanReadableInputTests.swift`. Docs generated bodies are now compared with
  validated `--json` and `--json-file` bodies; Sheets rejects an invalid
  dimension and non-finite numeric input; Drive dry-run assertions use unique
  content and metadata markers and prove they are absent from stdout; and the
  resumable-upload MIME test now uses a UUID-derived `.CSV` fixture. Focused,
  full-suite, lint, and build verification are pending this revision.

## Risks

- Generated and raw body shapes may diverge unless equality tests exercise the
  common validator and planner.
- New direct inputs may leak through dry-run metadata unless every source flag
  participates in redaction.
- Sheets comma input may be mistaken for full CSV unless help and errors state
  that no quoting or escaping is supported.
- Drive metadata and media headers may disagree unless one validated MIME
  resolution is passed through the full resumable-upload flow.
- Live cleanup may target pre-existing resources unless unique markers,
  observed IDs, exact ranges, and mutation preconditions are retained.
- `GatewayCLI.swift` is already large; implementation must split coherent
  responsibilities before any Swift file approaches the 1,000-line limit.
- The pre-existing `mise.toml` modification may be accidentally staged unless
  the final file list and commit diff are checked explicitly.
