# Clipd

Fast, local-first clipboard history for macOS. The engineering centerpiece is a
C++ core: an in-memory store with fuzzy search and a **crash-safe append-only
storage engine**, exposed over a flat `extern "C"` API and driven by a thin
Swift menu-bar shell. **All four phases are complete** — the standalone C++ core
(also driven by a scriptable CLI harness), the C API boundary, the macOS
menu-bar app, and polish (eviction, fsync-durable compaction, a recovery demo) —
with tests, sanitizers, and benchmarks. Post-v1 batches are also shipped: a
shell-enhancement batch (direct paste-back, keyboard selection, content-type
affordances, launch-at-login), **image/file capture** (content-addressed blob
store, type-tagged log), and **pinned-favorites + delete + clear-history**
(new crash-safe control records keyed on a content-derived id).

## Architecture

The core is split into small, independently testable units, behind a flat C API
that the Swift shell links against:

| Unit | Responsibility |
|------|----------------|
| `Crc32` | IEEE CRC32 checksum (table-based). |
| `ClipStore` | In-memory entries: dedup, recency ordering, bounded-size LRU eviction (pinned entries are exempt — the least-recent *unpinned* entry is evicted). Sole authority on what is *live*. |
| `FuzzyMatcher` | Pure subsequence match + quality scoring (contiguity, word/camelCase boundary, position, recency). |
| `BlobStore` | Content-addressed image-byte store (`<log>.blobs/<id>`): write-once, atomic rename + fsync, GC at compaction. |
| `Log` | Crash-safe append-only log: `"CLPD"`+version header, type-tagged length+CRC32 records (text/image/file + pin/unpin/tombstone/clear), torn-write truncation, compaction via atomic rename, replay. |
| `Core` | Coordinator — wires the store, log, blob store, and matcher together; owns identity derivation and pinned-first search ordering. No other policy of its own. |
| `clipd.h` (C API) | Flat `extern "C"` boundary (`clipd_create`/`add`/`add_image`/`add_file`/`search`/`read_blob`/`set_pinned`/`delete`/`clear`/`compact`/`stats`/`free_results`); the only surface the shell sees. |
| `clipd-cli` | Scriptable front-end (`add`/`add-image`/`add-file`/`search`/`list`/`pin`/`unpin`/`delete`/`clear`/`compact`/`stats`/`replay`). |

## Swift menu-bar shell

A deliberately thin macOS shell over the C API (no dedup, scoring, or storage
policy of its own — that all lives in the core):

- **Menu-bar status item** (agent app, no Dock icon; right-click → Quit, with a
  **Launch at Login** toggle).
- **Unified search panel** — type to fuzzy-search history; **↑/↓** move the
  selection and **Enter pastes it back into the app you were just in** (**⌘↵**
  copies only); **⌘1–9** grab the Nth most recent.
- **Direct paste-back** — reactivates the previously focused app and synthesizes
  ⌘V so the entry lands in the field you were typing in. Needs the macOS
  Accessibility permission (prompted on first run); falls back to copy-only when
  it isn't granted.
- **Content-type affordances** — a snippet that's a whole URL, email, or hex
  color gets an inline action: open the link, compose an email, or a color swatch.
- **Pin · delete · clear** — a per-row star pins a favorite (pinned entries
  surface in their own section and survive eviction *and* clear); a per-row trash
  deletes (instant for unpinned, confirmed for pinned); "Clear History…" in the
  status menu wipes unpinned entries (pins kept), with confirmation.
- **Global hotkey** ⌘⇧V (via `KeyboardShortcuts`) to summon the panel.
- **Pasteboard polling** every 0.5 s on a `changeCount` check, with
  **concealed/transient skip** so password-manager (`ConcealedType`) and
  transient clipboard data are never recorded.
- **History log** at `~/Library/Application Support/Clipd/clipd.log`.
- **Defaults:** `max_entries = 10000`, 4 MB compaction threshold, 0.5 s poll.

Every C call is serialized on one `DispatchQueue`; search results are copied
into Swift values and handed straight back to `clipd_free_results`, so no C++
pointer outlives the call. Idle CPU was measured at ~0% in Phase 3 (the poll
loop is a single integer `changeCount` comparison twice a second).

The testable, UI-free layer (`ClipdKit`) is a SwiftPM library with 62 XCTest
cases — including pure helpers for the content-type classifier, keyboard-selection
index math, the paste-vs-copy fallback rule, and the pinned-section split. The
menu-bar app is an Xcode target generated from `project.yml`. See
[CLAUDE.md](CLAUDE.md) for the exact `swift test` / `xcodebuild` invocations.

## Build & test

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure
```

Sanitizers (CI runs both):

```sh
cmake -B build-asan -DCMAKE_BUILD_TYPE=Debug -DCLIPD_SANITIZE=address
cmake --build build-asan && ctest --test-dir build-asan
# ...and -DCLIPD_SANITIZE=undefined
```

### Editor setup (clangd)

The build emits a `compile_commands.json`; symlink it at the repo root so
clangd picks up the real flags (it's gitignored):

```sh
ln -sf build/compile_commands.json compile_commands.json
```

Point it at `build-asan/` instead if you want sanitizer-aware diagnostics.

## The storage engine

Each record is written as `[length][crc32][payload]`. On startup the log is
replayed record-by-record; the first record that fails its length or CRC check
marks a torn tail, and everything from there is truncated — so a process killed
mid-write never corrupts the store. Compaction rewrites the log to the live set
via a temp file plus an atomic `rename()`, so a crash during compaction leaves
either the old or the new complete log, never a broken in-between.

## Durability — honest framing

The log is **corruption-safe**: a torn record (a write killed mid-flight) is
always detected by the length+CRC32 check and truncated on replay, so the store
never loads garbage. That guarantee holds unconditionally.

Power-loss durability is narrower, and deliberately so:

- **Compaction is fsync-durable.** Before the atomic `rename()`, the temp file
  is flushed to stable storage with `F_FULLFSYNC` (`fdatasync` on non-Apple);
  after the rename, the containing directory is `fsync`'d so the rename entry
  itself survives a crash. Every one of those calls throws on failure, so a
  dropped sync surfaces as a non-zero `clipd_compact` rather than a false claim
  of durability.
- **Appends are not fsync'd.** A normal append is buffered, so a power loss can
  lose the last few entries that hadn't reached disk. For a clipboard cache
  that's an acceptable trade — per-copy `F_FULLFSYNC` would tax every keystroke
  of copied text for little real benefit.

Encryption-at-rest stays **Future Work**; the log is plaintext today (see
*Limitations*).

## Crash-recovery demo

```sh
./scripts/torn_write_demo.sh ./build/clipd-cli
```

It adds three entries, appends a corrupt partial record to the tail (simulating
a mid-write crash), then shows `replay` truncating to the last valid record with
earlier history fully intact:

```text
==> Adding three entries
entries: 3
log_bytes: 82

==> Log is clean
valid records: 3
log clean (no truncation)

==> Simulating a crash mid-write: appending a torn record to the tail
    log size is now 97 bytes (corrupted tail)

==> Replaying: torn tail detected and truncated
valid records: 3
truncated torn tail: 97 -> 82 bytes

==> Earlier history is intact
1779997192513	1.5	third entry
1779997192511	1.5	second entry
1779997192509	1.5	first entry
```

![Crash-recovery demo](docs/torn_write_demo.gif)

The GIF is regenerable from the committed script:
`vhs docs/torn_write_demo.tape` (needs `brew install vhs`).

## Eviction (FR6)

History is bounded by a configurable cap (`max_entries`, default 10000), set at
create time. Each new clip evicts the least-recently-used entry once the cap is
reached; re-copying an existing entry bumps it to most-recent instead, so active
items are never evicted. Replay re-derives the live set in chronological order
and re-applies eviction at the *current* cap — it never resurrects an entry that
was evicted under that cap. Raising the cap can recover still-logged entries on
the next open (until the next compaction rewrites the log to the live set).

## Benchmarks

`./build/clipd_bench` (Release build) on an Apple M5 (16 GB, macOS 26.5):

| Entries | Mean | p50 | p99 | Peak RSS |
|--------:|-----:|----:|----:|---------:|
| 10,000 | ~0.19 ms | ~0.18 ms | ~0.23 ms | ~3.2 MB |
| 50,000 | ~0.98 ms | ~0.97 ms | ~1.22 ms | ~8.5 MB |

Comfortably under the PRD's sub-millisecond target at 10k, with a ~3 MB footprint
for 10k entries held in memory. A linear subsequence scan stays imperceptible at
this scale; an index becomes worthwhile around ~1M entries (see *Limitations*).

## Limitations (v1, honest framing)

- **Storage is plaintext — including image blobs.** The macOS shell (Phase 3)
  excludes password-manager `ConcealedType`/`TransientType` clipboard data, but
  arbitrary private text still lands in a plaintext log, and image bytes sit in
  a plaintext content-addressed blob store on disk (`<log>.blobs/<id>`). That
  filter is the floor, **not** security: encryption-at-rest is Future Work, and
  the store is **not** secure today.
- **Apple's Passwords app can't be reliably excluded.** `ConcealedType` is a
  third-party convention (1Password, Chrome, Bitwarden honor it); Apple's
  Passwords app / Keychain copy a password as a bare plain-text string with no
  marker. As a best-effort fallback, copies made while a known secret app is
  frontmost (`com.apple.Passwords`, Keychain Access) are skipped — but that's a
  source-app heuristic with a brief timing race, not security.
- **Files are captured by reference, not by value.** A file copy stores its path
  only; if the file is moved or deleted before paste-back, the reference points
  nowhere. Image bytes, by contrast, are captured in full (their pasteboard
  representation is the bytes themselves).
- **Capture priority is file → text → image.** A copied file is detected first:
  Finder's ⌘C puts the file URL **plus** the filename as plain text **plus** the
  icon as an image, so checking text first would store a file as just its name
  (and pasting it back would yield text, not the file). Text still beats image,
  so rich text with an inline image is stored as text (the more searchable
  representation).
- **Fuzzy matching is ASCII-only.** Case-folding and word-boundary detection
  target ASCII; UTF-8 multibyte sequences are matched byte-for-byte and never
  split, but accent-insensitive / CJK / emoji handling is Future Work.
- **Search is a linear scan.** Sub-millisecond to ~50k entries; an n-gram/trie
  index is Future Work for scaling to ~1M.
- **Single-threaded core.** The core is lock-free; the Swift shell serializes
  every C call on one `DispatchQueue`.
- **Delete / clear are not secure erase.** A deleted or cleared entry leaves the
  live set immediately, and its records (and any image blob) are dropped at the
  next compaction — but until then the bytes still exist in the plaintext log /
  blob store. This is removal, not cryptographic erasure (encryption-at-rest is
  Future Work).
- **Pinned entries are exempt from eviction *and* the byte budget.** Pinning many
  large images can push total on-disk usage above the configured byte budget,
  since pinned entries are never evicted to reclaim space.
