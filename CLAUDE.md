# CLAUDE.md

## Project

Clipd — fast, local-first clipboard history for macOS. C++ core does the real
engineering (store, fuzzy search, crash-safe storage); a thin Swift menu-bar
shell comes later.

4-phase project, each phase gets its own approved plan cycle:
1. **C++ core** (standalone, CLI-driven) — **DONE**
2. C API boundary (`extern "C"` lib + flat header) — **DONE**
3. Swift shell (menu bar, pasteboard polling, hotkey) — **DONE**
4. Polish (eviction, persistence hardening, README/benchmarks) — **DONE**

**Project complete** — all four phases are done: fsync-durable compaction,
eviction (FR6) and crash/recovery characterization tests, and a portfolio
README with real benchmarks plus a recorded recovery demo (`docs/`).

**Post-v1 shell-enhancement batch** — also shipped (all shell-only, no
core/C-API/header/log change): direct paste-back (Enter pastes into the prior
app, ⌘↵ copies; needs the Accessibility permission), keyboard selection (↑/↓ +
Enter + ⌘1–9), content-type affordances (URL/email/hex color), and
launch-at-login. Pure logic lives in `ClipdKit` helpers (`ContentType`,
`SelectionIndex`, `PasteAction`) and is unit-tested. Since 2026-09-25 the panel
opens with the **newest copy** highlighted (`clipdDefaultSelection`, by
timestamp), because pinned-first ordering can put it below older starred rows. A
starred row wins only when it is itself the newest — re-copying an entry, or
pasting it from Clipd (the monitor re-captures Clipd's own pasteboard write),
bumps its timestamp. A new query starts on its top match; pin/delete/clear keep
the highlight where it was. ⌘1–9 still count from the top row, by choice.

**Post-v1 image / file capture** — shipped after the shell batch
(`git show a23ef25 a2160ec`). First post-v1 batch that crosses every layer:
images stored as bytes in a content-addressed blob store at `<log>.blobs/<id>`,
files captured by reference (path), log format upgraded (`"CLPD"`+version
header, per-record type tag), legacy v0 logs migrated on first start. Per-entry
identity is `sha256-hex(kind_byte ‖ content)` from `src/identity.{hpp,cpp}`
(single source, no drift between add and replay). Eviction adds a total-byte
budget and an optional per-image cap alongside the count cap. The PRD
non-goal "image/file clipboard support" is lifted via a dated amendment in
`prd_clipd.md`. Run-the-app verification of real pasteboard image/file reads,
thumbnails, and paste-back is still pending.

**Post-v1 pinned / delete / clear** — shipped on top of the identity model
(dated amendment in `prd_clipd.md`, 2026-06-06). Crosses every layer again. The
four reserved log tags are now implemented as control records (state changes
keyed on an `id`, no content): `PIN`=3, `UNPIN`=4, `TOMBSTONE`=5, `CLEAR`=6.
`Entry.pinned`; pinned entries are exempt from eviction (evict least-recent
*unpinned*) and from clear (clear-unpinned), and sort first in `Core::search` so
old pins still surface. Compaction re-emits a PIN record per pinned entry (the
content-record schema is unchanged); a deleted image's blob is reclaimed by the
next compaction's existing GC (not eagerly). C API gains `clipd_set_pinned`
(idempotent set-to-bool) / `clipd_delete` / `clipd_clear` and `ClipdMatch.pinned`.
Shell: per-row star + trash, status-menu "Clear History…"; clear is confirmed,
per-row delete is instant for unpinned and confirmed for pinned. Run-the-app
verification of the star/trash/clear UI and pin/delete persistence across
restart is still pending.

**Post-v1 settings + filters batch** — an approved 8-stage schedule (settings
window, capture gates, editable excluded apps, history caps, retention, type
filters, source-app capture, source-app filter), one stage per agent. The PRD
non-goal "Settings UI beyond the essentials" is *scoped*, not lifted, by a dated
amendment (2026-08-18) that enumerates exactly which settings are in scope.
**Stage 1 (settings foundation) is shipped** and shell-only: `ClipdSettings` in
ClipdKit is the single settings store (typed accessors over `UserDefaults` with
explicit defaults, `ObservableObject` change signal, injectable suite for tests);
it owns the cap defaults that used to be `private let` on `AppDelegate`, plus the
two first-run flags under their original key strings. The Settings window is an
`NSTabViewController` with `tabStyle = .toolbar` (`shell/Clipd/SettingsWindow.swift`),
one `NSHostingController` per pane, opened from a "Settings…" status-menu item —
not a SwiftUI `TabView`, which draws toolbar tabs only inside a SwiftUI `Settings`
scene (the app is AppKit-bootstrapped) and an in-window segmented box anywhere
else. The global hotkey is the one setting wired through; `KeyboardShortcuts`
owns its own persistence, so it is not mirrored into `ClipdSettings`. Login-item
state is owned by one `ObservableObject` (`ClipdLoginItem`) shared by the
Settings switch and the status-menu item — a computed `Binding` over
`SMAppService.status` never redraws, and re-reading that status immediately
after register/unregister can still report the OLD value and snap the control
back. Run-the-app verified
(2026-08-18): the Settings window opens from the status menu, rebinding the
hotkey works and survives a restart, Reset to Default restores ⌘⇧V, the status
menu's shortcut hint follows the new binding, and the login-item toggle agrees
across both surfaces. **Redesigned 2026-09-29** (Mac-standard): every pane is a
grouped `Form` (System Settings rows, switches, cards), and the window resizes to
the selected pane and follows one whose content grows (a new excluded-app row,
the entries subtitle) with no extra hook. The panes carry **no explanatory text**
except the excluded-apps warning (`ClipdSettingsCopy.excludedAppsFooter`, pinned
by `SettingsCopyTests`) — no captions, subtitles or ⓘ tooltips, by choice; the
caveats for the caps, retention and clear-on-quit live only in the confirmation
alerts those settings raise. A shortcut cleared with the recorder's ✕ and never
replaced is put back when the recording ends (Reset still restores ⌘⇧V); the
library has no public hook for that, so `GeneralSettingsView` observes its
internal `KeyboardShortcuts_recorderActiveStatusDidChange` notification by string.
**Watch:** size a pane from `fittingSize` measured once the window is on screen
(`viewDidAppear`, tab switch), never from `preferredContentSize` — a hosting
controller inside a tab controller never publishes one. **Watch:** the ✕
refocuses the recorder, which posts "stopped" then "started" back to back, so the
restore waits one run-loop turn; restoring on that first "stopped" re-registered
the hotkey mid-recording, where it swallowed its own keystroke. Run-the-app
verified (2026-09-29): every tab in dark and light, pause and login agreement with
the status menu, excluded apps growing and shrinking the window, and hotkey
rebind, Reset and clear-restore.

**Stage 2 (capture gates) is shipped**, shell-only: a new pure `CapturePolicy`
value in ClipdKit (pause flag + per-kind allow flags) plus `clipdSelectCapture`,
the pure decision function `PasteboardMonitor.poll()` now calls instead of its old
inline priority chain. The pause gate sits *after* `lastChangeCount` advances, so a
copy made while paused is dropped for good, never replayed on resume. A
disallowed kind **skips the copy entirely** — no fall-through to the next
representation (unchecking "files" means a Finder ⌘C records nothing, not its
filename). `PasteboardMonitor` reads the policy through an injected
`() -> CapturePolicy` provider, re-evaluated every poll, so a settings change
takes effect without rebuilding the monitor. Pause is persisted in `ClipdSettings`
(`captureIsPaused` + `capturesText`/`capturesImages`/`capturesFiles`) — it
survives a restart on purpose, since it has a Settings switch and is a setting.
Surfaced from both a "Pause Capture" status-menu item (checkmark) and a new
**Capture** tab in Settings; both read/write the same `ClipdSettings` property, so
they can't disagree. The status-item icon swaps `doc.on.clipboard` → `pause.circle`
(shown at `.large` symbol scale — the default `.small` menu-bar scale reads
noticeably smaller than the doc icon) while paused; there is no slashed-clipboard
SF Symbol. **Watch:** `@Published`'s projected publisher fires from `willSet`, so a
Combine sink that discards its emitted value and re-reads the `ClipdSettings`
property can observe the pre-change value on the very next run-loop turn (this bit
the first cut of the icon swap — fixed by consuming the sink's own parameter).
Run-the-app verified: pause/resume from the status menu, images/files toggles in
Settings, and the icon/menu-checkmark agreement (after the fix above) all work.

**Stage 3 (editable excluded source apps) is shipped**, shell-only: the
`private static let excludedSourceApps` set is gone from `PasteboardMonitor`;
the monitor now takes an injected `() -> Set<String>` provider (same shape as
Stage 2's `CapturePolicy` provider, re-read every poll, so a Settings edit
applies on the next tick with no restart). Its default is **permissive (`[]`)** —
the pure layer carries no baked-in list, and `ClipdSettings.defaultExcludedSourceApps`
is now the single source of the two Apple ids (a test pins them so the fallback
can't be dropped silently). The list persists as an `[String]` under
`clipd.excludedSourceApps` (UserDefaults has no `Set`; the Array also gives the UI
a stable row order) and `excludedSourceAppIDs` is what the provider hands back.
An **absent key** seeds the two Apple defaults; a **stored empty array is honored
and never re-seeded**, so removing every app is a real, persisted choice. Add/remove
live on `ClipdSettings` (`addExcludedApp` trims, de-dupes exactly, and never
reorders; matching stays exact, as the monitor's `Set.contains` always was), so the
view holds no list logic. UI is an `NSOpenPanel` app picker + `−` button in the
Capture tab (`shell/Clipd/ExcludedAppsView.swift`); display names resolve via
`NSWorkspace` with a raw-bundle-id fallback, and that file lives in the **Clipd
target, not ClipdKit**, because NSWorkspace/NSOpenPanel are AppKit. The tab carries
the honest framing in its one footer (best-effort frontmost check with a timing
window, **not** security, and a warning that removing the Apple rows can leave
passwords in the plaintext history). Run-the-app verified (2026-08-20):
add/remove changes capture without a restart, the list survives quit/relaunch,
and both tabs lay out cleanly.
**Watch:** the Stage 2 per-kind filters persist like pause does, so a filter left
off during testing reads later as "the app captures nothing" — check
`defaults read com.clipd.Clipd` (`clipd.capturesText` etc.) before debugging capture.

**Stage 4 (history caps) is shipped** — the first stage of the batch to open
C++, so it crosses `src/` → `include/` → `shell/`. `ClipStore::set_limits` is a
**second eviction trigger** (see the amended invariant below): it replaces both
caps and evicts down immediately, because a cap the user just lowered that only
takes effect on the next copy is a bug, not a policy. Eviction itself is not
reimplemented anywhere — `set_limits` assigns the two members and calls the
existing `evict()`, so the pinned exemption, the never-evict-the-most-recent
guard, and the nothing-evictable termination case all come along unchanged (a
cap can still be held **above** its limit by pins). New `clipd_set_limits`
carries exactly the two caps `ClipStore` owns; `max_blob_bytes` deliberately
stays a `clipd_create` parameter, since it is an **ingest-side** reject rule and
lowering it could not retroactively remove a stored image. The setter does
**not** rewrite the log: evicted records drop at the next compaction on the
existing threshold, which keeps the documented "raising the cap can recover
evicted entries from the log *only before* the next compaction" grace intact.
Shell: a new **History** tab (caps are about how much is kept; Capture is about
what gets recorded), with bounded controls only — 100–100,000 entries via a
text field (its stepper was dropped 2026-09-29), a preset picker for the budget,
and no "unlimited" option, so the UI can't produce a value
`ClipdSettings.positiveInt` treats as corrupt (the 0-means-unbounded C contract
is unchanged for API callers). A reduction is confirmed **only when it would
actually evict**; the count it names is an
**upper bound** ("up to N"), because pinned entries are exempt and `ClipdStats`
carries no pinned count, and a byte reduction names sizes rather than a count.
The alert copy promises neither permanence nor recoverability — a
`HistoryLimitsTests` case pins that wording. **Watch:** `AppDelegate`'s two
`@Published` sinks each consume their **own** emitted value and read the *other*
cap off `settings` (the willSet trap again), and both use `.dropFirst()` so
launch doesn't re-apply the values `clipd_create` was just handed. Run-the-app
verified (2026-09-23, on a backed-up copy of real history): a reduction confirms
with the right upper bound and evicts exactly (lowering to 200 and then to 100
showed "Up to 100"), Cancel applies nothing, and raising applies silently. The
storage budget, pushed over with three ~27 MB test images, confirmed at 79 MB →
64 MB and evicted least-recent-unpinned first while keeping the pin, so the
`$maxBytes` sink applies the new value. That run also found four bugs in the
entries field, **fixed and run-the-app verified 2026-09-25**: (1) a click on blank
space never committed — on macOS a click on non-focusable content doesn't move
first responder — so the History tab now fills itself with a tap shape that drops
the field's focus and fires the focus-loss commit; (2) ⌘A/⌘C/⌘V/⌘X did nothing,
here and in the panel's search box, because they are Edit-menu key equivalents
and the app had no main menu — `ClipdMainMenu` (installed in `main.swift`) is a
never-shown Edit menu that exists only to route them, so the hotkey recorder now
refuses those shortcuts as the global hotkey; (3) letters were accepted —
`ClipdHistoryLimits.digitsOnly` now filters every edit, typed or pasted; (4) an
out-of-range count was clamped to 100,000 and saved silently (the caret landed
after "10000", so typing "200" made "10000200") — `ClipdEntriesEdit` now refuses
it with a beep and a snap-back, **never a clamp**, and its caption — the row's
gray subtitle, shown **only** while the box holds a count that isn't in force —
says how to apply it or what the box accepts. **Watch:** SwiftUI runs `.onChange`
inside a Core Animation transaction commit, where AppKit *suppresses*
`NSAlert.runModal()` (logging "Suppressing invocation of -[NSAlert runModal]")
and the suppressed alert reads as Cancel. The focus-loss commit therefore hops to
the next run-loop turn (`DispatchQueue.main.async`) before it can confirm; any
confirmation raised from an `onChange` needs the same hop, while Binding setters
and `.onSubmit` run outside the commit and don't. While a typed count is pending,
changing Storage budget, retention or clear-on-quit **settles the count first**
(`commitPendingEntries()`: its confirmation or its beep), then asks about its own
change; a cancel on the first doesn't block the second. Those are AppKit controls
that never take focus, so without this the count waited behind their
confirmation. **Watch:** a grouped `Form` draws a `TextField` as plain text, with
the arrow pointer until the first click — use `.textFieldStyle(.roundedBorder)`
plus `textPointer()` (`.pointerStyle(.horizontalText)`, macOS 15+); the box alone
doesn't bring the I-beam.

**Stage 5 (retention: age expiry + clear-on-quit) is shipped** — the second
stage to open C++, riding the **existing** TOMBSTONE control record rather than
touching the log format (that's Stage 7's job). `Core::delete_older_than`
coordinates over existing primitives — `store_.snapshot()` to find victims,
then per victim `log_.append_control(Tombstone, id)` *before* `store_.remove(id)`
(matching `Core::remove`'s ordering, so a crash mid-sweep is always consistent)
— and compacts **only when it removed something**. That compact-on-removal is a
deliberate departure from Stage 4's `set_limits` precedent: the 4 MB compaction
threshold can go months without tripping for a low-volume user, and a retention
feature that never actually removes plaintext from disk would be underdelivering
on the thing it's for. **`ClipStore` gains nothing** — no timestamp-aware bulk
op — so `upsert` and `set_limits` remain its only two eviction triggers; expiry
is a removal path, not a third one. **Pinned entries are exempt**, the same
exemption `clear()` and eviction use, so a retention period is *not* a blanket
guarantee that nothing older survives — the confirmation the period raises says so.
New `clipd_delete_older_than(core, cutoff_ms, size_t* out_removed)` mirrors
`clipd_set_limits`'s conventions (NULL handle safe, out-param optional). Shell:
a new `ClipdRetention` pure helper (day options **with an explicit `Never` row**
— unlike Stage 4's caps, "never expire" is the current behavior and a normal
default, not an absurd value) drives a History-tab picker that sweeps at launch
and hourly; a **shortening** of the period confirms (naming no count — a dry-run
pass would be needed to know one), lengthening or picking Never applies
silently. Clear-on-quit is a separate switch wired to `applicationWillTerminate`
→ the existing `clipd_clear` (so it's clear-**unpinned**, best-effort — a force
quit or abrupt logout never runs it, and it can make quitting visibly slow
because `clear()` compacts); it confirms only on **enabling**, never at quit
time. Both alerts' wording is pinned by `RetentionTests` to promise **neither
permanence nor recoverability** and to name the pinned exemption. The
clear-on-quit alert was cut to two short sentences on 2026-09-29, by request: it
names the pinned exemption but **no longer mentions best-effort or slow quits**,
so the best-effort caveat is no longer shown anywhere in the UI (it lives here
and in code comments); `RetentionTests` pins the exemption plus a 90-character
cap on its body. Run-the-app verified (2026-09-23, same run): shortening
Never → 30 days confirmed, Cancel snapped the picker back, and confirming
removed exactly the unpinned entries past the cutoff (1,697 of 2,049, reconciled
by entry id) and compacted (log 3.0 MB → 480 KB, orphan blobs GC'd); lengthening
applied silently. Clear-on-quit
confirms only on enabling (Cancel leaves it off), and a normal quit left only
the pinned entry, with every blob reclaimed. The stored period and checkbox
survived that restart in `UserDefaults`; the tab's display of them after the
restart, and switching both back off, were not exercised.

`prd_clipd.md` is the **authoritative spec**. Consult it before planning any
phase or making an architectural decision. If a request conflicts with it,
**flag the conflict** — don't silently follow either one.

## Build & test

```sh
# Configure + build + test (Release)
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure

# Sanitizers — both must be clean
cmake -B build-asan -DCMAKE_BUILD_TYPE=Debug -DCLIPD_SANITIZE=address
cmake --build build-asan && ctest --test-dir build-asan --output-on-failure
cmake -B build-ubsan -DCMAKE_BUILD_TYPE=Debug -DCLIPD_SANITIZE=undefined
cmake --build build-ubsan && ctest --test-dir build-ubsan --output-on-failure

# Benchmark (use a Release build) and recovery demo
./build/clipd_bench
./scripts/torn_write_demo.sh ./build/clipd-cli
```

### Swift shell (Phase 3)

Needs `brew install cmake xcodegen` and full Xcode. `ClipdKit` (the testable,
UI-free layer) is a SwiftPM library that links the CMake archives in `build/`;
the menu-bar app is an Xcode target generated from `project.yml`.

```sh
# ClipdKit unit tests — no Xcode needed. Populate build/ first (it links
# libclipd_capi.a + libclipd_core.a), then:
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
swift test                       # also: --sanitize=address | --sanitize=thread

# Menu-bar app: regenerate the Xcode project, then build (its pre-build phase
# runs cmake). Clipd.xcodeproj is generated/gitignored; project.yml is source.
xcodegen generate
xcodebuild -project Clipd.xcodeproj -scheme Clipd -configuration Debug \
  -destination 'platform=macOS' build

# App icon: drawn by a script, not a design file. `preview` writes every style
# to build/icon-previews/compare.png; `install` rewrites the committed
# shell/Clipd/Assets.xcassets (installed style: blue). After installing: rebuild,
# touch the built .app, relaunch. macOS caches app icons keyed on the .app
# folder's date, which in-place rebuilds never change — skip the touch and the
# running app (its NSAlerts) keeps the old icon even though Finder may not.
swift scripts/make_app_icon.swift preview
swift scripts/make_app_icon.swift install blue
touch "$(xcodebuild -project Clipd.xcodeproj -scheme Clipd -configuration Debug \
  -showBuildSettings 2>/dev/null | awk '/ CODESIGNING_FOLDER_PATH =/{print $3}')"
```

**Do NOT add `CODE_SIGNING_ALLOWED=NO`.** It produces an ad-hoc/linker-signed
binary whose CDHash changes on every rebuild, which silently invalidates the
Accessibility (TCC) grant that paste-back depends on — while the "Clipd" row
still *looks* checked in System Settings. Symptom: the panel dismisses and
nothing pastes (the entry only reaches the clipboard). `project.yml` pins a
stable Development identity so the grant survives rebuilds.

## Invariants (must survive every change)

- **Core is a coordinator** — no dedup, scoring, or durability policy of its
  own; it only wires ClipStore + FuzzyMatcher + Log + BlobStore together. It
  does own identity derivation, the blob-vs-record crash ordering (below), and
  **pinned-first search ordering** (the comparator, not FuzzyMatcher).
- **FuzzyMatcher is pure** — recency is passed in as a parameter; it never
  reaches into the store or any global state. Non-text entries feed it a
  synthesized label, not a separate code path. (Pinned-first ordering lives in
  `Core::search`, never here — the matcher only produces the relevance score.)
- **ClipStore stays behind its narrow interface** and **pure in-memory** — the
  backing (list + id-keyed map) is swappable; evicting an image entry does NOT
  touch blobs (blob GC is Core's job at compaction). It is the sole authority on
  pinned state and liveness (`set_pinned`/`remove`/`clear_unpinned`). **Two
  triggers evict, and only two**: `upsert`, and `set_limits` (which applies a
  lowered cap at once rather than waiting for the next copy). Replay still
  reproduces eviction exactly because replay never calls `set_limits` — recovery
  constructs the store with the already-current caps and drives every record
  through `upsert`.
- **Identity is content-derived, single-sourced** — `id = sha256-hex(kind_byte ‖
  defining content)` via `src/identity.{hpp,cpp}`. Both ingest and replay go
  through that helper (and the image-label helper in `core.cpp`) so the scheme
  can never drift between write and read paths.
- **Recovery, eviction, and blob contracts hold**:
  - Replay re-derives the live set in chronological order (never resurrects an
    evicted/deleted/cleared entry); raising the cap can recover evicted entries
    from the log *only before* the next compaction. Content **and** control
    records (pin/unpin/tombstone/clear) are applied in strict file order — never
    batched — so a PIN takes effect before the later adds that would otherwise
    evict the pinned entry.
  - Eviction respects BOTH the count cap and the byte budget; the most-recent
    insert is never evicted away even when oversize (per-image cap is upstream).
    **Pinned entries are exempt** — the victim is the least-recent *unpinned*
    entry; if none is evictable (all pinned / only the most-recent), the cap may
    be held above its limit (documented, intentional).
  - **Control records** (`PIN`/`UNPIN`/`TOMBSTONE`/`CLEAR`, log tags 3-6) are
    state changes keyed on an `id`, no content/timestamp. PIN/UNPIN are
    last-write-wins. `clear()` = clear-unpinned: a CLEAR record (durable for the
    crash window) then a compaction to a pinned-only log. Tombstones are NOT
    carried into the compacted log (the live set already excludes them); pinned
    state survives compaction via a PIN record re-emitted after each pinned
    entry's content record.
  - **Blob-first ordering**: the blob is written (temp → `F_FULLFSYNC` → atomic
    rename → fsync dir) BEFORE the referencing log record. A missing blob on
    replay skips just that one entry (not a torn-tail wipe). Orphan blobs are
    GC'd ONLY after a compacted log is durably renamed — including a **deleted
    image's blob**, reclaimed at the next compaction, never eagerly on `remove`.
  - Log v1: existing legacy (header-less) text-only logs replay as TEXT and are
    migrated to v1 on first `start()`.
- **Swift shell stays thin** — UI, pasteboard polling, hotkey, one serial
  `DispatchQueue`, UI-preference persistence (`ClipdSettings` over `UserDefaults`
  — never history data), and presentation-side UX (paste-back, keyboard nav,
  affordances, launch-at-login, thumbnails, the pinned-section split + pin/
  delete/clear controls + their confirmations) only; no dedup/scoring/storage.
  Every C call is serialized on that queue, and search results are copied into
  Swift values then handed back to `clipd_free_results` (no C++ pointer outlives
  the call). The same rule applies to `clipd_read_blob` / `clipd_free_blob`.

## Workflow

- **TDD**: write the failing test first, watch it fail, then make it pass.
- A change is **done** only when tests are green AND both sanitizers are clean.
- **Don't commit unless I say so.**
- **Don't start the next phase without an approved plan.**

## Known limitations — keep framed honestly, don't quietly "fix" or overclaim

- **ASCII-only matching.** Multibyte UTF-8 is matched byte-wise and never split;
  accent-insensitive / CJK / emoji handling is **Future Work**.
- **Local plaintext storage.** Concealed/transient exclusion (Phase 3) is the
  floor, not security; encryption-at-rest is **Future Work**. The store is not
  secure today — say so. This now includes **plaintext image blobs** in
  `<log>.blobs/` (worse for sensitive images than short text).
- **Concealed-skip only catches apps that tag copies.** `ConcealedType`/
  `TransientType` is the third-party nspasteboard convention (1Password, Chrome,
  Bitwarden honor it). **Apple's Passwords app / Keychain do NOT tag** — a copied
  password is a bare `public.utf8-plain-text` string. The fallback skips copies
  made while a known secret app is frontmost — a **user-editable** list, seeded
  with `com.apple.Passwords` + `com.apple.keychainaccess` from
  `ClipdSettings.defaultExcludedSourceApps` and injected into `PasteboardMonitor`.
  It stays a source-app heuristic with a ~0.5s poll race, **not** security, and the
  user can now remove the seeded apps entirely. Don't overclaim it; the real fix is
  encryption-at-rest.
- **Files captured by reference, not value.** A file copy stores its path only;
  a moved/deleted file can't be pasted back. Document the caveat; don't
  silently switch to copying contents.
- **Capture priority is file → text → image.** A copied file is detected FIRST:
  a Finder ⌘C puts the file URL **and** the filename as plain text **and** the
  icon as a TIFF, so a text-first check would store a file as just its name (the
  original bug — `git`-blame the reorder). Text still beats image, so rich text
  with an inline image stays text (the more searchable representation). Document
  surprises rather than reordering silently.
- **Delete/clear/expiry are removal, not secure erase.** The entry leaves the
  live set at once, but its log records (and any image blob) persist in the
  plaintext store until the next compaction drops them — not cryptographic
  erasure. Age expiry's sweep compacts whenever it removes anything (unlike
  `set_limits`), so expired records leave the log promptly, but the freed disk
  blocks are never overwritten. Don't overclaim any of this as secure deletion.
- **Pinned is exempt from the byte budget, not just the count cap.** Pinning many
  large images can push total on-disk usage past `max_bytes` (pinned entries are
  never evicted to reclaim space). The budget's confirmation states it ("Pinned
  entries are kept"); the Settings pane carries no caption. Don't silently start
  evicting pins.
- **Pinned entries never expire.** Age-based retention only sweeps unpinned
  entries, so "delete after N days" is not a guarantee that nothing older
  survives — a pinned entry from years ago is kept forever. The retention
  confirmation states this; the Settings pane carries no caption. Don't imply
  it's a blanket cutoff.
