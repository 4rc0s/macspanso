# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app (SwiftUI + AppKit) that gives espanso's YAML match files a GUI. The app does not own its data format — espanso does. Users edit the same files by hand, and espanso reloads them on change. That constraint drives most of the architecture below.

## Build and test

The Xcode project is **generated** — `project.yml` is the source of truth, and `macspanso.xcodeproj` is a build artifact that is nonetheless committed and routinely stale. Always regenerate before building:

```bash
xcodegen generate          # required after adding/removing/renaming any source file
xcodebuild build -scheme macspanso -destination 'platform=macOS'
xcodebuild test  -scheme macspanso -destination 'platform=macOS'
```

`project.yml` globs `macspanso/` and `macspansoTests/` wholesale, so new files need no project edit — but a build without `xcodegen generate` will not see them and will fail with confusing "cannot find type" errors.

Single test or single test class:

```bash
xcodebuild test -scheme macspanso -destination 'platform=macOS' \
  -only-testing:macspansoTests/EspansoConfigStoreTests/testAddRefusesParseErroredFile
```

There is no linter and no formatter. CI (`.github/workflows/ci.yml`) runs the build, uploads the app bundle as an artifact, then runs tests with a 60s per-test allowance so a hung test fails rather than stalling the runner. `release.yml` fires only on `v*` tags and needs signing secrets.

Version lives in `project.yml` (`CFBundleShortVersionString` / `CFBundleVersion`) and is mirrored into the tracked-but-generated `macspanso/App/Info.plist`; keep both in step. Nothing else in the repo carries a version worth touching — see "Upstream-owned files" below.

## Architecture

### Data flow

`AppDelegate` → resolves the match directory by shelling out to `espanso path` → builds `EspansoConfigStore`, `EspansoProcessManager`, `UpdateChecker` → hands them to `MenuBarController`, which owns the status item and lazily creates `MatchManagerWindowController`. There is no SwiftUI `WindowGroup`; `macspansoApp` declares an empty `Settings` scene and everything real is AppKit-driven. The app is `LSUIElement`.

`EspansoConfigStore` (`Store/EspansoConfigStore.swift`) is the center of the app — the single `@MainActor` `ObservableObject` that owns all match state. Views take it via `@ObservedObject`. Nearly every non-trivial behavior question is answered in this file.

### Round-trip preservation is the core invariant

macspanso models only a subset of espanso's schema, but rewrites whole files. Anything unmodeled that is not deliberately preserved gets **destroyed on save**. Two mechanisms carry it:

- `MatchFileContent.extras` — every top-level key besides `matches:` (`global_vars:`, `imports:`, …)
- `EspansoMatch.extras` — every per-match key outside `CodingKeys` (`markdown:`, `priority:`, `paste_shortcut:`, app filters, …)

Both use `YAMLAny` (`Model/YAMLAny.swift`), a recursive `Codable` enum, and both are re-emitted by hand-written `encode(to:)` implementations. **When adding a field to `EspansoMatch`, add it to `CodingKeys` too** — `knownKeys` derives from `CodingKeys.allCases`, so a property that skips it will be both decoded into the model and duplicated into `extras`. `RoundTripPreservationTests` guards this.

A corollary: never write into a file whose `parseError != nil`. A file that failed to parse holds nothing in memory, so writing it out replaces its real contents with an empty document. `add()` and `move()` enforce this with an explicit guard. `update()` and `delete()` need none — both resolve their target by searching `matchFiles` for a match ID, and a parse-errored file is stored with `matches: []`, so it can never be found. That distinction matters when adding a write path: if it targets a file directly rather than via a match it contains, it needs the explicit guard.

### Write-then-commit ordering

Every mutating path on the store writes to disk **first** and only updates `matchFiles` if the write succeeded. This is deliberate — a failed write that had already mutated memory would leave the UI showing matches that don't exist on disk. Preserve this ordering in new write paths. `EspansoConfigStoreTests` makes the temp directory read-only (`0o555`) to force write failures, which works because writes are atomic (temp file + rename in the same directory).

### Watcher suppression

`FileWatcher` uses `DispatchSource` per file *and* per directory (a root-level source does not fire for files created in subdirectories). Because the app's own atomic writes look identical to external edits, `suppressingWatcherEvents(for:)` reference-counts in-flight writes across three paths — the file, its parent, and the root — and decrements on a 2s delay to cover async FSEvent delivery. The decrement is scheduled in a `defer` so a throwing write can't leak the counter and disable external-edit detection for the rest of the session.

Atomic writes replace the inode, so the watcher's event handler cancels and re-opens its source on every event — a source left pointing at the old fd goes permanently silent.

### URL identity

The store compares URLs by equality everywhere, but directory enumeration returns symlink-resolved paths (`/private/var/…`) while `appendingPathComponent` does not (`/var/…`). Both `init` and `scanMatchDirectory` call `resolvingSymlinksInPath()` to normalize at the boundary. Any new code constructing a URL to compare against store state must do the same.

### Match identity across reloads

`EspansoMatch.id` is a UUID minted at decode time and excluded from YAML. On reload, `reassociateIDs` re-attaches prior UUIDs by matching on primary trigger (or regex pattern) so the editor's selection survives an external edit elsewhere in the file. `IDReassociationTests` covers it.

### Subprocess handling

Every `Process` in the codebase (`EspansoProcessManager.run`, `BackupManager`'s `zip`/`unzip`) follows the same shape, and the deviations have each caused a shipped hang: **drain the pipe to EOF before `waitUntilExit()`**, because output past the ~64 KB pipe buffer blocks the child forever; return early if `proc.run()` throws, since our end still holds the write side and the read would never see EOF; and send unread stdout to `FileHandle.nullDevice` rather than an undrained `Pipe()`. `resolveMatchDirectory` additionally races a 3s deadline and kills the child, so a wedged espanso binary can't block launch.

`EspansoProcessManager` parses `espanso status` output as strings, verified against espanso v2.2.x — it's the fragile seam on espanso upgrades. Pass `espansoPath:` to the initializer in tests.

### Packages are read-only

Anything under `<matchdir>/packages/` is espanso-managed: excluded from writes, from backups (`zip -x 'packages/*'`), from restores, and from replace-mode cleanup. `isPackage` is computed by prefix against the known config root, not a path search.

### Backups vs. snapshots

Both are zips of the match directory. Backups are user-initiated to a chosen path (`.macspanso` extension); snapshots are automatic — one per editing session, taken the first time the Match Manager opens with a non-empty store, rotating at 10, in Application Support. Replace-mode restore calls `deleteUserMatchFiles`, which must cover both `.yml` and `.yaml` (espanso loads both — see `matchExtensions`).

### Menu-bar and window presence

`MenuBarController` flips `NSApp.setActivationPolicy` to `.regular` while the Match Manager window is open (so it appears in Cmd-Tab and the Dock) and back to `.accessory` on `willCloseNotification`. Activation deliberately uses the deprecated `NSApp.activate(ignoringOtherApps: true)`: for an accessory app the macOS 14 no-arg variant can silently no-op. `MatchManagerWindowController.placement(forFrame:visibleFrames:)` is pure and unit-tested — it requires half the window's area on one screen rather than a bare `intersects`, because a 1px sliver after a display change reads as "visible" and the window appears not to open.

Focus commands (new match, about) reach SwiftUI through `NotificationCenter` posted one run-loop cycle late, so the view's `.onReceive` is wired up before the notification fires.

## Testing conventions

XCTest, `@testable import macspanso`. Classes that touch the actor-isolated types are `@MainActor` (`EspansoConfigStoreTests`, `BackupManagerTests`, `EspansoProcessManagerTests`, `TriggerConflictTests`, `RoundTripPreservationTests`); the pure-logic ones are not (`MatchValidationTests`, `MatchExpanderTests`, `YAMLParsingTests`, `YAMLSerializationTests`, `TriggerModeTransitionTests`, `MatchManagerWindowPlacementTests`, `IDReassociationTests`). Tests build a real temp directory per test in `setUp` and write real YAML — there are no mocks or protocol seams. Most non-UI logic is reachable because the pure parts (`MatchValidator`, `MatchExpander`, `TriggerModeTransition`, `YAMLSerializer`, window placement, ID reassociation) are `static`/`nonisolated` and free of app state.

## Notes

- `CHANGELOG.md` entries are user-facing prose: bolded symptom, em dash, then what went wrong and what changed. Match that register rather than listing commits.
- This is a fork (`4rc0s/macspanso`); upstream is `jeffcaldwellca/macspanso`. Release DMGs come from upstream — this fork's CI produces ad-hoc-signed artifacts only.

## Upstream-owned files — do not bump

`docs/` and `Casks/macspanso.rb` describe upstream's published release, not this fork's build. **Leave both alone**, including when bumping the version:

- `docs/` is upstream's marketing site vendored into the repo. Every URL in it points at `www.jeffcaldwell.ca/macspanso/` (`robots.txt`, `sitemap.xml`, and the canonical/OG tags in `index.html`), and there is no `CNAME` here, so this fork does not publish it. The version strings in `index.html` (the `softwareVersion` JSON-LD and the footer) are upstream's to update.
- `Casks/macspanso.rb` is a template. `release.yml` rewrites the cask in the *tap* repo (`jeffcaldwellca/homebrew-tap`, checked out to `tap/`), never this copy — so the in-repo version and its `PLACEHOLDER_UPDATED_BY_RELEASE_WORKFLOW` sha are inert by design.

`release.yml` cannot run here regardless: it needs `TAP_TOKEN` (a PAT scoped to upstream's tap) and Developer ID signing secrets, neither of which this fork has. There is no "tag time" for this fork. If work goes upstream as a PR, leaving these untouched is also the right hygiene — they are the maintainer's release surface.
