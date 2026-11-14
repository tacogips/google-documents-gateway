# Command

## Status

Draft

## Current CLI

```bash
document-gateway [--help] [--version]
```

## Role-separated Google gateways

```text
google-docs-gateway-reader  document get
google-docs-gateway-writer  document create | document batch-update
google-sheet-gateway-reader spreadsheet get|get-by-data-filter | values get|batch-get|batch-get-by-data-filter | developer-metadata get|search
google-sheet-gateway-writer spreadsheet create|batch-update | sheet copy-to | values append|update|clear|batch-update|batch-clear|batch-clear-by-data-filter|batch-update-by-data-filter
google-drive-gateway-reader about get | changes start-token|list | shared-drives list|get | files list|get|download|export | permissions list|get | comments list|get | replies list|get | revisions list|get|download
google-drive-gateway-writer folders create | files upload|copy|replace-content|rename|move|trash|untrash | permissions create|update|delete | comments create|update|delete | replies create|update|delete | revisions update
```

Each executable also supports `config validate`, `auth login`, `auth status`,
`auth revoke`, and `doctor`. The executable fixes the service and access role;
commands cannot use another role as an option. Output is one JSON envelope.
`--dry-run` returns a redacted request plan and performs neither token loading
nor transport I/O.

See `api-coverage.md` for the discovery audit and intentional exclusions.
