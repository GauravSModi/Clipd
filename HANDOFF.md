# Handoff — Phase 3 (Swift shell)

## Goal

Build the thin Swift menu-bar app and wire it to the C++ core over the Phase 2
C API (`src/clipd.h`). The C++ does the real work; Swift owns only the UI,
clipboard polling, the global hotkey, and serializing calls into the library.
Authoritative spec: `prd_clipd.md` → *Architecture (Swift shell)*, *C API memory
model*, *Concurrency model*, *Pasteboard security*, *Functional requirements*.
Standing rules and invariants: `CLAUDE.md`.

Phase 3 must start from an **approved plan** (CLAUDE.md workflow rule). Don't
write code before that plan exists. If a request conflicts with the PRD, **flag
it** rather than silently resolving it.

## Current progress

- Phases 1 (core) and 2 (C API) are complete and on `master`:
  - Phase 1 core: `git show cb65551`.
  - Phase 2 — write-failure hardening + C API: `git show f4a2bbd 18e6549`.
- State: 57 GoogleTest cases green; ASan + UBSan clean; benchmark, torn-write
  demo, and a pure-C client (`tests/c_smoke.c`) all working.
- Re-verify anytime (full commands in `CLAUDE.md`):
  ```sh
  cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
  ctest --test-dir build --output-on-failure
  ```

## The C API you're consuming (`src/clipd.h`)

Opaque `ClipdCore*` handle; seven `extern "C"` functions:

- `clipd_create(log_path, max_entries, compact_threshold_bytes)` → handle, or
  NULL on failure (e.g. unwritable log path). Opens + replays the log for you.
- `clipd_destroy(core)` — NULL-safe.
- `clipd_add(core, text, timestamp_ms)` → 0 ok, nonzero on failure.
- `clipd_search(core, query, max_results, now_ms)` → `ClipdResults*`, or NULL on
  failure. **No match is a non-NULL result with `count == 0`** — distinct from
  NULL; branch on exactly that difference.
- `clipd_free_results(results)` — NULL-safe; one free of the whole result block.
- `clipd_compact(core)` / `clipd_stats(core, &out)` → 0 ok.

Result structs: `ClipdMatch { const char* text; int64_t timestamp; float
score; }`, `ClipdResults { ClipdMatch* matches; size_t count; }`,
`ClipdStats { size_t entry_count; uint64_t log_bytes; }`.

### Non-negotiable contracts (built and tested into Phase 2)

- **Memory:** C++ owns every allocation and the free. On the Swift side:
  `clipd_search`, copy each `text` into a Swift `String` (`String(cString:)`
  allocates its own buffer), copy timestamp/score, then immediately
  `clipd_free_results`. After that call, hold **zero** pointers into C++ memory.
  Never free a C++ pointer with a Swift/Foundation allocator.
- **Threading:** a `ClipdCore` is not thread-safe and holds no locks by design.
  Serialize **every** call (add, search, compact, stats) onto **one** serial
  `DispatchQueue`. Concurrent calls on the same handle are undefined behavior.
- **Time is injected, in epoch milliseconds.** `timestamp_ms` = when the copy
  happened; `now_ms` = the recency reference for a search. Use one consistent
  clock (e.g. `Int64(Date().timeIntervalSince1970 * 1000)`).
- **Text is NUL-terminated bytes**; embedded NULs truncate, matching is
  ASCII-oriented. Fine for clipboard text; a binary-safe API is Future Work.

## Open questions to resolve in the Phase 3 plan

1. **Build integration (the big one).** The core builds via CMake into static
   archives; decide how the Swift app consumes them — an Xcode app target
   linking the archives + a bridging header, or a SwiftPM package wrapping the C
   library. Watch for:
   - `libclipd_capi.a` holds **only** the C-API objects. Static archives don't
     bundle their dependencies, so the app must link **both** `libclipd_capi.a`
     **and** `libclipd_core.a`, plus the C++ runtime (`-lc++`).
   - Consider moving `src/clipd.h` → `include/clipd.h` for a clean bridging
     header (a Phase 2 note we deliberately deferred).
2. **Hotkey library.** PRD locks "small third-party Swift lib, no hand-rolled
   Carbon." Pick one (e.g. HotKey, KeyboardShortcuts) and decide how it's
   vendored.
3. **v1 UX scope.** Menu-bar dropdown of N most-recent + click-to-copy-back;
   global hotkey opens a search field, type to fuzzy-filter, Enter copies the
   top result.
4. **Compaction cadence.** `clipd_create` compacts past the threshold at
   startup; decide whether a long-running session also calls `clipd_compact`
   periodically on the serial queue (deeper eviction/persistence work is Phase
   4 — "polish").

## Pasteboard rules (PRD → Pasteboard security)

- Poll `NSPasteboard.general.changeCount` on a timer; read contents **only**
  when it increments (reading every tick is slow; the counter check is ~free).
- **Skip** anything tagged `org.nspasteboard.ConcealedType` or
  `org.nspasteboard.TransientType` — password managers mark secrets this way.
- This exclusion is the security **floor**, not real security: the log is still
  plaintext on disk. Keep that framed honestly in UI/README; encryption-at-rest
  is explicit Future Work. Don't overclaim.

## What worked (reuse these approaches)

- **Plan-first, per phase.** Brainstorm against the PRD, surface conflicts, get
  the plan approved before any code. Phase 2's planning caught two real core
  bugs (silent log-write failure; non-atomic `add`) before the adapter existed.
- **Strict TDD:** failing test first, watch it fail for the right reason, then
  implement. A change is done only when tests are green AND both sanitizers are
  clean.
- **Thin-adapter discipline.** The C layer added zero policy — only marshalling,
  the result arena, and exception translation. Keep the Swift shell equally
  thin: UI + polling + hotkey + the serial queue. No dedup/scoring/storage logic
  leaks out of the core.

## Gotchas (carry forward)

- **Always benchmark a Release build** of the core; Debug numbers are ~10× off
  and meaningless.
- `.claude/settings.local.json` is personal config and gitignored — keep it out
  of commits. Build dirs (`build/`, `build-*/`) and the root
  `compile_commands.json` symlink are gitignored too.
- **Don't commit unless asked. Don't start a phase without an approved plan.**

## Next steps

1. Plan Phase 3 against the PRD and get it approved. Resolve the
   build-integration question first — it shapes everything else.
2. Stand up the Swift app skeleton + the bridge to `clipd.h`; prove a
   round-trip (add a copy → search it → render it) before building UI.
3. Layer in changeCount polling, concealed/transient filtering, the hotkey, and
   the single serial queue.
4. Leave the core untouched behind its C API. Wanting to change the core is a
   signal to revisit the plan, not to reach across the boundary.
