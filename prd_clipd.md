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

> **Post-v1 shell-enhancement amendment (2026-05-29).** A four-feature UX batch
> extends the panel beyond the FRs, all **shell-only** (no C++ core, C API,
> header, or log change):
> - **Direct paste-back.** The default activation now *pastes* the chosen entry
>   into the previously focused app (Enter / click), with **copy-back on ⌘↵ /
>   ⌘-click**. This deliberately shifts the FR3/FR4 "copy back" default to "paste"
>   while keeping copy available; it requires the macOS Accessibility permission
>   and falls back to copy-only when that isn't granted.
> - **Keyboard selection.** ↑/↓ + Enter activate the highlighted row (extending
>   FR4's "Enter copies top result"), plus ⌘1–9 for the Nth recent.
> - **Content-type affordances.** A whole-string URL / email / hex color gets an
>   inline action (open link / compose / color swatch).
> - **Launch at login** via `SMAppService`, with a first-launch prompt.
>
> These are UX extensions, not changes to the storage/search contract.

> **Post-v1 image / file capture amendment (2026-05-29).** Promotes the v1 *non-goal*
> "Image/file clipboard support" and the Future-Work item "Image/file clipboard
> support" to **supported features**. This is the first post-v1 change that
> touches every layer (Entry/identity, log record format, the C API, and the
> Swift shell), so the storage/search contracts are **extended** here, not
> bypassed.
> - **Capture:** images are stored as bytes; files are stored **by reference**
>   (the path), not by copying contents. Capture priority is **file → text →
>   image** (corrected 2026-06-06 — see the note below): a file copy is detected
>   first because Finder ⌘C also puts the filename as text and the icon as an
>   image; text still beats image so rich text with an inline image stays text.
> - **Identity:** every entry has a stable `id = sha256-hex(kind_byte ‖ content)`.
>   The leading kind byte is domain separation so a text and a file with the
>   same content bytes never collide.
> - **Storage:** image bytes live in a content-addressed blob store at
>   `<log_path>.blobs/<id>` (write-once, atomic rename, fsync); the log carries
>   only small reference records. The log format gains a `"CLPD"`+version header
>   and per-record type tags (TEXT / IMAGE / FILE; PIN/UNPIN/TOMBSTONE/CLEAR
>   reserved for the next batch). Pre-amendment header-less text-only logs
>   replay as TEXT and are migrated to v1 on first start (one compaction).
> - **Crash safety:** the blob is written and fsync'd **before** the log record
>   that references it (a crash leaves an orphan blob, never a dangling
>   reference). On replay, an image record whose blob is gone skips just that
>   one entry. Orphan blobs are GC'd by compaction, but only **after** the new
>   log is durably renamed.
> - **Eviction:** the count cap stays; a new total-byte budget is enforced
>   alongside it, and an optional per-image cap rejects oversize images at
>   ingest. A single oversize entry is kept (the most-recent insert is never
>   evicted away).
> - **Search:** `FuzzyMatcher` stays pure — it sees a synthesized label
>   (files match on filename + path; images on a label like `"image 1024x768 png"`).
> - **C API + memory model:** `ClipdMatch` gains `kind`/`id`/`byte_size`/`width`/
>   `height` (still one single-arena allocation, freed in one call). Image bytes
>   are fetched on demand via `clipd_read_blob` + `clipd_free_blob` (its own
>   single-malloc/single-free buffer) so the search arena stays small.
>
> **Limitations to keep framed honestly (not to overclaim away):** referenced
> files can be moved/deleted between capture and paste-back; image bytes sit in
> a **plaintext blob store on disk** — worse for sensitive images than the
> already-plaintext text log. The concealed/transient pasteboard filter is
> still the floor, not security. Encryption-at-rest remains Future Work.
>
> **Capture-priority correction (2026-06-06).** The original amendment specified
> capture priority **text → image → file**; runtime testing showed this made file
> capture non-functional. A Finder ⌘C on a file puts the file URL **plus** the
> filename as `public.utf8-plain-text` **plus** the icon as `public.tiff`, so a
> text-first check always captured the file as just its filename (and paste-back
> yielded that text, never the file). Corrected to **file → text → image**: a
> real file URL wins over the filename text and icon; text still beats image so
> rich text with an inline image stays text. (Fix: `PasteboardMonitor.poll`
> reorder + regression test `testFinderFileCopyIsCapturedAsFileNotFilenameText`.)
> Note: this only affects copies made **after** the fix — entries already stored
> as text are not retroactively re-typed.

> **Post-v1 pinned / delete / clear amendment (2026-06-06).** Promotes the
> Future-Work item "Pinned/favorite entries" to a shipped feature and adds
> delete-an-entry and clear-history alongside it (one batch — they share new
> record types, the existing `id` key, and the eviction/compaction paths). Built
> directly on the image/file identity + record-type machinery; the storage/search
> contracts are **extended**, not bypassed.
> - **Record types:** the four reserved log tags are implemented — `PIN` (3),
>   `UNPIN` (4), `TOMBSTONE` (5), `CLEAR` (6). Each is a control record (a state
>   change keyed on an `id`, no content, no timestamp); replay applies content
>   and control records strictly in file order so the live set is re-derived
>   chronologically. PIN/UNPIN are last-write-wins, like text dedup.
> - **Pinned:** `Entry.pinned`; a pinned entry is exempt from eviction (eviction
>   evicts the least-recent **unpinned** entry, never the most-recent insert).
>   Pinned matches sort first in search, so an old pin still surfaces, and the
>   panel renders them as a separate **"Pinned" section**. Persisted via
>   PIN/UNPIN records; compaction re-emits a PIN record after each pinned entry's
>   content record (the content schema is unchanged).
> - **Delete:** `clipd_delete` writes a TOMBSTONE; replay drops the entry;
>   compaction discards both the tombstone and the dead record. A deleted image's
>   blob is reclaimed by the **next compaction's existing GC**, not eagerly
>   (matches the "GC at compaction, post-rename" rule).
> - **Clear:** `clipd_clear` keeps pinned entries (**clear-unpinned**). It writes
>   a CLEAR record (durable for the crash window) then compacts to a pinned-only
>   log, GC-ing every now-unreferenced blob.
> - **C API + shell:** `clipd_set_pinned` (idempotent set-to-bool) / `clipd_delete`
>   / `clipd_clear`; `ClipdMatch` gains `pinned` (still one single-arena alloc).
>   The panel adds a per-row star toggle and trash button and a status-menu
>   "Clear History…". Clear is confirmed; per-row delete is instant for unpinned
>   rows and **confirmed for pinned** rows (a pin is explicitly marked important
>   and there is no undo).
>
> **Limitations to keep framed honestly:** delete/clear are not "secure erase" —
> the bytes leave the live set and are dropped at the next compaction, but the
> store remains plaintext and unencrypted (Future Work). Pinning large images
> counts toward the byte budget and can push total on-disk usage above it (pinned
> entries are never evicted to reclaim space).

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
- Pinned/favorite entries (next batch on top of the image/file identity model).

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