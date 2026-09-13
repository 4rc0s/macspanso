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

macspanso models only a subset of espanso's schema, but rewrites whole files. Anything unmodeled that is not deliberately preserved gets **destroyed on save**. Three tiers carry it, one per level of nesting:

- `MatchFileContent.extras` — every top-level key besides `matches:` (`global_vars:`, `imports:`, …)
- `EspansoMatch.extras` — every per-match key outside `CodingKeys` (`markdown:`, `html:`, `image_path:`, `paragraph:`, …)
- `EspansoVar.extras` — every per-var key outside `CodingKeys` (`inject_vars:`, `depends_on:`, which espanso documents on *every* variable type)

All three use `YAMLAny` (`Model/YAMLAny.swift`), a recursive `Codable` enum, and all three are re-emitted by hand-written `encode(to:)` implementations. **When adding a field to `EspansoMatch` or `EspansoVar`, add it to that type's `CodingKeys` too** — `knownKeys` derives from `CodingKeys.allCases`, so a property that skips it will be both decoded into the model and duplicated into `extras`. `RoundTripPreservationTests` guards all three tiers.

The var tier was added last and is instructive about how these gaps hide. `inject_vars`/`depends_on` were silently dropped on every save, and two espanso shapes — a `choice` var's `values:` list of mappings and a `form` var's `fields:` mapping — couldn't be represented at all, so a file containing either failed to decode and became an uneditable `parseError`. Both causes are gone: var params are now `[String: YAMLAny]` (there is no second, narrower YAML value enum to drift), and `VarType` carries an `unknown(String)` case so a type espanso adds later round-trips instead of quarantining the file. `VarType` is therefore not `CaseIterable` — the picker iterates `VarType.known`, and `isEditable` marks the types with no editor, whose params are shown read-only.

**Known hole: YAML anchors are not preserved.** espanso documents `anchors:` plus `&name`/`*name` aliases as the compact way to share one script across matches ([docs](https://espanso.org/docs/matches/extensions/#anchors-and-aliases)). Yams resolves aliases while composing the node graph and keeps no anchor name on the resulting value, so any save inlines the shared body at every use site — the `anchors:` block and the body both survive and espanso behaves identically, but the user's DRY structure is flattened. Fixing it means threading anchor identity through `YAMLAny`, `EspansoVar`, `FormField`, and `EspansoMatch`, because the Codable layer is where it is dropped; Yams *does* model anchors at the `Node` level (`Node.anchor`, `.alias`, and a Codable hook via `Node.anchorKeyNode`). `Emitter.Options.redundancyAliasingStrategy` is not a shortcut — it invents anchor names and aliases subtrees the user never shared. `RoundTripPreservationTests.testYAMLAliasesAreInlinedOnRoundTrip` pins the current behavior with a strict `XCTExpectFailure`, so it turns red when someone fixes this; delete this paragraph when it does.

A corollary: never write into a file whose `parseError != nil`. A file that failed to parse holds nothing in memory, so writing it out replaces its real contents with an empty document. `add()` and `move()` enforce this with an explicit guard. `update()` and `delete()` need none — both resolve their target by searching `matchFiles` for a match ID, and a parse-errored file is stored with `matches: []`, so it can never be found. That distinction matters when adding a write path: if it targets a file directly rather than via a match it contains, it needs the explicit guard.

`renameFile()` and `deleteFile()` are the two paths that do target a file directly, and they satisfy the rule by not writing YAML at all on the dangerous side. A rename is `FileManager.moveItem` — content never passes through the Codable layer, which is why an open editor and every match ID survive it. A delete removes the source outright and guards `parseError` only on the *destination* it appends to. A parse-errored group is therefore deletable but not moveable, which is the honest offer: there is nothing legible to move.

### Write targets must be somewhere espanso looks

`validateWriteTarget` gates every path that writes to a file the user named (`add`, `move`, `deleteFile`'s destination). Two conditions, and the second is the one that was missing: the extension must be in `matchExtensions`, **and** the path must be under the match directory. Neither failure is visible without the guard — the write succeeds, `matchFiles` gains an entry, the match renders, and the next `load()` drops it, having never once expanded. The `NSSavePanel` behind **New Group…** opens on the match directory but does not confine the user to it, so the containment half is not theoretical.

Containment resolves symlinks on the candidate because `init` resolved the root — both operands or neither, per the URL-identity rule below.

### Write-then-commit ordering

`YAMLSerializer.write` decodes its own output and compares it to the model before anything reaches disk — on a mismatch it throws and the file keeps its previous contents. Yams emits from a node tree, so malformed *syntax* is near-impossible and is not what this guards; the risk in an app that rewrites whole files it doesn't own is emitting something well-formed that no longer says what the model said. `id` is aligned before the comparison because it is minted at decode and never serialized. The check is cheap (files are small) and has no false positives on ambiguous YAML scalars — quoted digits, `yes`, whole floats, big ints, nulls, empty strings are all pinned by `testVerificationAcceptsAmbiguousScalars`. Nothing else in the app validates YAML: there is no linter, and `MatchValidator` checks app-level rules (triggers, variable references), not espanso's schema. **Restore and import are deliberately exempt** — `BackupManager.unzipBackup` extracts through `/usr/bin/unzip` straight into the match directory and never goes through `YAMLSerializer.write`, because a recovery tool must restore verbatim; refusing to restore a backup because it can't round-trip would defeat the point. Restored content is still covered on the next edit, so a non-round-trippable file fails safe and loudly then. Note also what the check cannot see: it compares decode(encode(model)) against model, so both sides share the decoder's blind spots. Anything `init(from:)` drops is invisible to it — YAML anchors, above. This is exactly how the var-tier losses went unnoticed: verification passed on every save that dropped `inject_vars`, because both sides of the comparison had already dropped it.

Every mutating path on the store writes to disk **first** and only updates `matchFiles` if the write succeeded. This is deliberate — a failed write that had already mutated memory would leave the UI showing matches that don't exist on disk. Preserve this ordering in new write paths. `EspansoConfigStoreTests` makes the temp directory read-only (`0o555`) to force write failures, which works because writes are atomic (temp file + rename in the same directory).

`deleteMatches(_:)` generalizes this to N files in one call (grouping targets by file, one write each) rather than the one-write-per-match loop every bulk-delete call site used to run. Its rollback on a partial failure — put every file already written this call back the way it was, then rethrow — depends on iterating in a **deterministic order**. It groups by index into `matchFiles` via a `Dictionary`, and `Dictionary` iteration order is unspecified in Swift, not merely unsorted; sort the keys before iterating (`.sorted(by: { $0.key < $1.key })`) wherever a partial failure must be reproducible rather than dependent on hash-seed luck. This bit once already, quietly: an early version of the test for this exact rollback passed against code with the rollback removed, because the immutable (failing) file happened to be visited first often enough that the rollback branch was never actually exercised. `undoDelete()` has the same shape (grouped by URL) and is sorted by path for the same reason.

### Undo is a short-lived, single-level buffer — not a stack

`deleteMatches` is the only path that populates `pendingUndo` (`EspansoConfigStore.PendingDelete` — per-file entries of `(url, match, originalIndex)` plus a display label), and it *replaces* rather than merges on every call: deleting B after deleting A makes A ungrievable, by design. Every other mutating method (`add`, `update`, `move`, `duplicate`, `renameFile`, `deleteFile`, `load`, `reloadFile`, `handleDirectoryChange`) clears it as its first statement. A general undo stack would need every entry's recorded index re-validated against however many intervening edits happened since — not worth the complexity for what this is: a grace period against an accidental delete, not a history feature. `undoDelete()` clamps each `originalIndex` to the file's current length and skips a file that's vanished entirely, so a stale buffer degrades to "restore what's still restorable" rather than crashing or throwing.

`pendingUndo` is a plain `@Published var`, not `private(set)` — matching `externallyChangedURL` just above it. `private(set)`'s setter is scoped to the *declaring file*, not the module, so `@testable import` from a test file cannot assign it regardless; a test that needs to construct a `PendingDelete` directly (to exercise the clamp/skip behavior against a stale index no real code path can currently produce) needs the setter to be at least `internal`.

### Trash, not a custom soft-delete convention

`deleteFile`'s two user-facing removals (outright delete, and the source removal after a successful move-matches-elsewhere) go through `trashHandler` — production default `FileManager.trashItem`, giving the user Finder's Put Back for free. The **third** `removeItem` in that method, compensating for the app's own just-created destination file when the source removal subsequently fails, stays plain `removeItem` on purpose: it's never user-facing, and trashing it would litter the user's Trash with internal artifacts. `trashHandler` is an injectable `var` for exactly this reason — tests substitute a plain `removeItem` (or a recording spy) so routine test runs never touch the real Trash.

Deliberately rejected: renaming a deleted file with a dot-suffix, or parking it in a subfolder inside the match directory. Either would be invisible to `scanMatchDirectory` (filtered to `matchExtensions`) without building a whole "recently deleted" browsing feature, and would plant a convention only this app understands inside a directory meant to be a clean, hand-editable, synced mirror of espanso's own files — the same shape of mistake the grouping model above avoids for a different feature. The real Trash already solves retention, discovery, and recovery UI for free.

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

### Editor drafts and view identity

`MatchEditorForm` seeds its `draft` from `State(initialValue:)` in `init`, and SwiftUI applies those seeds only when the view's identity changes. The manager keys the form by match UUID plus an `editorGeneration` counter, and `reassociateIDs` deliberately keeps UUIDs stable across reloads — the combination means store content can be swapped out from under an open form without the draft noticing. The save path bumps `editorGeneration` for exactly this reason, so any new path that replaces a selected match's store content must bump it too: the external-edit banner's Reload does (`reloadExternallyChangedFile`), with the semantics "adopt disk everywhere" — in-progress edits are discarded, which is what Reload promises; "Keep Mine" leaves the form untouched. A stale draft is worse than a stale display: `isDirty` compares against the (new) `initialMatch`, so the form shows unsaved changes nobody made, and Save would silently write the old content back over the external edit. The deployment target is macOS 13, so the two-parameter `onChange(of:)` that could adopt reloaded content in place is unavailable — the identity bump is the mechanism.

The same staleness reaches any URL the form holds in `@State`, and grouping added one. `currentFileURL` is looked up live for exactly this reason, but `destinationURL` — captured the moment the user touches the **Group** picker — is not, so renaming or deleting that group left Save moving the match to a path that no longer existed, recreating the old file. `resolvedDestination` drops a destination that is no longer in `store.writableFiles`, with `destinationIsNewGroup` marking the one legitimate exception: a group the user asked to create, which by definition doesn't exist yet.

### Preview fidelity

`MatchExpander.preview` must mirror espanso's own interpolation regex (`\{\{\s*(\w+)\s*\}\}`) and never be more permissive than the renderer: a preview that substitutes what espanso passes through as literal text lies in the one direction the user cannot check. This bit once — the expander substituted by literal string match, so `{{short-date}}` rendered a filled-in date espanso never produces (`\w` has no hyphen). `MatchValidator.invalidVarName` now rejects declared var names espanso could never reference, but a hyphenated token in the replace text with no var behind it is deliberately not an error — espanso passes it through and the user may want the literal output; the preview showing it raw is the signal. The agreement is pinned by the interpolation-fidelity tests in `MatchExpanderTests` and `MatchValidationTests`.

Two places must spell the brace-interpolation regex the same way, and they are easy to fix one at a time: `MatchExpander.preview` (substitution) and `MatchValidator.varReferences` (is this text a reference?) both need `\{\{\s*(\w+)\s*\}\}`. The expander was widened to allow `\s*` inside the braces while `varReferences` was left at `\{\{(\w+)\}\}`, so for a while `{{ name }}` was interpolated by espanso, filled in by the preview, and checked by nobody — a typo in that form saved clean. `MatchValidator`'s `invalidVarName` check is related but not the same regex: it validates a declared name in isolation (`^\w+$`, no braces), answering "is this name referenceable at all?" rather than "does this text reference something?". Touching the interpolation regex means touching both `preview` and `varReferences`; `invalidVarName` only needs to agree on which characters make a name legal.

### Grouping is files, not a category

The grouped list (`FileTreeView`, the default; the flat list is one toolbar button away) maps a group 1:1 onto a match file. That is deliberate: the file is espanso's own unit of organisation, the user can rearrange it by hand, and espanso reloads on the change — a parallel categorization stored anywhere else would be a second source of truth nothing but this app could read. So renaming a group is `FileManager.moveItem`, deleting one is deleting a file, and dragging a match between groups is `move()`.

`EspansoConfigStore.groupedFiles` returns one `FileGroup` per *parent directory* (root files first, then folders by path) — folders at any depth collapse to one flat level labeled by the relative path, because espanso imposes no meaning on directory depth. `displayLabel(for:)` is the label everywhere several files are listed together; it hides the extension and falls back to the relative path — extension included — only when two files share a base name, since `.yml` vs `.yaml` may be the only thing distinguishing them.

Two things to preserve when touching this view. `conflictingFileURLs` rebuilds the whole cross-file conflict map, so read it once into a `let` at the top of `body` rather than per row — `MatchListView.flatList` is the pattern. And the badge beside a group counts `visibleMatches(in:)`, not `file.matches`, so it agrees with the rows under it while a search is narrowing them.

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

XCTest, `@testable import macspanso`. Classes that touch the actor-isolated types are `@MainActor` (`EspansoConfigStoreTests`, `BackupManagerTests`, `EspansoProcessManagerTests`, `PreferencesTests`, `UpdateCheckerTests`, `SettingsMenuItemTests`, `TriggerConflictTests`); the pure-logic ones are not (`MatchValidationTests`, `MatchExpanderTests`, `YAMLParsingTests`, `YAMLSerializationTests`, `TriggerModeTransitionTests`, `MatchManagerWindowPlacementTests`, `IDReassociationTests`). `RoundTripPreservationTests` is neither: the class is not annotated and only its two store-touching methods are `@MainActor`, which is the pattern to copy when a mostly-pure suite needs one store test. Tests build a real temp directory per test in `setUp` and write real YAML — there are no protocol seams, and the one closure-based seam (`EspansoConfigStore.trashHandler`, substituted so tests never touch the real macOS Trash) is the exception rather than the pattern to reach for by default. Most non-UI logic is reachable because the pure parts (`MatchValidator`, `MatchExpander`, `TriggerModeTransition`, `YAMLSerializer`, window placement, ID reassociation, the Settings menu-item lookup) are `static`/`nonisolated` and free of app state.

## Notes

- `CHANGELOG.md` entries are user-facing prose: bolded symptom, em dash, then what went wrong and what changed. Match that register rather than listing commits.
- This is a fork (`4rc0s/macspanso`); upstream is `jeffcaldwellca/macspanso`. Release DMGs come from upstream — this fork's CI produces ad-hoc-signed artifacts only.

## Upstream-owned files — do not bump

`docs/` and `Casks/macspanso.rb` describe upstream's published release, not this fork's build. **Leave both alone**, including when bumping the version:

- `docs/` is upstream's marketing site vendored into the repo. Every URL in it points at `www.jeffcaldwell.ca/macspanso/` (`robots.txt`, `sitemap.xml`, and the canonical/OG tags in `index.html`), and there is no `CNAME` here, so this fork does not publish it. The version strings in `index.html` (the `softwareVersion` JSON-LD and the footer) are upstream's to update.
- `Casks/macspanso.rb` is a template. `release.yml` rewrites the cask in the *tap* repo (`jeffcaldwellca/homebrew-tap`, checked out to `tap/`), never this copy — so the in-repo version and its `PLACEHOLDER_UPDATED_BY_RELEASE_WORKFLOW` sha are inert by design.

`release.yml` cannot run here regardless: it needs `TAP_TOKEN` (a PAT scoped to upstream's tap) and Developer ID signing secrets, neither of which this fork has. There is no "tag time" for this fork. If work goes upstream as a PR, leaving these untouched is also the right hygiene — they are the maintainer's release surface.
