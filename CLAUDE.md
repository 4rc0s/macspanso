# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu-bar app (SwiftUI + AppKit) that gives espanso's YAML match files a GUI. The app does not own its data format — espanso does. Users edit the same files by hand, and espanso reloads them on change. That constraint drives most of the architecture below.

## Build and test

The Xcode project is **generated** — `project.yml` is the source of truth, and `macspanso.xcodeproj` is a build artifact that is nonetheless committed and routinely stale. Always regenerate before building:

```bash
xcodegen generate          # required after adding/removing/renaming any source file
xcodebuild build -scheme macspanso -destination 'platform=macOS' -derivedDataPath build/DerivedData
xcodebuild test  -scheme macspanso -destination 'platform=macOS' -derivedDataPath build/DerivedData
```

`project.yml` globs `macspanso/` and `macspansoTests/` wholesale, so new files need no project edit — but a build without `xcodegen generate` will not see them and will fail with confusing "cannot find type" errors.

Single test or single test class:

```bash
xcodebuild test -scheme macspanso -destination 'platform=macOS' \
  -only-testing:macspansoTests/EspansoConfigStoreTests/testAddRefusesParseErroredFile
```

Pass `-derivedDataPath build/DerivedData` (gitignored) so builds don't land in `~/Library`. Local development is on Xcode 26.x; CI (`.github/workflows/ci.yml`) is pinned to Xcode 26.3 via `DEVELOPER_DIR` because `KeyboardShortcuts` declares swift-tools-version 6.2 and the runner's default 16.4 (Swift 6.1) cannot resolve it. Keep the two on the same major.

There is no linter and no formatter. CI runs the build, uploads the app bundle as an artifact, then runs tests with a 60s per-test allowance so a hung test fails rather than stalling the runner. `release.yml` fires only on `v*` tags and needs signing secrets.

Version lives in `project.yml` (`CFBundleShortVersionString` / `CFBundleVersion`) and is mirrored into the tracked-but-generated `macspanso/App/Info.plist`; keep both in step. Nothing else in the repo carries a version worth touching — see "Upstream-owned files" below.

## Architecture

### Data flow

`AppDelegate` → resolves the match directory by shelling out to `espanso path` → builds `EspansoConfigStore`, `EspansoProcessManager`, `UpdateChecker` → hands them to `MenuBarController`, which owns the status item and lazily creates `MatchManagerWindowController`. There is no SwiftUI `WindowGroup`; `macspansoApp` declares only a `Settings` scene (which hosts the real Settings window — see "Menu-bar and window presence") and everything else is AppKit-driven. The app is `LSUIElement`.

`EspansoConfigStore` (`Store/EspansoConfigStore.swift`) is the center of the app — the single `@MainActor` `ObservableObject` that owns all match state. Views take it via `@ObservedObject`. Nearly every non-trivial behavior question is answered in this file.

### Round-trip preservation is the core invariant

macspanso models only a subset of espanso's schema, but rewrites whole files. Anything unmodeled that is not deliberately preserved gets **destroyed on save**. Two mechanisms carry it:

- `MatchFileContent.extras` — every top-level key besides `matches:` (`global_vars:`, `imports:`, …)
- `EspansoMatch.extras` — every per-match key outside `CodingKeys` (`markdown:`, `html:`, `image_path:`, `paragraph:`, …)

Both use `YAMLAny` (`Model/YAMLAny.swift`), a recursive `Codable` enum, and both are re-emitted by hand-written `encode(to:)` implementations. **When adding a field to `EspansoMatch`, add it to `CodingKeys` too** — `knownKeys` derives from `CodingKeys.allCases`, so a property that skips it will be both decoded into the model and duplicated into `extras`. `RoundTripPreservationTests` guards this.

**Known hole: YAML anchors are not preserved.** espanso documents `anchors:` plus `&name`/`*name` aliases as the compact way to share one script across matches ([docs](https://espanso.org/docs/matches/extensions/#anchors-and-aliases)). Yams resolves aliases while composing the node graph and keeps no anchor name on the resulting value, so any save inlines the shared body at every use site — the `anchors:` block and the body both survive and espanso behaves identically, but the user's DRY structure is flattened. Fixing it means threading anchor identity through `YAMLAny`, `EspansoVar`, `FormField`, and `EspansoMatch`, because the Codable layer is where it is dropped; Yams *does* model anchors at the `Node` level (`Node.anchor`, `.alias`, and a Codable hook via `Node.anchorKeyNode`). `Emitter.Options.redundancyAliasingStrategy` is not a shortcut — it invents anchor names and aliases subtrees the user never shared. `RoundTripPreservationTests.testYAMLAliasesAreInlinedOnRoundTrip` pins the current behavior with a strict `XCTExpectFailure`, so it turns red when someone fixes this; delete this paragraph when it does.

A corollary: never write into a file whose `parseError != nil`. A file that failed to parse holds nothing in memory, so writing it out replaces its real contents with an empty document. `add()` and `move()` enforce this with an explicit guard. `update()` and `delete()` need none — both resolve their target by searching `matchFiles` for a match ID, and a parse-errored file is stored with `matches: []`, so it can never be found. That distinction matters when adding a write path: if it targets a file directly rather than via a match it contains, it needs the explicit guard.

### Write-then-commit ordering

Every mutating path on the store writes to disk **first** and only updates `matchFiles` if the write succeeded. This is deliberate — a failed write that had already mutated memory would leave the UI showing matches that don't exist on disk. Preserve this ordering in new write paths. `EspansoConfigStoreTests` makes the temp directory read-only (`0o555`) to force write failures, which works because writes are atomic (temp file + rename in the same directory).

### Watcher suppression

`FileWatcher` uses `DispatchSource` per file *and* per directory (a root-level source does not fire for files created in subdirectories). Because the app's own atomic writes look identical to external edits, `suppressingWatcherEvents(for:)` reference-counts in-flight writes across three paths — the file, its parent, and the root — and decrements on a 2s delay to cover async FSEvent delivery. The decrement is scheduled in a `defer` so a throwing write can't leak the counter and disable external-edit detection for the rest of the session.

Atomic writes replace the inode, so the watcher's event handler cancels and re-opens its source on every event — a source left pointing at the old fd goes permanently silent.

### URL identity

The store compares URLs by equality everywhere, but the same file arrives in two spellings: directory enumeration yields `/private/var/…`, while `appendingPathComponent` keeps `/var/…`.

**`resolvingSymlinksInPath()` does not do what its name suggests.** It canonicalizes *toward* `/var/…` — it strips a `/private` prefix rather than adding one. The consequence that matters:

> Normalize **both** operands of any path comparison, or neither. Normalizing one side is worse than normalizing neither, because it guarantees the mismatch it was meant to fix.

`EspansoConfigStore` gets this right in two places that must stay in sync: `init` normalizes the root, and `scanMatchDirectory` maps the normalization over *every enumerated entry*. Code that enumerates and then compares against a path built from the root needs both halves.

This has bitten twice. `BackupManager.deleteUserMatchFiles` built its `packages/` prefix from the root but compared it against raw enumerated entries, so `hasPrefix` was false for every entry, the guard never fired, and replace-mode restore deleted package files. The first attempted fix normalized only the root — a no-op that looked right.

Note the asymmetry that hides this: `$HOME` is not symlinked, so production paths usually agree by accident, while `FileManager.temporaryDirectory` is always `/var/folders/…` → `/private/var/folders/…`. A path-comparison test failing here is a real bug, not a temp-directory artifact — and passing in production is not evidence the code is right.

### Match identity across reloads

`EspansoMatch.id` is a UUID minted at decode time and excluded from YAML. On reload, `reassociateIDs` re-attaches prior UUIDs by matching on primary trigger (or regex pattern) so the editor's selection survives an external edit elsewhere in the file. `IDReassociationTests` covers it.

### Subprocess handling

Every `Process` in the codebase (`EspansoProcessManager.run`, `BackupManager`'s `zip`/`unzip`) follows the same shape, and the deviations have each caused a shipped hang: **drain the pipe to EOF before `waitUntilExit()`**, because output past the ~64 KB pipe buffer blocks the child forever; return early if `proc.run()` throws, since our end still holds the write side and the read would never see EOF; and send unread stdout to `FileHandle.nullDevice` rather than an undrained `Pipe()`. `resolveMatchDirectory` additionally races a 3s deadline and kills the child, so a wedged espanso binary can't block launch.

`EspansoProcessManager` parses `espanso status` output as strings, verified against espanso v2.4.1 — it's the fragile seam on espanso upgrades. Pass `espansoPath:` to the initializer in tests.

**`espanso status` reports daemon liveness only.** It is documented as "Check if the espanso daemon is running or not" and prints `espanso is running` whether or not expansion is enabled; no `espanso cmd` subcommand (`enable`/`disable`/`toggle`/`search`) queries that state. `DaemonState` therefore has no `disabled` case, and nothing may branch on one. Code that did shipped three bugs at once: the menu toggle could only ever disable, an expiring snooze never re-enabled, and the "Espanso Enabled" checkmark always read enabled. Turn expansion on or off with an explicit `setExpansions(enabled:)`; when you genuinely mean "flip it", delegate to espanso's own `cmd toggle` (`toggleExpansions()`) rather than reading a state that isn't there.

### Packages are read-only

Anything under `<matchdir>/packages/` is espanso-managed: excluded from writes, from backups (`zip -x 'packages/*'`), from restores, and from replace-mode cleanup. `isPackage` is computed by prefix against the known config root, not a path search.

### Backups vs. snapshots

Both are zips of the match directory. Backups are user-initiated to a chosen path (`.macspanso` extension); snapshots are automatic — one per editing session, taken the first time the Match Manager opens with a non-empty store, rotating at 10, in Application Support. Replace-mode restore calls `deleteUserMatchFiles`, which must cover both `.yml` and `.yaml` (espanso loads both — see `matchExtensions`).

### Preferences, launch at login, hotkeys

`Preferences` (`Store/Preferences.swift`) is the only place that names a `UserDefaults` key; the one `@AppStorage` in the codebase (`MatchListView`'s sort order) binds through `Preferences.Key`. The key strings predate it and are pinned by `PreferencesTests.testKeysAreFrozen` — renaming one orphans every user's stored value. It takes an injectable `UserDefaults`; tests use a throwaway suite so they never share `.standard`. Consumers (`EspansoProcessManager`, `UpdateChecker`) accept an optional `Preferences` and fall back to `.shared` *inside* the init body: a `= .shared` default argument is evaluated outside the main actor and the toolchain flags it. `UpdateChecker` also takes a `fetch` closure and a `currentVersion`, which is how `UpdateCheckerTests` exercises the automatic-check gate without touching GitHub.

Two things are deliberately not in `Preferences`:

- **Launch at Login** is never persisted. `LoginItem.shared` (`App/LoginItem.swift`) reads `SMAppService.mainApp.status` live every time it is shown, because the user can flip it in System Settings › Login Items at any moment. It also surfaces `.requiresApproval`, which reads as "off" without that hint. It is a single shared instance because the status menu and the Settings window show the same toggle and must see each other's changes.
- **Global hotkeys** are owned by the `KeyboardShortcuts` package. Names and initial combos live in `App/Shortcuts.swift`; storage is the package's own defaults keys. The status-menu items get their key equivalents from `setShortcut(for:)` rather than a hardcoded copy, and the global registrations are disabled while the menu is open (`menuWillOpen`/`menuDidClose`) so a combo doesn't fire twice. Anything that shows a combo to the user must read `KeyboardShortcuts.getShortcut(for:)` — it can be changed or cleared.

### Menu-bar and window presence

`MenuBarController` flips `NSApp.setActivationPolicy` to `.regular` while the Match Manager window is open (so it appears in Cmd-Tab and the Dock) and back to `.accessory` on `willCloseNotification`. Activation deliberately uses the deprecated `NSApp.activate(ignoringOtherApps: true)`: for an accessory app the macOS 14 no-arg variant can silently no-op. `MatchManagerWindowController.placement(forFrame:visibleFrames:)` is pure and unit-tested — it requires half the window's area on one screen rather than a bare `intersects`, because a 1px sliver after a display change reads as "visible" and the window appears not to open.

Focus commands (new match, about) reach SwiftUI through `NotificationCenter` posted one run-loop cycle late, so the view's `.onReceive` is wired up before the notification fires.

The Settings window is the SwiftUI `Settings` scene (`SettingsView`), not a second window controller: that gives ⌘,, toolbar tabs, and frame autosave for free and guarantees one instance. The status menu opens it by activating first — an accessory app's window can otherwise open behind the frontmost app — and then performing the **application menu's own Settings item**, located by its ⌘, key equivalent (`MenuBarController.settingsItemIndex(in:)`, unit-tested; the title is localized and changed name in macOS 13).

Do not "simplify" that back to `NSApp.sendAction(Selector(("showSettingsWindow:")))`. That selector resolves — SwiftUI's internal app delegate answers it and `sendAction` returns `true` — but on macOS 26 no window appears. The menu item is then a silent no-op *and* the `true` return hides it, so a guard on the return value proves nothing. The item SwiftUI wires to the scene carries a `menuAction:` callback instead, and performing it opens the window. This was found by probing a running build, not by reading the code, which is the only way that failure shape is visible.

Opening Settings deliberately does not flip the activation policy; only the Match Manager does that. Because a `Settings` scene cannot be handed dependencies, `SettingsView` reaches state through `Preferences.shared`, `LoginItem.shared`, the package, and `(NSApp.delegate as? AppDelegate)?.updateChecker` for the one action that needs it — keep it that way rather than threading the store in.

## Testing conventions

XCTest, `@testable import macspanso`. Classes that touch the actor-isolated types are `@MainActor` (`EspansoConfigStoreTests`, `BackupManagerTests`, `EspansoProcessManagerTests`, `PreferencesTests`, `UpdateCheckerTests`, `SettingsMenuItemTests`, `TriggerConflictTests`, `RoundTripPreservationTests`); the pure-logic ones are not (`MatchValidationTests`, `MatchExpanderTests`, `YAMLParsingTests`, `YAMLSerializationTests`, `TriggerModeTransitionTests`, `MatchManagerWindowPlacementTests`, `IDReassociationTests`). Tests build a real temp directory per test in `setUp` and write real YAML — there are no mocks or protocol seams. Most non-UI logic is reachable because the pure parts (`MatchValidator`, `MatchExpander`, `TriggerModeTransition`, `YAMLSerializer`, window placement, ID reassociation, the Settings menu-item lookup) are `static`/`nonisolated` and free of app state.

## Notes

- `CHANGELOG.md` entries are user-facing prose: bolded symptom, em dash, then what went wrong and what changed. Match that register rather than listing commits.
- This is a fork (`4rc0s/macspanso`); upstream is `jeffcaldwellca/macspanso`. Release DMGs come from upstream — this fork's CI produces ad-hoc-signed artifacts only.

## Upstream-owned files — do not bump

`docs/` and `Casks/macspanso.rb` describe upstream's published release, not this fork's build. **Leave both alone**, including when bumping the version:

- `docs/` is upstream's marketing site vendored into the repo. Every URL in it points at `www.jeffcaldwell.ca/macspanso/` (`robots.txt`, `sitemap.xml`, and the canonical/OG tags in `index.html`), and there is no `CNAME` here, so this fork does not publish it. The version strings in `index.html` (the `softwareVersion` JSON-LD and the footer) are upstream's to update.
- `Casks/macspanso.rb` is a template. `release.yml` rewrites the cask in the *tap* repo (`jeffcaldwellca/homebrew-tap`, checked out to `tap/`), never this copy — so the in-repo version and its `PLACEHOLDER_UPDATED_BY_RELEASE_WORKFLOW` sha are inert by design.

`release.yml` cannot run here regardless: it needs `TAP_TOKEN` (a PAT scoped to upstream's tap) and Developer ID signing secrets, neither of which this fork has. There is no "tag time" for this fork. If work goes upstream as a PR, leaving these untouched is also the right hygiene — they are the maintainer's release surface.
