# Human-Readable Request Input

**Status**: Accepted for implementation
**Feature ID**: `human-readable-request-input-ux`
**Workflow Mode**: `issue-resolution`
**Issue Reference**: `workflow-input:human-readable-request-input-ux`
**Risk**: High; adversarial review required

## Purpose

Common Docs, Sheets, and Drive writes should not require callers to reproduce
provider JSON that the gateway can derive from explicit command options. This
design adds bounded convenience inputs to the existing commands while retaining
the current raw JSON or file-backed input where it is already supported.

The convenience and raw paths are two representations of the same curated
operation. Both converge on the same provider-body validation, size limits,
dry-run redaction, role policy, and request planner before authentication or
transport can occur.

## Reference behavior

The behavioral reference is `googleworkspace/cli` at commit
`a3768d0e82ad83cca2da97724e46bea4ff0e6dbd`, inspected locally at
`/tmp/googleworkspace-cli.tFfy8o`:

- `crates/google-workspace-cli/src/helpers/sheets.rs`: `+append` accepts a
  comma-separated row or JSON rows and constructs the Sheets value body.
- `crates/google-workspace-cli/src/helpers/docs.rs`: `+write` converts direct
  text to a Docs `insertText` batch request.
- `crates/google-workspace-cli/src/helpers/drive.rs`: `+upload` infers a name
  and MIME type from a file path while allowing bounded metadata overrides.
- `crates/google-workspace-cli/src/executor.rs`: supplies the upload MIME
  resolution flow used by the Drive helper.
- `crates/google-workspace-cli/src/helpers/README.md`: helpers are translations
  over the provider API rather than alternate authority boundaries.

The reference is behavioral and structural only. This Swift package does not
invoke it, depend on it, or copy its implementation. There is no Cursor CLI
integration in scope, so no Cursor-specific behavior or adapter module is
introduced.

## Invariants

- The six executable products, closed reader/writer command catalogs, and exact
  OAuth scopes do not change.
- Convenience flags do not introduce a generic REST or JSON patch surface.
- Input selection and validation complete before token loading or transport.
- Existing confirmations, optimistic preconditions, body limits, upload limits,
  path validation, structured JSON envelopes, and secret redaction remain in
  force.
- `--dry-run` constructs and validates the same request as execution, reports
  only redacted metadata, and never exposes text, cell values, file bytes, or
  credentials.
- Existing raw input syntax remains accepted with its current semantics. New
  validation applies to helper input and source selection; it does not silently
  rewrite caller-supplied raw bodies.

## Command contract

### Docs

`document create` accepts exactly one body source:

```text
--title TITLE | --json OBJECT | --json-file PATH_OR_STDIN
```

`--title` constructs `{"title": TITLE}`. The title must be non-empty after
trimming surrounding whitespace, but the submitted title preserves the
caller's original content. Raw input retains the existing closed create model.

`document batch-update` accepts exactly one body source:

```text
--text TEXT | --json OBJECT | --json-file PATH_OR_STDIN
```

`--text` constructs one `insertText` request using
`endOfSegmentLocation.segmentId = ""`, appending plain text to the document
body. Text must contain at least one Unicode scalar; its whitespace and newline
content is preserved. Rich formatting, index-sensitive edits, write controls,
and multi-request updates continue to use raw JSON or a JSON file.

The direct forms do not create new commands and therefore cannot expand the
writer's capability catalog. `document get` and the Docs reader are unchanged.

### Sheets

`values append` and `values update` accept exactly one value source:

```text
--values COMMA_SEPARATED_ROW | --json-values JSON_ROWS | --input-file PATH_OR_STDIN
```

The helper forms retain required `--spreadsheet-id` and `--range`, and accept
`--major-dimension ROWS|COLUMNS`, defaulting to `ROWS`. They construct:

```json
{"range":"<the --range value>","majorDimension":"ROWS","values":[["a","b"]]}
```

`--values` is deliberately a simple single-record format: literal commas split
cells, whitespace is preserved, empty cells are allowed, and every cell is a
string. It has no quote or escape grammar; callers needing commas, typed cells,
or multiple rows use `--json-values`.

`--json-values` accepts either one JSON row (`[value, value]`) or multiple rows
(`[[value], [value]]`). Cells may be strings, finite numbers, booleans, or null.
Objects and arrays nested below the row level fail locally. Empty outer input,
empty rows, mixed flat/nested shapes, and non-finite values fail locally.

The helper owns `range` and `majorDimension`, so callers do not duplicate them
inside a body. `--input-file` retains the existing full provider-body shape and
validation for compatibility. Multi-range and data-filter commands retain raw
file input because a single row flag cannot describe their structure without
becoming another JSON language. `--value-input-option` remains independent and
defaults to `RAW`; callers must explicitly choose `USER_ENTERED` and its
formula interpretation.

Sheets reads, spreadsheet structural updates, clears, and all existing clear
confirmations are unchanged.

### Drive

Drive already uses explicit fields rather than a raw metadata body. The readable
path is completed without adding arbitrary Drive metadata JSON:

```text
folders create --name NAME [--parent-id ID]
files upload --input PATH --max-bytes N
             [--name NAME] [--parent-id ID] [--mime-type TYPE]
```

For upload, `--name` defaults to the input path's final component. An explicit
empty name, a path without a usable final component, or a control character in
the name fails locally. `--parent-id`, when present, produces a one-element
`parents` array. Omitting it preserves Drive's default placement.

`--mime-type` overrides inference and must be a syntactically valid media type
without parameters or control characters. Without it, the gateway uses a
documented, case-insensitive extension mapping for routine text, JSON, CSV,
PDF, Microsoft Office, OpenDocument, image, audio/video, and archive formats;
unknown extensions use `application/octet-stream`. The gateway does not sniff
file contents. The chosen type is used consistently for upload metadata and
media content.

Upload metadata is validated and encoded separately from bounded media bytes,
then used in the existing resumable-upload flow. `--max-bytes`, approved session
hosts, retry bounds, and the `drive.file` scope are unchanged. Folder parents
and uploaded-file parents must remain visible within the existing per-file
authority; failures must not suggest a broader Drive scope.

## Input selection and data flow

1. The role-specific parser rejects unsupported commands and options.
2. A command-specific source selector requires exactly one convenience or raw
   source where a body is needed. Duplicate occurrences of singular source
   flags also fail rather than using a last-value-wins rule.
3. The selected input is decoded, normalized only as documented above, and
   checked against the existing 2 MiB provider-body limit. Upload media retains
   its separate 64 MiB ceiling and explicit caller maximum.
4. Convenience input is converted into a provider-shaped object. Raw input is
   decoded under its current closed model.
5. Both paths run through the same service validator and request planner.
6. Dry-run returns a redacted plan. Execution proceeds through the existing
   role/scope guard, credential loader, and transport.

Parse and validation errors use the existing structured `INVALID_ARGUMENT`
envelope. Error details may identify an option or JSON location but must not
echo direct text, cell values, raw bodies, local file contents, or secret data.

## Discoverability and compatibility

Per-command help and the README lead with the readable form and show raw input
as the advanced alternative. Examples cover one Docs title, one Docs append,
Sheets CSV and typed JSON rows, and Drive inferred and overridden metadata.

This is additive for callers using raw Docs and Sheets bodies or existing Drive
upload flags. Structured result and error envelope schemas do not change. The
only newly rejected forms are ambiguous combinations of body sources or
duplicate singular source flags; accepting those would make source ownership
order-dependent.

## Verification and rollout

Focused tests must cover source parsing, mutual exclusion and duplicates,
provider-body generation, scalar typing, size limits, invalid MIME/name input,
dry-run redaction and no-I/O guarantees, raw-input compatibility, command
boundaries, and exact scopes. Help snapshots or assertions must make every new
flag discoverable.

Safe live verification uses the existing Docs document
`1aR3kiA5RKuVTilzI71EmJ6Z9TRB7kSjEcwZ5xrXXv-Y` and Sheets spreadsheet
`1PtU3t0x0ZmQ3RTdoNFXJ-W1QU4jK4ga-VL_-lw95UDg` through kinko-injected role
credentials without printing environment values. Tests write uniquely marked
content into an isolated document range and sheet range, verify it with the
matching reader, then delete the inserted Docs range and clear the exact Sheets
range. A Drive smoke test uploads a small temporary file and trashes it using
the existing confirmation and observed-state precondition, making cleanup
recoverable. Pre-existing resources are never deleted or trashed.

Before acceptance, run:

```bash
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

Commit and push only the accepted feature files. Preserve the unrelated,
intentional `mise.toml` addition of `gcloud = "latest"` without folding it into
the feature commit.

## Risks and mitigations

- Generated and raw bodies could diverge. Both use one provider validator, and
  request-body equality is covered by focused tests.
- Convenience parsing could reinterpret data. CSV is intentionally minimal,
  JSON typing is explicit, and `USER_ENTERED` remains opt-in.
- Metadata inference could be surprising. Explicit flags win, inference is
  extension-only, and unknown types use a stable binary default.
- New flags could weaken authority or confirmations. The immutable executables,
  capability catalog, exact scopes, and existing mutation checks are unchanged
  and regression-tested.
- Live smoke tests mutate external resources. They use isolated markers and
  ranges, verify before cleanup, and prefer recoverable cleanup.

## Open questions

None. The former intake questions are resolved by scoping `--title` to document
creation, `--text` to document batch update, retaining raw input for complex
operations, and defining recoverable service-specific smoke cleanup.
