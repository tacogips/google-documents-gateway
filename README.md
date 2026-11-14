# document-gateway

A Swift command line tool

## Google document gateways

The package exposes six fixed-role executables. A reader never includes a
mutation command, and a writer never includes a reader command. The exact
required scopes are deliberately separate:

- `google-docs-gateway-reader`: `documents.readonly`; writer: `documents`
- `google-sheet-gateway-reader`: `spreadsheets.readonly`; writer: `spreadsheets`
- `google-drive-gateway-reader`: `drive.readonly`; writer: `drive.file`

Use `--help` on an individual executable to view only its allowed surface.
All commands write one structured JSON document. `--dry-run` validates a
supported mutation and shows its redacted request plan without loading a token
or calling a transport. Remote commands fail closed until a role-specific
Desktop OAuth profile is configured and its actual grant has been inspected.
Never pass client secrets, authorization codes, access tokens, or refresh tokens
as command-line arguments.

```bash
swift run google-docs-gateway-reader --help
swift run google-sheet-gateway-writer values clear --spreadsheet-id ID --range 'Sheet1!A1' --dry-run
swift run google-drive-gateway-writer --help
mise run gateway:help
```

### OAuth setup

Enable the Google Docs, Sheets, and Drive APIs in the Google Cloud project and
use an OAuth client whose application type is Desktop. The same Desktop client
JSON can bootstrap all six roles, but every role performs a separate consent
flow and stores a separate token with exactly one API scope.

The kinko keys are:

- `DOCUMENT_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_SECRET_JSON`
- `DOCUMENT_GATEWAY_CREDENTIAL_DOCS_WRITER_OAUTH_CLIENT_SECRET_JSON`
- `DOCUMENT_GATEWAY_CREDENTIAL_SHEETS_READER_OAUTH_CLIENT_SECRET_JSON`
- `DOCUMENT_GATEWAY_CREDENTIAL_SHEETS_WRITER_OAUTH_CLIENT_SECRET_JSON`
- `DOCUMENT_GATEWAY_CREDENTIAL_DRIVE_READER_OAUTH_CLIENT_SECRET_JSON`
- `DOCUMENT_GATEWAY_CREDENTIAL_DRIVE_WRITER_OAUTH_CLIENT_SECRET_JSON`

After login, the matching token can also be supplied without a filesystem
credential through `DOCUMENT_GATEWAY_CREDENTIAL_<ROLE>_TOKEN_STORE_JSON`, for
example `DOCUMENT_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON`. Environment
JSON takes precedence over `DOCUMENT_GATEWAY_CREDENTIAL_<ROLE>_TOKEN_STORE_PATH`,
matching `mail-gateway`. An expired environment token is refreshed in memory;
the caller remains responsible for replacing its kinko value.

The reusable Desktop OAuth client JSON from the sibling `mail-gateway` vault
has been copied into these document-gateway-local keys. Gmail token values were
not copied because Gmail grants do not satisfy any document-gateway role.

Run each login through kinko. Login opens the browser and accepts the callback
only on a temporary `127.0.0.1` listener; authorization codes and PKCE values
are never accepted as command arguments.

```bash
kinko exec --env DOCUMENT_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_SECRET_JSON -- \
  swift run google-docs-gateway-reader auth login
kinko exec --env DOCUMENT_GATEWAY_CREDENTIAL_DOCS_WRITER_OAUTH_CLIENT_SECRET_JSON -- \
  swift run google-docs-gateway-writer auth login
kinko exec --env DOCUMENT_GATEWAY_CREDENTIAL_SHEETS_READER_OAUTH_CLIENT_SECRET_JSON -- \
  swift run google-sheet-gateway-reader auth login
kinko exec --env DOCUMENT_GATEWAY_CREDENTIAL_SHEETS_WRITER_OAUTH_CLIENT_SECRET_JSON -- \
  swift run google-sheet-gateway-writer auth login
kinko exec --env DOCUMENT_GATEWAY_CREDENTIAL_DRIVE_READER_OAUTH_CLIENT_SECRET_JSON -- \
  swift run google-drive-gateway-reader auth login
kinko exec --env DOCUMENT_GATEWAY_CREDENTIAL_DRIVE_WRITER_OAUTH_CLIENT_SECRET_JSON -- \
  swift run google-drive-gateway-writer auth login
```

Tokens default to `~/.config/document-gateway/tokens/<role>.json` and are
written atomically with mode `0600`. Override a path with the matching
`DOCUMENT_GATEWAY_CREDENTIAL_<ROLE>_TOKEN_STORE_PATH` variable. `doctor`,
`auth status`, and `auth revoke --confirm-credential <role>` never print token
or client-secret values.

### Operations

- Docs reader: `document get`
- Docs writer: `document create`, `document batch-update`
- Sheets reader: spreadsheet get/get-by-data-filter, value get/batch-get and
  data-filter variants, and developer-metadata get/search
- Sheets writer: spreadsheet create/structural batch-update, sheet copy, and all
  value append/update/clear/batch/data-filter mutation methods
- Drive reader: account quota, changes, shared drives, file metadata/content,
  permissions, comments, replies, and revisions
- Drive writer: folders, upload/copy/replace/rename/move/trash, permissions,
  comments, replies, and revision flags

The Docs gateway covers every stable `documents` method and validates every
currently published Docs batch-update request discriminator. The Sheets gateway
covers all 17 stable methods under `spreadsheets`, `values`,
`developerMetadata`, and `sheets.copyTo`, plus every published structural
batch-update discriminator. See `design-docs/specs/api-coverage.md` for the
audited command matrix and intentional Drive exclusions.

Drive list operations support bounded `--page-all --max-pages N` aggregation.
Downloads and exports require `--max-bytes` and refuse to overwrite an existing
file unless `--overwrite` is present. Resumable uploads use bounded chunks and
require an explicit `--max-bytes` ceiling up to 64 MiB; they accept session URLs
only from approved HTTPS Google hosts. Mutations of existing
files or permissions require exact ID confirmation and observed-state
preconditions. Broad domain or public sharing also requires
`--acknowledge-broad-access`.

Drive writer access uses `drive.file`, so it cannot assume visibility of
arbitrary pre-existing files. All successful results and errors are structured
JSON; provider response fields are preserved rather than narrowed to an
incomplete local model.

### Readable write inputs

Common writes accept bounded flags so callers do not need to hand-author a
provider body. The advanced raw body paths remain available where shown.

```bash
# Docs: use raw JSON/file only for rich or index-sensitive changes.
swift run google-docs-gateway-writer document create --title 'Project notes'
swift run google-docs-gateway-writer document batch-update --document-id ID --text $'First line\nSecond line'

# Sheets: --values is one comma-split row; it has no quote or escape grammar.
swift run google-sheet-gateway-writer values update --spreadsheet-id ID --range 'Sheet1!A1' --values 'one,two,'
swift run google-sheet-gateway-writer values append --spreadsheet-id ID --range 'Sheet1!A1' --json-values '[1,true,null]'
swift run google-sheet-gateway-writer values update --spreadsheet-id ID --range 'Sheet1!A1' --input-file value-range.json

# Drive: metadata comes from the path unless an explicit bounded override is needed.
swift run google-drive-gateway-writer folders create --name Reports --parent-id PARENT_ID
swift run google-drive-gateway-writer files upload --input report.csv --max-bytes 1048576
swift run google-drive-gateway-writer files upload --input report.csv --max-bytes 1048576 --name export.csv --mime-type text/csv
```

`--json-values` accepts one JSON row or multiple rows. Its cells may be
strings, finite numbers, booleans, or `null`; use it for commas, typed values,
or multiple rows. `--value-input-option` still defaults to `RAW`; choose
`USER_ENTERED` explicitly to enable Sheets formula interpretation. Drive MIME
types are resolved from an explicit valid media type, otherwise a
case-insensitive extension mapping, and finally `application/octet-stream`.
Drive never sniffs file bytes.

For a direct option value that begins with `--`, use the unambiguous
`--option=value` form, such as `--text=--heading` or `--values=--pending`.

## Development

```bash
mise install
mise run build
mise run test
swift run document-gateway --help
```

The package uses Swift Package Manager with:

- Library target: `AppCore`
- Executable target: `AppCLI`
- Installed executable: `document-gateway`

Swift target names and type names must be valid Swift identifiers. If the project
name contains hyphens, keep `PROJECT_NAME` and `EXECUTABLE_NAME` hyphenated as
needed, but use identifier-safe values such as `AppCore`, `AppCLI`, and
`AppCommand` for Swift module/type variables.

## Homebrew Formula

Build local formula archives:

```bash
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render a formula after both platform archives exist:

```bash
mise run homebrew:formula -- 0.1.0
```

Render directly into the default sibling tap checkout:

```bash
mise run homebrew:tap-formula -- 0.1.0
```

Install from the tap after the formula is published:

```bash
brew tap tacogips/tap
brew install document-gateway
```

## Homebrew Cask

The Cask workflow builds signed, notarized, and stapled macOS DMG artifacts.
Apple signing credentials must stay local and must not be committed.

Check the build plan:

```bash
mise run build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build with local signing credentials:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run build:homebrew-cask -- darwin-arm64 darwin-x64
```

Render a Cask:

```bash
mise run homebrew:cask -- 0.1.0
```

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run release:homebrew-cask-local -- v0.1.0
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
