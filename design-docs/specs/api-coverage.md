# Google Workspace API coverage

Audit date: 2026-08-14

This gateway intentionally exposes a typed, least-privilege productivity
surface instead of an unrestricted discovery-driven REST dispatcher. The audit
compares the command catalog with the current Google Docs v1, Sheets v4, and
Drive v3 discovery documents.

## Coverage summary

| API | Audited surface | Coverage |
| --- | --- | --- |
| Docs v1 | `documents.get`, `documents.create`, `documents.batchUpdate` | Complete across reader/writer roles |
| Docs v1 batch requests | All published `Request` union discriminators | Complete, exact allowlist validation |
| Sheets v4 methods | 17 methods under spreadsheets, values, developer metadata, and sheet copy | Complete across reader/writer roles |
| Sheets v4 structural requests | All published `Request` union discriminators | Complete, exact allowlist validation |
| Drive v3 | Core end-user file collaboration and change tracking | Curated; exclusions are explicit below |

Provider JSON responses are preserved. Request bodies that are broad API union
types remain JSON-first, but their top-level discriminator is checked against
the audited discovery schema so misspelled or unknown operations fail locally.

## Docs commands

- Reader: `document get`
- Writer: `document create`, `document batch-update`

The Docs API exposes only these three document methods. Batch update accepts
all current variants, including tabs, headers and footers, named ranges,
tables, images, rich links, sections, bullets, styles, and text operations.

## Sheets commands

Reader:

- `spreadsheet get`, `spreadsheet get-by-data-filter`
- `values get`, `values batch-get`, `values batch-get-by-data-filter`
- `developer-metadata get`, `developer-metadata search`

Writer:

- `spreadsheet create`, `spreadsheet batch-update`, `sheet copy-to`
- `values append`, `values update`, `values clear`
- `values batch-update`, `values batch-update-by-data-filter`
- `values batch-clear`, `values batch-clear-by-data-filter`

Structural batch update accepts every current Sheets request discriminator,
covering sheets, cells, dimensions, ranges, filters, metadata, protected
ranges, tables, charts, slicers, data sources, formatting, validation, paste,
sort, trim, randomization, and merge operations. Destructive structural updates
require an exact spreadsheet confirmation for live execution; batch clears
require `--confirm-clear`.

## Drive commands

Reader:

- `about get`
- `changes start-token`, `changes list`
- `shared-drives list`, `shared-drives get`
- file list/get/download/export
- permission list/get
- comment list/get
- reply list/get
- revision list/get/download

Writer:

- folder create and file upload/copy/content replacement/rename/move/trash/untrash
- permission create/update/delete
- comment create/update/delete
- reply create/update/delete
- revision flag update

All Drive list commands support bounded pagination. File content and revision
downloads use an explicit byte ceiling and overwrite guard. Existing-file
mutations require exact target confirmation; file metadata/content mutations
also perform an observed `modifiedTime` preflight. Permission updates and
deletes perform an observed-role preflight.

## Intentional Drive exclusions

- Permanent file deletion and empty-trash operations, because they are
  difficult to recover and are not necessary for routine document workflows.
- Ownership transfer, access proposals, and approval administration, because
  `drive.file` is deliberately narrower than administrative Drive authority.
- Changes watches, channels, and webhook lifecycle management, because they
  require a durable public callback service rather than a local CLI command.
- Drive app registration, labels administration, and organization-wide access
  management, because those belong in dedicated administrative gateways.
- A generic raw-method escape hatch, because it would bypass the role command
  boundary, request validation, and mutation safeguards.

These exclusions are product and safety boundaries, not undiscovered gaps.
Adding one requires an explicit use case, scope review, confirmation policy,
and tests.
