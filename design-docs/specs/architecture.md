# Architecture

## Status

Draft

## Overview

`document-gateway` is a Swift Package Manager project with a
library target, an executable target, tests, and release automation for Homebrew.

## Targets

- `AppCore`: domain and command logic
- `AppCLI`: command line entry point
- `AppCoreTests`: package tests

## Google gateway composition

`AppCore` owns immutable service/role policy, closed command routing, request
planning, JSON envelopes, and preflight safeguards. Six minimal executable
targets select one immutable role and contain no provider, token, or command
policy. This keeps reader mutation surfaces absent rather than merely disabled.

Remote provider use is fail-closed: a role-specific OAuth grant must be
authoritatively inspected before a transport is allowed. Dry runs remain local,
and report only redacted method/path/query information.

## Release Surfaces

- Homebrew formula archives under `dist/homebrew/`
- Signed and notarized Cask DMGs under `dist/homebrew-cask/`
