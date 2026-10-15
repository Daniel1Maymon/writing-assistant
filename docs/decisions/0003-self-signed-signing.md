# 0003 — Sign debug builds with a local self-signed certificate

- **Date:** 2026-10-15
- **Status:** accepted
- **Supersedes:** the signing part of [0001](0001-build-with-xcode.md) ("sign debug builds with a free Apple ID 'Apple Development' identity"). Building with full Xcode still stands.

## Context

macOS ties the Accessibility permission to the app's code signature. An ad-hoc signature changes on every build, so the permission is lost each time. 0001 planned to fix that with an Apple ID added in Xcode → Settings → Accounts. That is a manual step for the user, and this app needs nothing an Apple ID gives (no App Store, no iCloud, no notarization).

## Decision

A self-signed code-signing certificate, "WritingAssistant Local Signing", lives in the user's login keychain, created with `openssl` + `security import` (no admin password). Xcode builds the app with ad-hoc signing, then `scripts/install.sh` re-signs it with that certificate (hardened runtime on) before installing.

## Why

- **Stable identity.** The app's designated requirement becomes `certificate leaf = H"1be8f724…"`, which doesn't change between builds.
- **No Apple ID, no password.** The user chose this option on 2026-10-15.
- The certificate shows as "not trusted" in `security find-identity`. That doesn't matter for `codesign` or for TCC, and trusting it would need an admin password.

## Consequences

- Signing happens in `install.sh`, not in Xcode. Building and running from the Xcode IDE gives an ad-hoc build that won't keep the permission.
- Debug builds set `ENABLE_DEBUG_DYLIB = NO`. Otherwise Xcode splits the code into `WritingAssistant.debug.dylib`, which keeps its ad-hoc signature, and launch fails with "different Team IDs". The cost: no SwiftUI previews.
- DerivedData lives in `~/Library/Developer/Xcode/DerivedData/WritingAssistant-local`, not under the repo. Files on Desktop get Finder metadata that makes `codesign` fail ("resource fork, Finder information, or similar detritus not allowed").
- The certificate is only on this Mac. A new Mac needs a new certificate and one more permission grant.
- If the app is ever distributed, it needs a Developer ID and notarization instead.
