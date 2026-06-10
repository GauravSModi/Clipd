# Handoff — pinned / delete / clear shipped

## Status

All four planned phases plus four post-v1 batches are done on `master`: a
small tweak (timestamps in the panel + click-away auto-dismiss), a four-feature
shell UX batch (direct paste-back, keyboard selection, content-type
affordances, launch-at-login), **image/file capture** (the first post-v1 work
to cross every layer), and **pinned/favorites + delete + clear history** (the
second cross-layer batch, built on image/file's identity + record-type
machinery). Clipd is a fast, local-first macOS clipboard manager: a C++ core
(store + fuzzy search + crash-safe log + content-addressed blob store) behind a
flat `extern "C"` API, driven by a thin Swift menu-bar shell. **See "Shipped —
pinned / delete / clear" below; no further batch is planned — remaining work is
run-the-app verification + the deferred Future-Work items.**

- Phase 1 — C++ core: `git show cb65551`.
- Phase 2 — hardening + C API: `git show f4a2bbd 18e6549`.
- Phase 3 — Swift menu-bar shell: `git show f9252f7 be1a4d8 4928ea5`.
- Phase 4 — polish: `git show ffeec6d 9e64eed`.
- Post-v1 — panel timestamps + auto-dismiss: `git show 7eedcc9`.
- Shell UX batch — Plan A (keyboard selection, affordances, launch-at-login)
  `git show b064fbb`; Plan B (direct paste-back) `git show 4c1d5ad`.
- Image/file capture — code: `git show a23ef25`; PRD amendment + README:
  `git show a2160ec`.
- Pinned / delete / clear — this batch (uncommitted working tree at handoff;
  split the code commit from the docs/PRD/README commit per the usual rule).

State: **147 GoogleTest cases** + **62 ClipdKit XCTest cases** green; C++ core
clean under ASan + UBSan; ClipdKit clean under ASan + TSan; the menu-bar app
builds. Plan A's GUI was confirmed working at runtime; **paste-back (Plan B),
the image/file UI/paste-back, and the new pin/delete/clear UI are not yet
runtime-verified — run the app with the Accessibility permission granted to
confirm them** (see the Shipped sections below).

Re-verify anytime (full commands in `CLAUDE.md` → Build & test):
```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
ctest --test-dir build --output-on-failure
swift test
```

## What exists

- **C++ core** behind `include/clipd.h`. Coordinator pattern: `ClipStore` +
  `FuzzyMatcher` + `Log` + `BlobStore`. Crash-safe append-only log v1 (CLPD
  header + per-record type tag) with CRC32 framing, torn-write truncation,
  compaction via atomic rename, replay recovery, and legacy v0 migration on
  first start. Compaction is fsync-durable (`F_FULLFSYNC` temp + directory
  `fsync` around the rename, via the shared `src/durable_file.{hpp,cpp}`);
  appends are deliberately not fsync'd (see *Durability* in the README).
  Per-entry identity is `sha256-hex(kind_byte ‖ defining content)` from
  `src/identity.{hpp,cpp}` (single source for ingest + replay); `src/sha256.{hpp,cpp}`
  is the hand-rolled streaming SHA-256 (KAT-tested) it's built on. Image bytes
  live in a content-addressed blob store at `<log>.blobs/<id>` (write-once
  dedup, hex-id validated to defeat path-traversal); the IMAGE log record
  carries only the id + metadata. `ClipStore` keys by `id` and evicts under
  both a count cap and a byte budget; an optional per-image cap skips oversize
  images at ingest. `Core::compact()` rewrites the log durably then GCs orphan
  blobs (post-rename ordering).
- **ClipdKit** (`shell/ClipdKit/`, a SwiftPM library — `Package.swift` at root):
  - `Clipboard` — the C-API bridge: one serial `DispatchQueue` for every call,
    copy-out-then-free for search results and `readBlob`, NULL-vs-`count==0`,
    stats/compact. `Match` carries `kind`/`id`/`byteSize`/`width`/`height`;
    `addImage(data, width, height, format, at:)` / `addFile(path, at:)` /
    `readBlob(id:)` mirror the new C calls. Init takes `maxBytes` and
    `maxBlobBytes` (default 0 = unbounded) for the byte budget + per-image cap.
  - `PasteboardMonitor` — changeCount polling + concealed/transient skip, now
    emitting a typed `Capture` (text / image / file) via `onCapture`. Priority
    is **file → text → image** (corrected 2026-06-06: a Finder file copy also
    carries the filename as text + the icon as a tiff, so file must be checked
    first; text still beats image so rich text with an inline image stays text);
    images come through `imageCapture()` (PNG/TIFF data + dims + format) and
    files through `fileURLPath()` on the `PasteboardReading` protocol;
    `SystemPasteboard` is the real adapter and also exposes `writeImage` /
    `writeFile` for paste-back. Concealed skip has two layers (2026-06-09):
    the `ConcealedType`/`TransientType` type filter, **plus** a source-app skip
    (`excludedSourceApps` + an injected `frontmostBundleID`) because Apple's
    Passwords app copies a bare plain-text string with no marker — best-effort,
    not security (a ~0.5s poll race; only the listed bundle ids).
  - `HistoryController` — ingest glue + in-session compaction past the threshold;
    `readBlob(id:)` passes blob fetches through to the UI.
  - `RelativeTime` — pure `clipdRelativeTime`/`clipdAbsoluteTime` formatters for
    the panel's timestamps (unit-tested; no core/store access). Good template for
    factoring testable logic out of the UI.
  - `ContentType`, `SelectionIndex`, `PasteAction` — pure shell helpers from the
    UX batch: the whole-string URL/email/hex classifier, keyboard-selection index
    math, and the paste-vs-copy fallback rule. All unit-tested (same `RelativeTime`
    template; no core/store access).
- **Menu-bar app** (`shell/Clipd/`, Xcode target from `project.yml`): status item
  (+ right-click Quit), unified SwiftUI search panel, `KeyboardShortcuts` hotkey
  (⌘⇧V default), `LSUIElement` agent. Each result row shows the snippet, a
  relative-time caption, and the exact copy time as a hover tooltip + VoiceOver
  label. The panel auto-dismisses when it loses key-window (`windowDidResignKey`
  → `orderOut` only; `NSApp.hide` paste-back hand-back stays on choose/toggle).
  The UX batch added ↑/↓ row selection (an `NSEvent` local monitor so the query
  field keeps typing focus), Enter to paste the selection back into the prior app
  (⌘↵ copies; ⌘1–9 grab the Nth recent), per-row affordances (open link /
  compose / color swatch), and a `Launch at Login` checkbox (`SMAppService`).
  The image/file batch added ImageIO-downsampled thumbnails for image rows (via
  `clipdThumbnail(...)` in `shell/Clipd/Thumbnail.swift`; the cache lives on
  `SearchModel`), system file icons for file rows, and kind-aware paste-back
  in `AppDelegate.activate(...)` that writes the original image bytes (PNG vs
  TIFF inferred from magic bytes via `clipdImageFormat(of:)`), a file URL, or
  text under the right pasteboard type. Log lives at
  `~/Library/Application Support/Clipd/clipd.log`; blobs live alongside at
  `clipd.log.blobs/`; defaults `max_entries=10000`, compact threshold 4 MB,
  `maxBytes=256 MB` (live byte budget), `maxBlobBytes=50 MB` (per-image cap),
  poll 0.5 s.
- **Benchmarks & demo:** `./build/clipd_bench` prints per-size latency + peak
  RSS. On an Apple M5: ~0.19 ms mean / ~3.2 MB at 10k, ~0.98 ms at 50k.
  `./scripts/torn_write_demo.sh` drives the recovery demo; the recorded GIF lives
  at `docs/torn_write_demo.gif`, regenerable with `vhs docs/torn_write_demo.tape`.

## Build/tooling notes

- Installed via Homebrew: `cmake`, `xcodegen`, `vhs` (for the demo GIF). Full
  **Xcode** is installed and selected. `/opt/homebrew/bin` may not be on the
  default PATH — prefix it (`export PATH="/opt/homebrew/bin:$PATH"`).
- Always benchmark a **Release** build; Debug is ~10× off.
- `swift test` links the CMake archives in `build/`, so **populate `build/`
  first** (`cmake --build build`). The app's xcodebuild has a pre-build phase
  that runs cmake automatically.
- `Clipd.xcodeproj` is **generated** (`xcodegen generate`) and **gitignored**;
  `project.yml` is the checked-in source of truth.
- `CMAKE_OSX_DEPLOYMENT_TARGET` is pinned to 13.0 (set before `project()`); keep
  it in sync with `Package.swift`'s `.macOS(.v13)` or the linker warns.
- Gitignored: `.claude/settings.local.json`, `build/`, `build-*/`, `.build/`,
  `Clipd.xcodeproj/`, and the root `compile_commands.json` symlink — keep them
  out of commits.
- The menu-bar app is an agent (no Dock icon); quit it via the status item's
  right-click → Quit, or `killall Clipd`.

## Shipped — shell-enhancement batch (4 features)

All shell-only (no C++ core / C API / header / log change), TDD'd where the logic
is pure, on `master` (Plan A `b064fbb`, Plan B `4c1d5ad`). The UX deviation from
the PRD (paste-back makes the default action *paste*, not copy; copy stays on ⌘↵)
is recorded as a post-v1 amendment in `prd_clipd.md`.

1. **Direct paste-back** (Plan B). On choosing an entry, reactivate the app that
   was frontmost when the panel opened and synthesize ⌘V, instead of only writing
   the pasteboard. Enter / plain click paste; ⌘↵ / ⌘-click copy-only. The ⌘V is
   gated on `NSWorkspace.didActivateApplicationNotification` (matching the
   target's pid) with a 0.15 s safety fallback — no fixed-delay race. Needs the
   **Accessibility (TCC) permission** (one-time first-run prompt via
   `AXIsProcessTrustedWithOptions`); degrades to copy-only when not granted
   (`ClipdKit/PasteAction` resolves this, tested). `AppDelegate` + `SearchModel`.
   **Not yet runtime-verified — run with Accessibility granted to confirm.**
2. **Keyboard selection** (Plan A). ↑/↓ move a highlighted row, Enter activates
   it, ⌘1–9 jump to the Nth recent. Arrows are driven by an `NSEvent` local
   monitor (a focused single-line `TextField` swallows `.onMoveCommand`); ⌘1–9 and
   ⌘↵ are hidden `keyboardShortcut` buttons. Index math is pure
   (`ClipdKit/SelectionIndex`, tested). `SearchModel` + `SearchView`.
3. **Content-type affordances** (Plan A). A whole-string URL / email / hex color
   gets an inline action (open link / compose / non-interactive swatch).
   Classifier is pure (`ClipdKit/ContentType`: `NSDataDetector` + a `#`-required
   hex regex, tested). UI in `SearchView`.
4. **Launch at login** (Plan A). `SMAppService.mainApp` status-menu checkbox
   (re-synced from the real status on menu open) + a first-launch prompt.
   `AppDelegate`. Verify by running; full effect needs a signed app in
   `/Applications`.

## Shipped — image/file capture (post-v1, cross-layer)

The first post-v1 batch to cross every layer — core, C API, log format, and
the shell — TDD'd at the layer the logic lives, with a PRD amendment lifting
the v1 non-goal. `git show a23ef25 a2160ec`. Invariants were **extended, not
bypassed**: every new record type has a recovery test, the C
allocates/C frees / single-arena model still holds, `ClipStore` stays the
authority and pure-in-memory, `FuzzyMatcher` stays pure.

- **Identity model.** `id = sha256-hex(kind_byte ‖ content)` (domain separation
  so a text and a file with byte-identical content never collide). Single
  source via `src/identity.{hpp,cpp}`; both ingest and replay derive ids
  through it. For images, the same digest is what the log record stores, so
  replay recovers the id by hex-encoding it — no re-hashing of the blob.
- **Log v1.** `"CLPD"` magic + `uint32` version header, per-record `[u8 type]
  [body]` payload (TEXT / IMAGE / FILE; PIN/UNPIN/TOMBSTONE/CLEAR reserved for
  feature 2). Sub-header-sized files are treated as fresh. Pre-feature
  header-less text-only logs are detected (first 4 bytes ≠ magic), replayed
  with the v0 decoder, and migrated to v1 by a compaction on first `start()`.
- **Blob store.** Content-addressed at `<log_path>.blobs/<id>`. Writes are
  temp → `F_FULLFSYNC` → atomic rename → fsync-dir via the lifted
  `src/durable_file.{hpp,cpp}`; existing ids are write-once skipped (free
  dedup). Hex-id validation prevents path traversal from a hostile read id.
- **Crash ordering.** Core writes the blob BEFORE the IMAGE record (a crash
  in between leaves an orphan blob, never a dangling reference). On replay, an
  IMAGE record whose blob is gone skips just that one entry (distinct from
  torn-tail truncation). `compact()` rewrites the log durably THEN GCs orphan
  blobs — a crash mid-GC leaves only re-collectable orphans.
- **Eviction.** `ClipStore` evicts least-recent until both `max_entries` AND
  `max_bytes` hold; the most-recent insert is never evicted away (a single
  over-budget entry stays). The optional per-image cap (`max_blob_bytes`) is
  enforced upstream at `add_image` and silently skips oversize images.
- **Search.** `FuzzyMatcher` stays pure — files match on filename + path,
  images on a synthesized label like `"image 1024x768 png"` generated by a
  single `image_label(w,h,fmt)` helper shared by `add_image` and replay.
- **C API.** `ClipdKind` / `ClipdImageFormat`, `ClipdMatch` gains
  `kind`/`id`/`byte_size`/`width`/`height` packed into the same single-arena
  alloc, extended `clipd_create(..., max_bytes, max_blob_bytes)`,
  `clipd_add_image` / `clipd_add_file`, and lazy `clipd_read_blob` /
  `clipd_free_blob` (its own single-malloc/single-free buffer) so the search
  arena stays small. `ClipdStats` gains `store_bytes` for byte-budget
  observability.
- **CLI.** `add-image`/`add-file`/`read-blob` verbs and `kind`/`id` columns in
  `list`/`search` so migration / blob-GC / round-trip can be scripted without
  the shell.
- **Shell.** `Clipboard.addImage`/`addFile`/`readBlob`; `PasteboardMonitor`
  emits typed `Capture` (file → text → image priority — corrected 2026-06-06,
  see the capture-priority note) via `onCapture`;
  `SystemPasteboard` reads PNG/TIFF + file URLs; `SystemClipboardWriter` writes
  the right pasteboard type back. UI: ImageIO-downsampled thumbnails (not
  `NSImage(data:)`), system file icons, kind-aware paste-back with PNG/TIFF
  inferred from magic bytes (no extra C API field). App caps `maxBytes = 256
  MB`, `maxBlobBytes = 50 MB`.

State: 117 GoogleTest + 54 ClipdKit XCTest green; C++ clean under ASan +
UBSan; ClipdKit clean under ASan + TSan; menu-bar app builds. **Run-the-app
verification still pending**: real pasteboard image/file reads (Preview ⌘C,
Finder ⌘C), concealed/transient skip for an image copy, thumbnails rendering
in the panel, and paste-back of an image (PNG → PNG, TIFF → TIFF) and a file
(file URL) into the prior app.

### TDD honesty note (for the next session)

`sha256`, `identity`, `ClipStore`, `BlobStore`, and `Core`'s new methods went
through clean **stub → RED → GREEN**. `Log` v1 and the C API extensions went
straight from test-to-impl because the format/header changes broke the
compile graph (no clean stub state). Both layers have strong concrete-assertion
regression tests (the 13 pre-existing log crash-safety tests now run on the v1
header format; the C API tests assert specific kind enum values, 64-char ids,
and binary round-trip with embedded NULs). Worth knowing when reading the
log/C-API tests.

## Shipped — pinned / delete / clear (post-v1, cross-layer)

The second post-v1 batch to cross every layer, built on image/file's identity +
record-type machinery. PRD amendment dated 2026-06-06. Invariants **extended,
not bypassed**: every new record type has round-trip + torn-tail recovery tests,
the C allocates / C frees / single-arena model still holds, `ClipStore` stays
the liveness authority and pure-in-memory, `FuzzyMatcher` stays pure.

Decisions taken (with the user): pinned surfaces as a **separate "Pinned"
section**; clear is **clear-unpinned** (pins survive); deleting a pinned row is
**allowed but confirmed**; **clear confirms, unpinned delete is instant**;
deleted image blobs are reclaimed at the **next compaction** (deferred GC, no
targeted delete); tombstones are **not** carried into the compacted log;
`clipd_set_pinned` is **idempotent set-to-bool**.

- **Control records.** The four reserved log tags are implemented as control
  records (state change keyed on an `id`, no content/timestamp): `PIN`=3,
  `UNPIN`=4, `TOMBSTONE`=5, `CLEAR`=6. `Log::append_control` + a second
  `replay` callback (`on_control`); content and control records replay in
  strict file order. Round-trip, torn-tail, and replay-order tests in
  `tests/test_log.cpp`.
- **Pinned.** `Entry.pinned`; `ClipStore` evicts the least-recent **unpinned**
  entry (never the most-recent insert), exempting pins from both the count cap
  and the byte budget; `set_pinned`/`pinned_state`; eviction is upsert-only so
  replay is faithful. `Core::search` sorts **pinned-first** (the comparator, not
  `FuzzyMatcher`) so an old pin still surfaces past `max_results`.
- **Delete.** `ClipStore::remove` + `Core::remove` writes a TOMBSTONE; replay
  drops the entry; compaction discards both the tombstone and the dead record. A
  deleted image's blob is reclaimed by the next compaction's existing GC (test:
  `CoreTest.DeletedImageBlobReclaimedAtNextCompaction`).
- **Clear.** `Core::clear` = clear-unpinned: a CLEAR record (durable for the
  crash window) → `ClipStore::clear_unpinned` → compact to a pinned-only log +
  blob GC. Pinned state survives compaction because `Log::compact` re-emits a
  PIN record after each pinned entry's content record (content schema unchanged).
- **C API.** `clipd_set_pinned` / `clipd_delete` / `clipd_clear`;
  `ClipdMatch.pinned` packed into the same single-arena block. Tests in
  `tests/test_c_api.cpp` (NULL-safety, the pinned field round-trips, one free).
- **CLI.** `pin` / `unpin` / `delete` / `clear` verbs and a pinned column in
  `list`/`search` (columns: ts, kind, pinned, id, score, text).
- **Shell.** `Clipboard.setPinned`/`delete`/`clear` + `Match.pinned`;
  `HistoryController` passthroughs; pure `clipdPinnedPrefixCount`
  (`shell/ClipdKit/PinnedSplit.swift`, tested). UI: per-row star + trash, a
  "Pinned"/"Recent" section split, and a status-menu "Clear History…". Clear is
  confirmed; per-row delete is instant for unpinned and confirmed for pinned
  (`SearchModel.onConfirmDelete` → `AppDelegate` NSAlert).

State: 147 GoogleTest + 62 ClipdKit XCTest green; C++ clean under ASan + UBSan;
ClipdKit clean under ASan + TSan; menu-bar app builds. **Run-the-app
verification still pending**: the star toggle moving a row into the Pinned
section, per-row delete (instant unpinned / confirmed pinned), the status-menu
"Clear History…" confirmation keeping pins, and **pin + delete persisting across
an app restart**.

## Future work (deferred — see `prd_clipd.md` → Future work)

- **Indexed search for scale:** trie / n-gram index to take search sublinear,
  with a synthetic 1M-entry benchmark. Today's linear scan is imperceptible to
  ~50k and degrades around ~1M.
- **Encryption-at-rest:** the log is plaintext today; concealed/transient skip is
  the floor, not security. This is the real fix.
- **FuzzyMatcher scoring floor:** subsequence matching returns all in-order hits
  with no score floor (a `FuzzyMatcher`/core change with its own tests; correct
  by design per the PRD — confirm before touching the core).
- **Concurrent compaction** and the technical blog post. (Image/file capture
  and pinned/delete/clear have both shipped — see the Shipped sections above.)

## Invariants to hold (from CLAUDE.md — non-negotiable)

- Core is a coordinator (durability lives in `Log` + `BlobStore`); `FuzzyMatcher`
  is pure; `ClipStore` stays behind its narrow interface and pure-in-memory
  (blob GC is Core's at compaction). Identity is content-derived
  (`sha256-hex(kind_byte ‖ content)`) and single-sourced via
  `src/identity.{hpp,cpp}` — never compute or store ad-hoc.
- Recovery, eviction, and blob contracts hold: chronological replay; eviction
  respects both `max_entries` and `max_bytes` (most-recent never evicted);
  blob-first ordering before each IMAGE record; missing blob on replay skips
  one entry (not a torn-tail wipe); orphan blobs GC'd only AFTER the compacted
  log is durably renamed.
- Swift shell stays thin (UI + polling + hotkey + the one serial queue +
  presentation-side UX only). The C-allocates / C-frees / single-arena memory
  model extends to `clipd_read_blob` / `clipd_free_blob`.
- TDD: failing test first, watch it fail, then pass. Done = tests green AND
  both sanitizers clean. **Don't commit unless asked.** Wanting to change the
  core is a signal to revisit the plan, not to reach across the C API.
