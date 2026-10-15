# 0001 — Build with full Xcode, not SwiftPM-only

- **Date:** 2026-10-15
- **Status:** accepted
- **Supersedes:** —

## Context

The plan assumes Xcode (an `.xcodeproj`, XCUITest). The Mac only had the Command Line Tools: `xcodebuild` was unavailable, while `swift build` and `swift test` (with Swift Testing) worked. The alternative was to build the `.app` with a script around SwiftPM.

## Decision

Install full Xcode and sign debug builds with a free Apple ID "Apple Development" identity.

## Why

- **Accessibility permission sticks.** macOS ties it to the app's code signature. A script build would be ad-hoc signed, which gives it a new signature on every build, so the permission would have to be re-approved after each rebuild unless a self-signed certificate was created by hand.
- **XCUITest is available.** The plan's M2/M3 integration tests depend on it.
- **The plan stays as written.**

## Consequences

- One-time ~15 GB install, which the user does (App Store + admin password).
- `Core/` remains a plain SwiftPM package, testable with `swift test` even without Xcode, so work on it can start before the install finishes.
