# Handoff — Phase 4 (Polish)

## Goal

Phases 1–3 are done: the C++ core, the `extern "C"` C API, and a working Swift
menu-bar app are all on `master`. Phase 4 is **polish** — make the project
portfolio-ready and tie off the rough edges. Per `prd_clipd.md` → *Phases*:
"eviction, persistence hardening, README with benchmarks and a recovery demo."

Phase 4 must start from an **approved plan** (CLAUDE.md workflow rule). Don't
write code before that plan exists. If a request conflicts with the PRD, **flag
it** rather than silently resolving it. Authoritative spec sections for Phase 4:
*Success metrics*, *Quality bar*, *Portfolio optimization*, *Future work*, and
*Functional requirements* (esp. FR6 eviction).

## Current progress

- Phases 1–3 complete on `master`:
  - Phase 1 core: `git show cb65551`.
  - Phase 2 hardening + C API: `git show f4a2bbd 18e6549`.
  - Phase 3 Swift shell: `git show f9252f7 be1a4d8 4928ea5`.
- State: **57 GoogleTest cases** + **13 ClipdKit XCTest cases** green; C++ core
  clean under ASan + UBSan; ClipdKit clean under ASan + TSan; the menu-bar app
  builds and was verified at runtime (capture, concealed-skip, hotkey, panel,
  copy-back, ~0% idle CPU).
- Re-verify anytime (full commands in `CLAUDE.md` → Build & test):
  ```sh
  cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
  ctest --test-dir build --output-on-failure
  swift test
  ```

## What exists now (build on this; don't rebuild it)

- **C++ core** behind `include/clipd.h` (moved there in Phase 3). Coordinator
  pattern: `ClipStore` + `FuzzyMatcher` + `Log`. Crash-safe append-only log with
  CRC32 + torn-write truncation + compaction via atomic rename + replay recovery.
- **ClipdKit** (`shell/ClipdKit/`, a SwiftPM library — `Package.swift` at root):
  - `Clipboard` — the C-API bridge: one serial `DispatchQueue` for every call,
    copy-out-then-free for search results, NULL-vs-`count==0`, stats/compact.
  - `PasteboardMonitor` — changeCount polling + concealed/transient skip (behind
    `PasteboardReading`; `SystemPasteboard` is the real adapter).
  - `HistoryController` — ingest glue + in-session compaction past the threshold.
- **Menu-bar app** (`shell/Clipd/`, Xcode target from `project.yml`): status item
  (+ right-click Quit), unified SwiftUI search panel, `KeyboardShortcuts` hotkey
  (⌘⇧V default), `LSUIElement` agent. Log lives at
  `~/Library/Application Support/Clipd/clipd.log`; defaults `max_entries=10000`,
  compact threshold 4 MB, poll 0.5 s.

## Build/tooling notes (Phase 3 set these up)

- Installed via Homebrew: `cmake` 4.3.3, `xcodegen` 2.45.4. Full **Xcode 26.5**
  is installed and selected. `/opt/homebrew/bin` may not be on the default PATH
  — prefix it (`export PATH="/opt/homebrew/bin:$PATH"`) for cmake/xcodegen.
- `swift test` links the CMake archives in `build/`, so **populate `build/`
  first** (`cmake --build build`). The app's xcodebuild has a pre-build phase
  that runs cmake automatically.
- `Clipd.xcodeproj` is **generated** (`xcodegen generate`) and **gitignored**;
  `project.yml` is the checked-in source of truth.
- `CMAKE_OSX_DEPLOYMENT_TARGET` is pinned to 13.0 (set before `project()`); keep
  it in sync with `Package.swift`'s `.macOS(.v13)` or the linker warns.
- A Phase-3 fix: `clipd_bench` now gets `clipd_apply_sanitizer` so an all-targets
  sanitizer build links (it didn't before).

## Phase 4 scope — likely work items (resolve in the plan)

1. **README + benchmarks + recovery demo** (highest portfolio value — PRD calls
   the torn-write recovery demo "the single strongest selling point").
   - Real numbers from a **Release** `./build/clipd_bench` (search latency over
     10k+; Debug numbers are ~10× off — meaningless).
   - Recovery demo via `./scripts/torn_write_demo.sh ./build/clipd-cli` — embed
     terminal output or a GIF.
   - Memory footprint at 10k entries; idle CPU (measured ~0% in Phase 3).
   - Honest framing: ASCII-only matching; plaintext storage (concealed/transient
     skip is the floor, not security). Don't overclaim.
2. **Eviction** (FR6 "configurable max history size with automatic eviction").
   - **Check what the core already does** — `max_entries` is passed through
     `clipd_create`, and the eviction/recovery contract is already an invariant
     (see CLAUDE.md). This may mostly need *verification + tests + exposing
     configurability*, not new core logic. Confirm before planning new code.
3. **Persistence hardening** — more crash/recovery edge-case tests, review fsync
   /durability policy, stress the compaction path. Stay behind the C API.
4. **Scoring-quality tweak** (surfaced in Phase 3, optional polish). Subsequence
   matching returns *all* in-order matches with no score floor, so a query like
   `after` also matches "type a few letters" (scattered: a-f-t-e-r in order),
   ranked below the contiguous hit. This is **correct by design** (PRD locks
   subsequence matching) — see `src/fuzzy_matcher.cpp:91` (`nullopt` only when
   not a subsequence). If you want to suppress weak matches, that's a
   `FuzzyMatcher`/core change (min-score floor or contiguity re-weighting) with
   its own tests — a naive relative cutoff won't cleanly fix that case (~69% of
   the top score). Confirm the user wants this before touching the core.

## Invariants to hold (from CLAUDE.md — non-negotiable)

- Core is a coordinator; `FuzzyMatcher` is pure; `ClipStore` stays behind its
  narrow interface; recovery/eviction contract holds.
- Swift shell stays thin (UI + polling + hotkey + the one serial queue only).
- TDD: failing test first, watch it fail, then pass. Done = tests green AND both
  sanitizers clean. **Don't commit unless asked. Don't start a phase without an
  approved plan.** Wanting to change the core is a signal to revisit the plan,
  not to reach across the C API.

## Gotchas (carry forward)

- Always benchmark a **Release** build; Debug is ~10× off.
- `.claude/settings.local.json`, `build/`, `build-*/`, `.build/`,
  `Clipd.xcodeproj/`, and the root `compile_commands.json` symlink are gitignored
  — keep them out of commits.
- The menu-bar app is an agent (no Dock icon); quit it via the status item's
  right-click → Quit, or `killall Clipd`.

## Next steps

1. Brainstorm Phase 4 against the PRD; surface conflicts; get the plan approved.
2. Lead with the README/benchmarks/recovery demo (most portfolio value), then the
   eviction verification, persistence hardening, and (if the user wants it) the
   scoring tweak.
3. Keep the core green behind its C API and the shell thin. A change is done only
   when tests are green and both sanitizers are clean.
