# Brief: command catalog and `GoogleDocumentsGatewaySDK` on `GatewaySDKKit` (2026-09-04)

Master design: `/Users/taco/gits/tacogips/riela/docs/briefs/gateway-sdk-2026-09-04.md`
(sections 2 and 3.5 are normative). The shared kit is implemented at
`/Users/taco/gits/tacogips/gateway-sdk-kit` (read its `README.md` and
`design-docs/briefs/gateway-sdk-kit-2026-09-04.md` for the exact API, especially the
`command` operation kind and `GatewayArgvBuilder`). Treat this whole brief as exactly
ONE feature.

## Goal

google-documents-gateway has no GraphQL: its surface is `<group> <verb> --flag value`
argv per role. Give it the same SDK shape as the GraphQL gateways: a declared command
catalog (commands, flags, types, required-ness, per role), operation-by-name invocation
that builds argv, raw argv passthrough, a printable schema (`type Command`), and regex
search, so riela's generic add-on engine can drive it like the others.

## Verified seams (2026-09-04, HEAD cda93cd)

- `Sources/GoogleDocumentsGatewayCore/GatewayCLI.swift:8-33` `GatewayCommandRunner(role:
  authorizer: transport: credentialProfile: environment: [String: String])`; `:35
  run(arguments:) -> GatewayCommandResult { stdout, exitCode }` (sync, non-throwing;
  success `{"ok":true,"data":...}` :412-414, error `{"ok":false,"error":{code,message}}`
  :416-418); `--help` / no args returns `{usage, service, role}` (:36-38, usage built at
  :109); `--version` :40; `--dry-run` returns the planned request without calling Google
  (:59-61); role gate `FORBIDDEN_COMMAND` :52-55; option parser :729-746
  (`--flag value` and `--flag=value`, repeated flags collect).
- `Sources/GoogleDocumentsGatewayCore/GatewayCapabilityCatalog.swift:4-37`
  `GatewayCapabilityCatalog.commands(for: GatewayRole) -> Set<String>` (docs read 1 /
  write 2; sheets read 7 / write 10; drive read 18 / write 19); `docsBatchUpdateRequests`
  :39, `sheetsBatchUpdateRequests` :51.
- `Sources/GoogleDocumentsGatewayCore/GatewayRole.swift:23-32` (`GatewayRole(service:
  .docs|.sheets|.drive, accessMode: .read|.write)`, scopes), `GatewayRequestPlan` :50-62.
- `Sources/GoogleDocumentsGatewayCore/GatewayRequestBuilder.swift` (491 lines)
  `plan(role:operation:options:)` reads the flags per command (`options["range"]` :88,
  `--values/--json-values/--major-dimension` :240-250, confirm flags such as
  `--confirm-range` :255, `--confirm-spreadsheet-id` :259, `--confirm-file-id` :314/:324,
  `--confirm-permission-id` :332, `--confirm-comment-id` :362, `--confirm-reply-id` :377,
  `--confirm-revision-id` :386, `--max-bytes` :291, `--page-size` (1...1000) :305,
  `--max-pages` (1...100) :308, `--open-browser` :662, `--timeout-seconds` :665).
- Role-neutral commands allowed everywhere: `config validate`, `auth status`, `doctor`,
  `auth login`, `auth revoke` (`GatewayCLI.swift:41-51`); riela forbids the last two.
- Products: library `GoogleDocumentsGatewayCore`; executables `google-docs-gateway-reader|writer`,
  `google-sheet-gateway-reader|writer`, `google-drive-gateway-reader|writer` (5-line mains)
  and a stub `google-documents-gateway`. Role separation is runtime-only (every executable
  links the whole core).
- Tests: swift-testing, `Tests/GoogleDocumentsGatewayCoreTests` (`APICoverageTests`,
  `CommandTests`, `DocsTests`, `DriveTests`, `SheetsTests`, `GatewayTests`,
  `HumanReadableInputTests`).
- riela calls `GatewayCommandRunner(role:environment:).run(arguments:)` from
  `/Users/taco/gits/tacogips/riela/Sources/RielaCLI/ProductionNodeAdapter+GoogleDocumentsGatewayAddons.swift:104-117`
  with `config.command` + `config.argsTemplate`; it will add operation mode through the
  facade. Keep the runner and CLI unchanged.

## Deliverables

1. **Dependency.** `Package.swift`: `.package(path: "../../gateway-sdk-kit")` (this
   worktree is `/Users/taco/gits/tacogips/google-documents-gateway-worktrees/gateway-sdk`)
   and product `GatewaySDKKit` on `GoogleDocumentsGatewayCore`. One-line comment that the
   operator switches it to a URL pin later.
2. **Command catalog** (`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsCommandCatalog.swift`,
   split per service if long): one declaration per command in
   `GatewayCapabilityCatalog.commands(for:)` (all six role sets) as a `GatewayOperation`
   with `kind: .command`, `name` = the command string (`"values get"`), `tier` =
   `"<service>-<read|write>"` (e.g. `sheets-read`), `domain` = service, `arguments` = the
   flags that command reads in `GatewayRequestBuilder` (name without `--`, type: `String`
   / `Int` / `Boolean` / `[String]` for repeatable flags / `JSON` for JSON-valued flags
   such as `--json-values` and batch-update request bodies, `isRequired`, `description`
   including value constraints such as `ROWS|COLUMNS` or `1...1000`), `isDestructive`
   for delete/trash/clear/replace commands, `summary` one line. Enumerated flag values
   (`--major-dimension`, `--value-input-option`, `--value-render-option`, etc.) become
   enum types. `GatewaySchemaCatalog.googleDocuments(role: GatewayRole)` returns the
   catalog for a role (role-neutral commands `config validate`, `auth status`, `doctor`
   included; `auth login` / `auth revoke` excluded from the SDK catalog on purpose).
   Test: for every role, catalog names ⊇ `GatewayCapabilityCatalog.commands(for:)` and
   every catalog command is accepted by the role; `validate()` empty. Flag parity: for
   every command, a fixture request built from its declared required flags (plus one
   optional) passes `--dry-run` through `GatewayCommandRunner`, and a request containing
   an undeclared flag that the builder reads must not exist (assert by driving
   `GatewayRequestBuilder.plan` with the declared flags and checking the plan is complete;
   document any command whose flags are intentionally open-ended).
3. **Facade** (`Sources/GoogleDocumentsGatewayCore/SDK/GoogleDocumentsGatewaySDK.swift`):
   ```swift
   public struct GoogleDocumentsGatewaySDK: GatewaySDK {
     public let provider = "google-documents-gateway"
     public let tier: String                  // "docs-read" | ... | "drive-write"
     public let catalog: GatewaySchemaCatalog
     public init(role: GatewayRole, authorizer: ..., transport: ..., credentialProfile: ...)  // same defaults as GatewayCommandRunner
     public func execute(document:variables:environment:) async -> GatewayEnvelope
   }
   ```
   `execute` treats `document` as a JSON-encoded argv array (`["values","get","--spreadsheet-id","..."]`);
   GraphQL text yields an envelope error `UNSUPPORTED_DOCUMENT` (exit 2). `invoke` (kit
   default) builds argv through `GatewayArgvBuilder` and calls `execute`. Results map via
   `GatewayEnvelope(parsingCLIOutput:exitCode:)` (the `{ok, data, error}` shape).
4. **CLI.** `schema print` (SDL with `type Command`), `schema search <regex> [--kinds
   command,enumeration] [--include-referenced-types] [--limit N]` (JSON matches), and
   `operation run <name> --variables <json>|--variables-file <path>` (argv built by the
   facade) added to all six role binaries; `--help` usage lists them; `README.md` gains an
   SDK section with a Swift example and the CLI additions.
5. **Tests**: catalog parity and validate() per role (item 2); facade `invoke` for
   `values get`, `files list` (repeatable flag), `files delete` (confirm flag required and
   validated), and `spreadsheet batch-update` (JSON body) through a fake transport
   asserting the argv and the planned HTTP request; a writer command invoked on a read
   role returns the `FORBIDDEN_COMMAND` envelope error; `execute` argv passthrough equals
   `run(arguments:)` output; `schema search` / `schema print` / `operation run` CLI.

## Verification

`arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/google-documents-gateway-worktrees/gateway-sdk && swift build && swift test && swiftlint'`
green. Commit on `feat/gateway-sdk` in this worktree as work lands; do not push.

## Non-goals

No GraphQL layer for this gateway, no changes to request building, OAuth, transport, or
packaging. Do not touch `/Users/taco/gits/tacogips/google-documents-gateway` (the main
checkout).
