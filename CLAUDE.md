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
`SelectionIndex`, `PasteAction`) and is unit-tested.

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
two first-run flags under their original key strings. The Settings window is a
`TabView` in an `NSWindow` + `NSHostingView` (no SwiftUI `Settings` scene — the
app is AppKit-bootstrapped), opened from a "Settings…" status-menu item. The
global hotkey is the one setting wired through; `KeyboardShortcuts` owns its own
persistence, so it is not mirrored into `ClipdSettings`. Login-item state is owned
by one `ObservableObject` (`ClipdLoginItem`) shared by the Settings checkbox and
the status-menu item — a computed `Binding` over `SMAppService.status` never
redraws, and re-reading that status immediately after register/unregister can
still report the OLD value and snap the control back. Run-the-app verified
(2026-08-18): the Settings window opens from the status menu, rebinding the
hotkey works and survives a restart, Reset to Default restores ⌘⇧V, the status
menu's shortcut hint follows the new binding, and the login-item toggle agrees
across both surfaces.

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
survives a restart on purpose, since it has a Settings checkbox and is a setting.
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
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

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
  pinned state and liveness (`set_pinned`/`remove`/`clear_unpinned`); only
  `upsert` evicts (so replay reproduces eviction exactly).
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
  made while a known secret app is frontmost (`excludedSourceApps` in
  `PasteboardMonitor`: `com.apple.Passwords`, `com.apple.keychainaccess`) — a
  source-app heuristic with a ~0.5s poll race, **not** security. Don't overclaim
  it; the real fix is encryption-at-rest.
- **Files captured by reference, not value.** A file copy stores its path only;
  a moved/deleted file can't be pasted back. Document the caveat; don't
  silently switch to copying contents.
- **Capture priority is file → text → image.** A copied file is detected FIRST:
  a Finder ⌘C puts the file URL **and** the filename as plain text **and** the
  icon as a TIFF, so a text-first check would store a file as just its name (the
  original bug — `git`-blame the reorder). Text still beats image, so rich text
  with an inline image stays text (the more searchable representation). Document
  surprises rather than reordering silently.
- **Delete/clear are removal, not secure erase.** The entry leaves the live set
  at once, but its log records (and any image blob) persist in the plaintext
  store until the next compaction drops them — not cryptographic erasure. Don't
  overclaim it as secure deletion.
- **Pinned is exempt from the byte budget, not just the count cap.** Pinning many
  large images can push total on-disk usage past `max_bytes` (pinned entries are
  never evicted to reclaim space). State the trade-off; don't silently start
  evicting pins.
