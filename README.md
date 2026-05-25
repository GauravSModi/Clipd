# Clipd

Fast, local-first clipboard history for macOS. The engineering centerpiece is a
C++ core: an in-memory store with fuzzy search and a **crash-safe append-only
storage engine**. This repository currently contains **Phase 1** — the
standalone C++ core, driven by a scriptable CLI harness, with tests and
benchmarks. (The Swift menu-bar shell is a later phase.)

## Architecture

The core is split into small, independently testable units:

| Unit | Responsibility |
|------|----------------|
| `Crc32` | IEEE CRC32 checksum (table-based). |
| `ClipStore` | In-memory entries: dedup, recency ordering, bounded-size LRU eviction. Sole authority on what is *live*. |
| `FuzzyMatcher` | Pure subsequence match + quality scoring (contiguity, word/camelCase boundary, position, recency). |
| `Log` | Crash-safe append-only log: length+CRC32 records, torn-write truncation, compaction via atomic rename, replay. |
| `Core` | Coordinator — wires the store, log, and matcher together. No policy of its own. |
| `clipd-cli` | Scriptable front-end (`add`/`search`/`list`/`compact`/`stats`/`replay`). |

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

## The storage engine

Each record is written as `[length][crc32][payload]`. On startup the log is
replayed record-by-record; the first record that fails its length or CRC check
marks a torn tail, and everything from there is truncated — so a process killed
mid-write never corrupts the store. Compaction rewrites the log to the live set
via a temp file plus an atomic `rename()`, so a crash during compaction leaves
either the old or the new complete log, never a broken in-between.

See it in action:

```sh
./scripts/torn_write_demo.sh ./build/clipd-cli
```

This adds entries, appends a corrupt partial record to the tail, then shows
`replay` truncating to the last valid record with earlier history intact.

## Benchmarks

`./build/clipd_bench` (Release build), Apple Silicon:

| Entries | Mean | p50 | p99 |
|--------:|-----:|----:|----:|
| 10,000 | ~0.57 ms | ~0.54 ms | ~1.0 ms |
| 50,000 | ~3.1 ms | ~3.0 ms | ~5.2 ms |

Peak resident memory at 50k entries: ~9 MB. A linear subsequence scan stays
imperceptible at this scale; an index becomes worthwhile around ~1M entries
(see *Limitations*).

## Limitations (v1, honest framing)

- **Storage is plaintext.** The macOS shell (later phase) excludes
  password-manager `ConcealedType`/`TransientType` clipboard data, but arbitrary
  private text still lands in a plaintext log. Encryption-at-rest is Future Work;
  the store is **not** secure today.
- **Fuzzy matching is ASCII-only.** Case-folding and word-boundary detection
  target ASCII; UTF-8 multibyte sequences are matched byte-for-byte and never
  split, but accent-insensitive / CJK / emoji handling is Future Work.
- **Search is a linear scan.** Sub-millisecond to ~50k entries; an n-gram/trie
  index is Future Work for scaling to ~1M.
- **Single-threaded core.** Phase 1 has no locks; the shell will serialize all
  calls on one dispatch queue.
