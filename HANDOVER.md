# Session Handover

**Date**: 2026-03-13
**Branch**: main
**Project**: OpenPlaudit
**Version**: 0.4.0

## What Was Done

### Bug Fixes
- Fixed `tomlNeverContainsToken` test — was failing because `saveConfigWithKeychain` aborts on Keychain write failure in unsigned test runner, TOML never written. Test now uses `saveConfig` directly.
- BLE scan fallback and 15s timeout (from prior session)
- Auto-record no longer fires for already-running meeting apps (from prior session)
- Paste support in Settings text fields via NSMenu Edit menu (from prior session)

### Version Bump
- 0.3.0 → 0.4.0 in `AboutView.swift` and `Info.plist`
- `build-release.sh` updated: uses "OpenPlaudit Dev" signing, builds to `/tmp` (avoids provenance xattr), outputs zip to project root, references v0.4.0

### Features
- Transcript preview text in recent recordings menu items (first 60 chars)
- `RecentRecording` struct now includes `transcriptPreview: String?`

### Documentation
- README.md — added meeting recording section, updated config with `[meeting]` section, added MeetingKit to project structure, updated test count (118), added permissions section
- llms.txt/openplaudit-swift-api.md — version to 0.4.0, updated MeetingDetector onChange signature, BLE connect timeout note, auto-record seeding note
- docs/plaude-documentation.md — updated intro to mention macOS app and meeting recording

## Git State

All changes uncommitted. Ready to commit.

## Test Results

118 tests pass (`swift test`).
</content>
</invoke>