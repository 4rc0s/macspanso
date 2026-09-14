# Changelog

## [Unreleased]

## [1.8.0] - 2026-09-13

### Added
- **The menu shows when espanso is paused** — espanso itself cannot be asked whether expansion is on or off, so the header used to say "Espanso running" even when nothing you typed would expand. macspanso now watches espanso's own daemon log, which records every enable, disable, and toggle — including ones made from espanso's tray icon, its keyboard shortcut, or the terminal — and shows **◌ Espanso paused** in yellow while expansion is off. The header's status glyph is now colored the same way elsewhere: a green circle while espanso is expanding, red when it has stopped. As a self-check, every enable, disable, and toggle macspanso sends must show up in that log within moments; when it doesn't, the header quietly falls back to just "running" rather than trusting a state it can no longer see. Snoozing and re-enabling are unchanged: they never needed to read the state to do the right thing.
- **Matches are grouped by file** — the match list now shows your matches under the file each one lives in, which is espanso's own unit of organisation rather than a category invented by this app: the same grouping is what you see editing the files by hand. Group labels drop the `.yml`, since the extension is espanso's loading rule and not a name you chose, and two groups that would read the same fall back to their folder path. Subfolders collapse into one level you can fold away. The toolbar button on the right switches back to the flat list at any time.
- **Groups can be renamed, deleted, and rearranged** — **Rename…** and **Delete Group…** live in a group's context menu. Deleting offers to move the matches into another group first, so nothing is thrown away by accident; a group whose file couldn't be read can only be deleted outright, because there is nothing legible to move. Renaming is a file rename and never rewrites the YAML, so comments and formatting are untouched and an open editor keeps its place. Matches move between groups by dragging them onto a group label, from **Move to** in their context menu, or from the **Group** picker in the editor, which now works on an existing match and not only a new one.
- **Deleting a match can be undone** — deleting one match, or several at once, now shows a brief **Undo** banner that puts them back exactly where they were. It covers the single most recent delete and disappears after a few seconds or as soon as you do something else, rather than trying to be a full undo history. Deleting a whole group's file now moves it to the Trash instead of removing it outright, so it can be recovered from Finder the same way any other deleted file can.

### Fixed
- **A new group saved outside the espanso folder silently did nothing** — the **New Group…** panel opened on the match folder but let you navigate anywhere, and the app only checked the file name, not where it was going. Saving to the Desktop wrote the file, showed the match in the list, and then lost it on the next launch — espanso never loads anything outside its own match folder, so the snippet had never once expanded. Any destination outside the match folder is now refused with an explanation, whether it arrives from the save panel, a drag, or the **Move to** menu.
- **Typos in a spaced variable reference went unreported** — `{{ name }}` with spaces inside the braces is interpolated by espanso, and the preview filled it in, but validation didn't recognise it as a variable reference at all: a misspelled name in that form raised no warning and saved cleanly. Validation now reads references exactly as espanso and the preview do.
- **Deleting a group lost your place even when nothing was deleted** — choosing to move a group's matches into another group first still cleared the selection and closed the open editor, as though the matches had been thrown away rather than simply relocated.
- **The "changed externally" banner could get stuck** — if the file it referred to was renamed or deleted before you answered it, **Reload** had nothing to read and quietly did nothing, leaving a dead button and a banner only **Keep Mine** would dismiss. The notice now follows a renamed file and clears when its file is gone.
- **A group's match count ignored the search box** — while searching, the number beside a group counted every match in the file rather than the ones shown beneath it.
- **The drop highlight could disappear mid-drag** — dragging a match from one group onto another sometimes cleared the highlight on the group being entered, so there was nothing showing where the match would land.
- **A group renamed with the editor open could resurrect the old file** — if the **Group** picker had been touched before the rename, saving moved the match to the path the group used to have, recreating it under the old name.

## [1.7.0] - 2026-09-13

### Added
- **Match labels** — a match can now be given a name, shown beside its trigger in the list. The match list and the Quick Switcher have always searched labels, but there was no way to set one short of editing YAML by hand; espanso shows the label in its own search bar too.
- **Variable settings are no longer lost, and two kinds of file can be opened again** — `inject_vars` and `depends_on` on a variable were read and then quietly dropped every time the file was saved. Separately, a file containing a **choice** variable, or a **form** variable with fields, couldn't be read at all: it showed as unparseable and couldn't be edited in macspanso. Both are fixed, and a variable type espanso adds in future will now be preserved rather than making the file unreadable.
- **Saves are checked before they touch disk** — when macspanso rewrites a match file it now reads its own output back and compares it against what it meant to write. If anything fails to survive the trip the save is refused with an explanation and the file keeps its previous contents, rather than the rewrite landing and the loss being noticed later.
- **Advanced match options** — a collapsed **Advanced** section in the match editor exposes five more espanso options: matching only at the start or end of a word, the capitalisation style used alongside **Propagate case**, whether the replacement is pasted from the clipboard or typed as keystrokes (the fix for long or multi-line text in apps that drop characters), extra search terms that find the match in espanso's own search bar, and a free-text comment. Options you don't touch are left out of the file entirely rather than written as defaults.

### Fixed
- **Reloading after an external edit left the open editor in the past** — with a match open in the editor, choosing **Reload** on the "changed externally" banner updated the match list but not the editor: its Replacement and Variables boxes kept the pre-reload content and showed unsaved changes nobody had made, so saving would have written the old content back over the external edit. The editor now starts fresh from the reloaded match, the same way it does after a save. In-progress edits are discarded by Reload — that is what it promises; **Keep Mine** still leaves everything untouched.
- **Some validation errors blocked saving without ever being shown** — a duplicated variable name or a shell variable with an empty command made Save unusable but appeared nowhere on screen, so the match looked fine and refused to save. Both are now reported beside the other variable warnings.
- **The preview filled in dates espanso would never produce** — a variable name containing a hyphen, or anything besides letters, digits, and underscores, cannot be used by espanso's interpolation, so text like `{{short-date}}` stays on screen as-is when the snippet fires. The preview substituted it anyway, showing a filled-in date that never arrived, and validation stayed silent because it never recognised the token as a variable reference at all. The preview now follows espanso's own rules — including optional spaces inside the braces — and the editor reports an unreferenceable variable name as an error rather than saving it. A hyphenated token in the replacement text with no variable behind it is still allowed, since espanso deliberately passes those through and the text may be wanted literally.
- **Expansions could be switched off but not back on** — the menu's **Espanso Enabled** item decided which way to flip by reading `espanso status`, but that command only reports whether the espanso daemon is running, never whether expansion is enabled. It therefore always took the "disable" branch: a second click disabled again, and there was no way back from the menu or from the Shortcuts action. The menu now offers explicit **Enable Expansions** and **Disable Expansions** commands, and the Shortcuts **Toggle Espanso** action asks espanso itself to flip the state.
- **Snooze never ended** — when a snooze ran out, expansion was only switched back on if macspanso believed it was currently disabled, which it had no way to know. Espanso stayed disabled indefinitely while the menu showed it as enabled, and starting a snooze before the first status check silently didn't disable anything at all. Both ends of a snooze now act unconditionally.
- **The menu said expansion was on when it was off** — the **Espanso Enabled** checkmark was driven by whether the daemon was alive, so it stayed ticked after expansion was turned off. The status line now reads **Espanso running**, which is what can actually be determined.

## [1.6.0] - 2026-09-13

### Added
- **Settings window** — press **⌘,** or choose **Settings…** from the menu for a proper settings window with General and Shortcuts tabs. Launch at Login lives there as well as in the menu, and it now tells you when macOS is still waiting for you to approve it in System Settings › Login Items.
- **Customisable hotkeys** — ⌃⇧M and ⌃⇧N are now defaults rather than fixed. Record any combination in Settings › Shortcuts, or clear one to turn it off; the menu shows whatever you chose.
- **Automatic update checks can be turned off** — the once-a-day check against GitHub is now a toggle in Settings › General. **Check for Updates…** in the menu always works regardless.

### Fixed
- **⌘, opened a blank window** — pressing ⌘, while the Match Manager was open showed an empty settings window. It now opens the real one.

## [1.5.0] - 2026-09-13

### Added
- **System-wide hotkeys** — press **⌃⇧M** to open the Match Manager and **⌃⇧N** to start a new match, from any app, without opening the menu. They need no Accessibility or Input Monitoring permission, and they sit beside espanso's own ⌃⇧Space without colliding with it. These replace the old ⌘M / ⌘N menu shortcuts, which only worked while the menu bar menu was open.
- **Match Manager in the Cmd-Tab switcher** — while its window is open, macspanso behaves as a regular app, so you can switch back to the Match Manager with Cmd-Tab and it appears in the Dock. It returns to menu-bar-only once the window closes.

### Fixed
- **Backups and restores could hang on large match directories** — `zip` and `unzip` print one line per entry, and once that output passed the 64 KB pipe buffer the child process blocked forever, freezing the export or restore. Output is now discarded and error output is drained before waiting, the same way espanso commands were fixed in 1.4.0.
- **Restoring in replace mode left stale `.yaml` files behind** — cleanup only removed `.yml` files, so matches in `.yaml` files survived the restore and reappeared alongside the restored set. Both extensions espanso loads are now cleaned up; `packages/` is still never touched.
- **Adding a match to an unparseable file wiped it** — a file whose YAML failed to parse holds nothing in memory, so writing a new match into it replaced everything already on disk. Adding to such a file is now refused with a message telling you to fix the YAML first, matching the protection that already covered moving matches between files.
- **Failed imports and restores could leave the app showing matches that no longer existed** — if extraction failed partway, the match list kept displaying entries whose files had already been removed. The store now resyncs with disk before the error is reported.

## [1.4.1] - 2026-06-28

### Fixed
- **Match Manager sometimes didn't open after switching displays** — opening Match Manager from the menu bar could silently do nothing, most often right after disconnecting an external monitor or switching to the built-in display. A display change can leave the window straddling a screen edge with only a sliver on screen; the previous check treated any overlap as "visible", so the window was ordered front where you couldn't see it. It now recenters unless a real portion of the window is reachable on a current display, and the app is brought forward more reliably as a menu-bar (accessory) app.

## [1.4.0] - 2026-06-10

### Fixed
- **Settings beyond matches no longer deleted on save** — editing a match in a file containing `global_vars:`, `imports:`, or any other top-level key used to silently erase those keys when the file was rewritten. Unmodelled per-match options (`markdown:`, `html:`, `image_path:`, `paragraph:`, …) were dropped the same way. All YAML the editor doesn't model now survives every save.
- **espanso commands could hang the app** — command output larger than 64 KB (e.g. `espanso log`) deadlocked the process runner, and a missing espanso binary left it blocked forever. Match-directory detection now also times out after 3 seconds and falls back to the default location instead of waiting on a stuck binary.
- **References to global variables blocked saving** — a `{{name}}` referencing a `global_vars:` declaration in another file was flagged as unresolved and disabled the Save button.
- **Regex toggle could write invalid YAML** — switching a multi-trigger match to Regex and back produced both `trigger:` and `triggers:` keys on the same match.
- **Failed saves no longer desync the app** — if a disk write failed, deletes and adds could show state that didn't match the file, and external-edit detection could be silently disabled for the rest of the session. All write paths now keep memory and disk consistent and recover cleanly.
- **Snooze now ends on time after sleep** — sleeping the Mac through a snooze's end time left espanso disabled; expiry is now checked by the regular status poll.
- **Date preview literal text** — formats like `Updated: %Y` or `%d days` no longer mangle literal letters in the preview, and `%%` renders as a literal percent.
- **Backups no longer touch espanso packages** — exports skip `packages/`, and restores never overwrite installed packages, even from older backups that contained them.
- **Window stays visible when switching apps** — the Match Manager no longer hides when macspanso loses focus.
- **Symlinked match directories** — file identity now resolves symlinks, preventing duplicate file entries when the config path goes through a symlink.

### Added
- **`.yaml` support** — match files with the `.yaml` extension are now loaded alongside `.yml`.
- **Live detection in subfolders** — files added or removed inside subdirectories of the match folder are now picked up immediately, not just at the top level.
- **Conflict badges in the match list** — triggers defined in more than one file show an inline warning badge in the main list, not just the file tree.
- **Delete confirmations** — deleting multiple matches at once now asks first.
- **Session safety snapshot** — opening the Match Manager automatically snapshots your match files (rotating, last 10 kept), so any editing session can be rolled back from "Restore from Snapshot".
- **Update check feedback** — "Check for Updates…" now reports up to date, update available, or network failure instead of silently doing nothing.

### Improved
- **Menu freshness** — the menu bar menu rebuilds each time it opens, so the snapshot list and Launch at Login state are always current; stale update checks re-run on open.
- **Release safety** — CI and the release pipeline now run the full test suite (71 tests, up from 43) with per-test timeouts before any build ships.

## [1.3.5] - 2026-05-06

### Fixed
- **Match Manager window invisible after display changes** — when docking, undocking, or disconnecting an external monitor, opening Match Manager from the menu bar could fail silently because the window was being restored at coordinates no longer covered by any screen. The window now recenters if its frame doesn't intersect a visible screen.
- **Match Manager window stuck on another Space** — the panel now follows you to the active Space instead of staying on whichever Space it was last opened on.

## [1.3.0] - 2026-05-05

### Added
- **Duplicate match** — context menu and ⌘D create a copy with an auto-suffixed trigger.
- **Move match between files** — "Move to" submenu in row context menu, with atomic write and rollback on failure.
- **Choose destination file** — when creating a new match, pick which `.yml` file it lands in. New File… prompts a save panel. Last-used destination is remembered.
- **Live expansion preview** — read-only preview pane below the replacement field resolves date, echo, clipboard, and random variables. Shell and script values render as safe placeholders without executing.
- **Quick switcher (⌘P)** — Spotlight-style fuzzy finder over all triggers, labels, and replacements. Arrow keys to navigate, Enter to jump.
- **Empty-state onboarding** — first-run experience with starter chips for signature, current date, and clipboard paste.
- **Sort options** — flat list can sort by file order, trigger A→Z, or trigger Z→A. Choice persists.
- **Search filter chips** — filter by All / Text / Form / Regex / Vars; combines with search text.
- **Match counts** — toolbar shows total matches and current filtered count.
- **Reorder alternate triggers** — up/down arrows reorder triggers within a multi-trigger match.
- **Regex tester** — when regex mode is on, a test-input field shows live match results.
- **Multi-select operations** — ⌘-click and shift-click to select many matches; bulk-action panel offers Delete All and Move to.
- **Snooze espanso** — temporarily disable for 15 min, 1 hour, 4 hours, or until tomorrow. State persists across launches and the menu header reflects the snooze window.
- **Cross-file conflict detection** — duplicate triggers spanning multiple files now show a badge in the file tree and a Conflicts section in Diagnostics.
- **Espanso log viewer** — live tail of `espanso log` with auto-refresh and error highlighting, accessible from About.
- **Versioned auto-backups** — destructive imports and snapshot restores automatically snapshot the current state first. "Restore from Snapshot" submenu lists the last 10.
- **App Intents** — Toggle Espanso, Restart Espanso, Snooze Espanso, and New Match From Clipboard intents are now available in Shortcuts.app, Spotlight, and Siri.

### Improved
- **Stable match identity** — selection now survives external file edits. When a file is reloaded, UUIDs are re-associated to existing matches by trigger so the editor stays open on the same match.
- **Match list rows** — regex matches now show a `regex` badge alongside the existing `form` badge.

## [1.2.0] - 2026-04-20

### Fixed
- **About screen** — version number now correctly reflects the current release; app icon displayed at full resolution instead of the low-res menu bar icon.

### Improved
- **About screen** — added a Website link (`jeffcaldwellca.github.io/macspanso`) alongside the existing GitHub and espanso.org links.
- **Form match editor** — the template field now has a "Template" section label and an inline placeholder hint (`e.g. Hello [[name]], your email is [[email]]`) so it is clear where to type. A descriptive caption explains the `[[placeholder]]` syntax. When no placeholders have been added yet, a guidance message is shown where the field cards will appear.

## [1.1.0] - 2026-04-14

### Added
- **Launch at Login** — toggle macspanso to start automatically at login from the menu bar. The setting integrates with System Settings › General › Login Items.
- **Backup & Restore** — export all espanso matches to a `.macspanso` backup file and restore them on any machine. Import supports two modes: *Merge* (adds backup matches alongside existing ones) or *Replace* (replaces existing matches with the backup).
- **Clipboard shortcut** — quickly insert clipboard contents via an espanso match shortcut.

## [1.0.0] - 2026-03-01

Initial release.
