# Clipd

[![CI](https://github.com/GauravSModi/Clipd/actions/workflows/ci.yml/badge.svg)](https://github.com/GauravSModi/Clipd/actions/workflows/ci.yml)

**Fast, local-first clipboard history for macOS.** Clipd quietly remembers
everything you copy — text, images, and files — and hands it all back through a
search panel that's one keystroke away. Everything stays on your Mac; nothing
ever touches the network.

Under the hood it's a hand-written **C++ storage engine** — a crash-safe log,
fuzzy search, and a content-addressed blob store — behind a thin Swift menu-bar
app. It's a portfolio project, so the engineering is as much the point as the
app itself; if that's what you're here for, jump to [Under the hood](#under-the-hood).

> **Heads up:** Clipd is build-from-source today (no notarized download yet).
> See [Getting started](#getting-started) — it takes a couple of minutes.

## Contents

- [Features](#features)
- [Getting started](#getting-started)
- [Using Clipd](#using-clipd)
- [Privacy & security](#privacy--security)
- [Under the hood](#under-the-hood)
- [Build & test](#build--test)
- [Limitations](#limitations)

## Features

- 📋 **Captures everything you copy** — text, images, and files, automatically.
- 🔍 **Instant fuzzy search** — just start typing; stays sub-millisecond even
  over tens of thousands of entries.
- ⤵️ **Pastes straight back** — pick an entry and it lands in the app you were
  just in (or copy without pasting via ⌘↵).
- ⭐ **Pin favorites** — snippets you reuse get their own section and are never
  evicted or cleared.
- 🗑️ **Delete & clear** — remove one entry or wipe history (pins kept), with a
  confirmation where it matters.
- 🔗 **Smart row actions** — a copied URL, email, or hex color gets an inline
  open-link / compose / color-swatch button.
- 🔒 **Local & private** — plain on-disk storage, no network, password-manager
  copies skipped (with honest [caveats](#privacy--security)).
- 🛟 **Crash-safe storage** — a hand-written append-only log that survives a
  mid-write crash or power loss without corrupting your history.
- 🪶 **Featherweight** — about 3 MB of RAM at 10,000 entries and ~0% idle CPU.

## Getting started

**You'll need:** macOS 13 or newer, [Xcode](https://developer.apple.com/xcode/),
and [Homebrew](https://brew.sh).

```sh
# 1. Build tools
brew install cmake xcodegen

# 2. Build the C++ core
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build

# 3. Generate the app project and open it
xcodegen generate
open Clipd.xcodeproj
```

Press **Run** (⌘R) in Xcode. On first launch Clipd will:

- ask for the **Accessibility** permission — needed to paste back into other
  apps. You can decline; it just falls back to copy-only.
- offer to **Launch at Login** so your history is always being captured.

Clipd lives in the **menu bar** (no Dock icon). Press **⌘⇧V** any time to open
the search panel. To quit, right-click the menu-bar icon → Quit.

> Prefer the terminal? `xcodebuild -project Clipd.xcodeproj -scheme Clipd
> -configuration Debug -destination 'platform=macOS' build` builds the app
> headlessly — see [Build & test](#build--test).

## Using Clipd

Hit **⌘⇧V** (or click the menu-bar icon) to open the panel, then type to filter.
An empty query shows your most recent copies.

| Action | How |
|---|---|
| Open / close the search panel | **⌘⇧V** |
| Move the selection | **↑ / ↓** |
| Paste the selected entry into your previous app | **Enter** ¹ |
| Copy the selected entry (don't paste) | **⌘↵** |
| Grab the Nth most-recent entry | **⌘1** – **⌘9** |
| Pin / unpin a row | the **★** button |
| Delete a row | the **🗑** button (instant; pinned rows ask first) |
| Clear all history (keeps pins) | menu-bar icon → **Clear History…** |

**Pinned** entries sit in their own section at the top and are never evicted or
cleared, so your go-to snippets are always one ⌘⇧V away.

¹ Paste-back needs the Accessibility permission. Without it, **Enter** copies the
entry instead so you can paste it yourself.

## Privacy & security

Clipd is **local-first**: your history is a plain file under
`~/Library/Application Support/Clipd/`, and nothing is ever sent off your Mac.

Being straight about what that does and doesn't protect:

- **The store is not encrypted.** Everything you copy — private text included,
  and image bytes — is written to disk in plain form. Encryption-at-rest is
  planned, not done, so don't treat Clipd as a vault.
- **Password managers that tag their copies are skipped** — 1Password, Bitwarden,
  Chrome / Google Password Manager, etc., which mark secrets with the standard
  `ConcealedType` flag.
- **Apple's Passwords app is the exception.** It copies passwords as ordinary
  text with no flag, so Clipd can't reliably tell them apart. As a fallback it
  skips copies made while the Passwords app or Keychain Access is frontmost —
  best-effort, not a guarantee.

The full technical list is in [Limitations](#limitations).

## Under the hood

> This is the engineering tour — the reason the project exists.

Clipd is a deliberately thin Swift shell over a hand-written C++ core. The core
holds **all** the policy (dedup, scoring, durability, eviction); the shell only
polls the pasteboard, draws the panel, and forwards calls. The core is split
into small, independently testable units behind a flat `extern "C"` API:

| Unit | Responsibility |
|------|----------------|
| `ClipStore` | In-memory entries: dedup, recency ordering, bounded LRU eviction (pinned entries are exempt — the least-recent *unpinned* entry is evicted). Sole authority on what's *live*. |
| `FuzzyMatcher` | Pure subsequence match + quality scoring (contiguity, word/camelCase boundaries, position, recency). |
| `Log` | Crash-safe append-only log: `"CLPD"`+version header, type-tagged `length`+`CRC32` records (text / image / file + pin / unpin / tombstone / clear), torn-write truncation, compaction via atomic rename, replay. |
| `BlobStore` | Content-addressed image-byte store (`<log>.blobs/<id>`): write-once, atomic rename + fsync, garbage-collected at compaction. |
| `Core` | Coordinator — wires the store, log, blob store, and matcher together; owns identity derivation and pinned-first ordering. No other policy of its own. |
| `Crc32` / `Sha256` | Hand-rolled checksums: CRC32 for record integrity, SHA-256 for content-derived entry ids. |
| `clipd.h` | The flat C boundary the shell links against (`clipd_create` / `add` / `add_image` / `add_file` / `search` / `read_blob` / `set_pinned` / `delete` / `clear` / `compact` / `stats` / `free_results`). |
| `clipd-cli` | Scriptable front-end for everything above — handy for tests, demos, and benchmarks without launching the app. |

The Swift side (`ClipdKit`) serializes every C call on one `DispatchQueue`, then
copies results into native Swift values and hands the C memory straight back to
`clipd_free_results` — so no C++ pointer ever outlives the call. Idle CPU is ~0%:
the poll loop is a single integer `changeCount` comparison twice a second.

### Crash-safe storage engine

Each entry is written as a length-prefixed, checksummed record:
`[length][crc32][payload]`. On startup the log is replayed record-by-record; the
**first** record that fails its length or CRC check marks a torn tail, and
everything from there is truncated. So a process killed mid-write never loads
garbage — that guarantee holds unconditionally.

Compaction rewrites the log down to just the live set via a temp file plus an
atomic `rename()`, so a crash *during* compaction leaves either the old or the
new complete log — never a broken in-between.

**On power loss, the guarantees are narrower — deliberately:**

- **Compaction is fsync-durable.** Before the rename, the temp file is flushed to
  stable storage with `F_FULLFSYNC` (`fdatasync` off Apple platforms); after the
  rename, the directory is `fsync`'d so the rename entry itself survives. Each
  call throws on failure, so a dropped sync surfaces as a non-zero `clipd_compact`
  rather than a false promise of durability.
- **Appends are not fsync'd.** A normal append is buffered, so a power loss can
  lose the last few entries that hadn't reached disk yet. For a clipboard cache
  that's a deliberate trade — `F_FULLFSYNC` on every copy would tax every
  keystroke of copied text for little real benefit.

### Recovery demo

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

Regenerate the GIF with `vhs docs/torn_write_demo.tape` (needs `brew install vhs`).

### Benchmarks

`./build/clipd_bench` (Release build) on an Apple M5 (16 GB, macOS 26.5):

| Entries | Mean | p50 | p99 | Peak RSS |
|--------:|-----:|----:|----:|---------:|
| 10,000 | ~0.19 ms | ~0.18 ms | ~0.23 ms | ~3.2 MB |
| 50,000 | ~0.98 ms | ~0.97 ms | ~1.22 ms | ~8.5 MB |

Comfortably under the sub-millisecond target at 10k. A linear subsequence scan
stays imperceptible at this scale; an index only becomes worthwhile around ~1M
entries (see [Limitations](#limitations)).

## Build & test

```sh
# Build + run the test suite (Release)
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build --output-on-failure          # 147 GoogleTest cases

# Swift layer (links the C++ archives in build/)
swift test                                           # 65 XCTest cases
```

Sanitizers — CI runs the C++ **address** (with leak detection) and
**undefined** suites; the Swift sanitizers are local-only. Run them all before a
PR:

```sh
# C++ — what CI gates on
cmake -B build-asan  -DCMAKE_BUILD_TYPE=Debug -DCLIPD_SANITIZE=address
cmake --build build-asan  && ctest --test-dir build-asan
cmake -B build-ubsan -DCMAKE_BUILD_TYPE=Debug -DCLIPD_SANITIZE=undefined
cmake --build build-ubsan && ctest --test-dir build-ubsan

# Swift — run locally
swift test --sanitize=address    # also: --sanitize=thread
```

> Heads up: macOS AddressSanitizer doesn't run LeakSanitizer, so a leaky test can
> pass locally. CI's Linux ASan job sets `ASAN_OPTIONS=detect_leaks=1` and will
> catch it; locally, use `leaks --atExit -- ./build/tests/clipd_tests`.

**Editor setup (clangd):** the build emits `compile_commands.json`; symlink it at
the repo root so clangd sees the real flags (it's gitignored):

```sh
ln -sf build/compile_commands.json compile_commands.json
```

The menu-bar app is an Xcode target generated from `project.yml` (`Clipd.xcodeproj`
is gitignored — regenerate with `xcodegen generate`). See [CLAUDE.md](CLAUDE.md)
for the full developer workflow.

## Limitations

Potential improvements/changes to work on in the future:

- **Storage is plaintext — including image blobs.** The shell skips
  password-manager `ConcealedType` / `TransientType` copies, but arbitrary
  private text still lands in a plaintext log and image bytes sit in a plaintext
  blob store. That filter is a floor, **not** security; encryption-at-rest is
  Future Work and the store is **not** secure today.
- **Apple's Passwords app can't be reliably excluded.** `ConcealedType` is a
  third-party convention; Apple's Passwords app / Keychain copy a password as a
  bare plain-text string with no marker. The fallback (skip copies made while a
  known secret app is frontmost: `com.apple.Passwords`, Keychain Access) is a
  source-app heuristic with a brief timing race — best-effort, not security.
- **Files are captured by reference, not by value.** A file copy stores its path
  only; if the file is moved or deleted before paste-back, the reference points
  nowhere. (Images, by contrast, are captured in full.)
- **Capture priority is file → text → image.** Finder's ⌘C puts a file URL *plus*
  the filename as text *plus* the icon as an image, so files are detected first —
  otherwise a file would be stored as just its name. Text still beats image, so
  rich text with an inline image is stored as text (the more searchable form).
- **Delete / clear are removal, not secure erase.** A deleted or cleared entry
  leaves the live set immediately, but its bytes persist in the plaintext log /
  blob store until the next compaction drops them.
- **Pinned entries are exempt from eviction *and* the byte budget.** Pinning many
  large images can push total on-disk usage past the configured budget, since
  pins are never evicted to reclaim space.
- **Fuzzy matching is ASCII-only.** Case-folding and word-boundary detection
  target ASCII; UTF-8 is matched byte-for-byte and never split, but
  accent-insensitive / CJK / emoji handling is Future Work.
- **Search is a linear scan.** Sub-millisecond to ~50k entries; an n-gram / trie
  index is Future Work for scaling toward ~1M.
- **Single-threaded core.** The core is lock-free; the Swift shell serializes
  every C call on one `DispatchQueue`.
