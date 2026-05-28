# PRD: Clipd — Fast Clipboard History for macOS

## Summary
A menu bar app that keeps a searchable history of everything you copy. Swift handles the menu bar UI and clipboard polling; a C++ core handles storage, dedup, indexing, and fuzzy search. The C++ core is where the real engineering lives and is the portfolio centerpiece.

## Problem
macOS forgets your clipboard the moment you copy something new. You lose snippets, links, and text you needed two copies ago. Existing tools exist but are often bloated, slow on large histories, or cloud-syncing things you'd rather keep local.

## Goals
- Instant retrieval of recent clipboard items via a menu bar dropdown + global hotkey.
- Sub-millisecond fuzzy search over 10k+ stored items.
- High-quality fuzzy match ranking that *feels* smart.
- Fully local, no network. Privacy is a feature.
- Demonstrable C++ engineering: clean library, crash-safe storage, benchmarks, tests, sanitizers.

## Non-goals
- iCloud / cross-device sync (kills the local-first story, adds scope).
- Image/file clipboard support in v1 (text only first).
- Settings UI beyond the essentials.

## Architecture
The whole point is a clean boundary so the C++ is real, not decoration.

**Swift shell (thin):**
- Menu bar icon + dropdown list (AppKit/SwiftUI).
- Polls `NSPasteboard.changeCount` on a timer; only reads actual clipboard contents when the integer has incremented. Reading contents every tick is slow; checking the counter is practically free.
- Filters out concealed/transient clipboard types before ingesting (see Pasteboard security).
- Global hotkey via a small third-party Swift hotkey library (no hand-rolled Carbon code).
- Serializes all calls into the C++ library on a single background dispatch queue (see Concurrency model).
- Calls into the C++ core over a small C API.

**C++ core (the meat):**
- In-memory store of clipboard entries with recency ordering.
- Deduplication (don't store the same thing twice; bump recency instead).
- Fuzzy search index with a quality scoring function.
- Crash-safe append-only persistent log with checksums and compaction.
- Exposed as a C ABI (`extern "C"`) so Swift can call it cleanly.

**Boundary:** C++ compiles to a static/dynamic lib with a flat C header. Swift talks to it through that header. This is the credible, real-world pattern used by many production Mac apps.

## Storage engine (the core C++ challenge)
A naive "append lines to a file" log is not impressive. The engineering value comes from making it crash-safe and self-maintaining, which is a miniature of what real storage engines (SQLite, RocksDB) do.

**Record format:** each entry is written as a length-prefixed record with a per-record CRC32 checksum:
`[length][crc32][payload]`

**Crash safety / torn-write detection:** if the process dies mid-write, the final record may be incomplete or corrupt. On startup, the log is replayed record by record; the checksum and length validate each one. The first record that fails validation marks the torn tail — everything from there is truncated, leaving a clean, valid log. No half-written entry corrupts the store.

**Compaction:** an append-only log grows forever, and dedup means superseded entries accumulate. Periodically (on size threshold), the log is rewritten keeping only live entries: write the compacted state to a temp file, then atomically `rename()` it over the original. The atomic rename guarantees that a crash during compaction never destroys the existing valid log — you either have the old one or the new one, never a corrupt in-between.

**Recovery:** on startup, replay the (validated) log to rebuild the in-memory store and search index.

This combination — length-prefixed + checksummed records, torn-write detection with truncation, compaction via atomic rename, and replay-based recovery — is the "this person understands storage internals" signal.

## Fuzzy search (v1: simple structure, strong scoring)
For the target scale (10k–50k short entries), a linear subsequence scan is comfortably sub-millisecond, so v1 uses a simple structure and invests effort in **match quality**, not the data structure.

**Matching:** subsequence match (query characters appear in order, not necessarily contiguous).

**Scoring** — the part that makes it feel smart. Rank matches by a weighted score considering:
- Contiguity (consecutive matched characters score higher than scattered ones).
- Word-boundary and camelCase-boundary hits (matching the start of a word/segment scores higher).
- Position (earlier matches score higher).
- Recency weighting (more recently copied entries get a boost, since clipboard use is recency-heavy).

**Scale note for context:** linear scan stays imperceptible to ~50k entries. At ~1M entries it degrades to roughly 30–100ms per keystroke (bottlenecked by memory bandwidth and cache misses, not raw comparisons), which is where an index becomes worthwhile — see Future Work.

## Pasteboard security
"Capture every text copy" must have a hard exception for sensitive data. Password managers (1Password, Keychain, Bitwarden, etc.) tag copied secrets with `org.nspasteboard.ConcealedType` and transient data with `org.nspasteboard.TransientType`. The Swift shell must inspect pasteboard types and skip ingesting anything carrying these markers — otherwise passwords land in a plaintext C++ log on disk, which is a severe security hole.

Honest framing for v1: concealed/transient exclusion is the **floor**, not full security. Arbitrary private text still gets written to a plaintext log. Encryption-at-rest is explicitly deferred to Future Work, and the README should say so rather than implying the store is secure.

## C API memory model
The inviolable rule: **C++ owns both allocation and free; Swift never frees C++ memory directly.** Swift and C++ may use different allocators, so freeing across the boundary is undefined behavior.

Shape for returning search results:

```c
typedef struct {
    const char* text;
    int64_t timestamp;
    float score;
} ClipdMatch;

typedef struct {
    ClipdMatch* matches;
    size_t count;
} ClipdResults;

ClipdResults* clipd_search(ClipdCore* core, const char* query, size_t max_results);
void clipd_free_results(ClipdResults* results);  // C++ frees what C++ allocated
```

Flow: Swift calls `clipd_search`, copies each struct into native Swift `String`s (`String(cString:)` allocates its own buffer), then immediately calls `clipd_free_results`. After that call Swift holds zero pointers into C++ memory.

Implementation detail that makes this leak-proof: allocate the entire result set as **one contiguous arena** — a single `malloc` covering the `ClipdResults`, the `ClipdMatch` array, and all string bytes packed behind it, with each `text` pointing into that block. `clipd_free_results` is then a single `free`. One allocation, one free, impossible to leak half of it. Copy cost is irrelevant (returning ~20 short strings, not 10k).

Rejected alternatives:
- *Zero-copy pointers into the live store:* they dangle the moment eviction or compaction mutates the store. Imposes a fragile "valid until next call" contract on Swift. Not worth it at this scale.
- *Swift pre-allocates a buffer C++ fills:* breaks on variable-length strings; forces a two-call size-then-fill pattern for no benefit here.

## Concurrency model
All calls into the C++ library — searches, inserts, eviction, compaction — run on a **single serial dispatch queue** in the Swift shell. From the core's perspective this makes it effectively single-threaded, so **no locks are required.** Compaction runs on that same serial queue; it's occasional and fast at this data size, so a brief block during a search keystroke is imperceptible.

This is strictly simpler than a reader-writer lock and removes a whole class of concurrency bugs (e.g. a search reading the store while compaction rewrites it). A reader-writer lock only becomes worthwhile if compaction later moves to a truly concurrent background thread — not needed for v1.

## Functional requirements
1. Capture every text copy automatically, except entries tagged concealed/transient (see Pasteboard security).
2. Dedup identical entries, keep most-recent timestamp.
3. Open dropdown showing N most recent; click to copy back.
4. Global hotkey opens a search field; type to fuzzy-filter; Enter copies top result.
5. History persists across restarts (via crash-safe log replay).
6. Configurable max history size with automatic eviction.

> **Phase 3 amendment (approved 2026-05-27).** Requirements 3 and 4 are merged
> into a **single unified search panel**, summoned by both the menu-bar icon and
> the global hotkey. An empty query shows the N most recent entries (the "dropdown"
> of FR3); typing fuzzy-filters; Enter or a click copies the chosen entry back.
> One surface satisfies both FR3 and FR4 instead of a separate dropdown + window.

## Success metrics (README / interview talking points)
- Fuzzy search latency over 10k entries (target: <1ms; show the benchmark).
- Recovery correctness: demonstrate clean truncation after a simulated torn write.
- Memory footprint at 10k entries.
- Idle CPU usage (clipboard polling should be near-zero).

## Quality bar
- CMake build.
- Unit tests (Catch2 or GoogleTest), including crash/recovery and compaction tests.
- ASan / UBSan (and TSan if any threading) wired into CI.
- Benchmark harness with real numbers in the README.

## Phases
1. **C++ core standalone** — store, dedup, fuzzy search + scoring, crash-safe log, compaction, recovery. Driven by a CLI test harness, no Mac code yet. Tests + benchmarks here. *This is most of the value; build it first.*
2. **C API boundary** — wrap the core in `extern "C"`, build as a lib with a flat header.
3. **Swift shell** — menu bar, pasteboard polling, hotkey (third-party lib), wire to the lib.
4. **Polish** — eviction, persistence hardening, README with benchmarks and a recovery demo.

## Future work
- **Indexed search for scale:** trie or n-gram index to take search sublinear, with a synthetic 1M-entry benchmark demonstrating the naive scan degrading (~30–100ms/keystroke) and the index holding up. Turns the scale limitation into a documented engineering story.
- **Encryption-at-rest:** encrypt the log so private text isn't stored in plaintext. Concealed-type exclusion is the v1 floor; this is the real fix.
- **Concurrent compaction:** move compaction off the serial queue onto a background thread, introducing a reader-writer lock. Only needed if data size grows enough that serial-queue compaction causes perceptible stalls.
- Image/file clipboard support.
- Pinned/favorite entries.

## Portfolio optimization
- **Torn-write recovery demo:** test harness that kills the process mid-write (or corrupts the log tail directly), then shows recovery truncating to the last valid record. Terminal output or a GIF of this in the README is the single strongest selling point — most clipboard managers don't do crash-safe storage at all.
- **Technical blog post:** a linked writeup ("Writing a Crash-Safe Storage Engine in C++ for a Mac Menu Bar App") explaining the `rename()` atomicity and CRC32 decisions in depth. Gets more traction than a README alone and gives an interview talking point.

## Decisions locked
- Persistence: hand-rolled crash-safe append-only log (checksums + torn-write truncation + compaction via atomic rename).
- Search v1: simple subsequence scan with a quality scoring function; indexed search deferred to Future Work.
- Hotkey: small third-party Swift library, no hand-rolled Carbon code.
- Clipboard polling: watch `NSPasteboard.changeCount`, read contents only on change; exclude concealed/transient types.
- C API memory: C++ allocates and frees; single-arena result allocation; Swift copies out then calls the free function.
- Concurrency: single serial dispatch queue for all C++ calls (including compaction); no locks in v1.