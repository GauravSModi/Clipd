# Handoff — Project complete

## Status

All four phases are done on `master`. Clipd is a fast, local-first macOS
clipboard manager: a C++ core (store + fuzzy search + crash-safe log) behind a
flat `extern "C"` API, driven by a thin Swift menu-bar shell.

- Phase 1 — C++ core: `git show cb65551`.
- Phase 2 — hardening + C API: `git show f4a2bbd 18e6549`.
- Phase 3 — Swift menu-bar shell: `git show f9252f7 be1a4d8 4928ea5`.
- Phase 4 — polish: `git show ffeec6d 9e64eed`.

State: **63 GoogleTest cases** + **13 ClipdKit XCTest cases** green; C++ core
clean under ASan + UBSan; ClipdKit clean under ASan + TSan; the menu-bar app
builds and was verified at runtime (capture, concealed-skip, hotkey, panel,
copy-back, ~0% idle CPU).

Re-verify anytime (full commands in `CLAUDE.md` → Build & test):
```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
ctest --test-dir build --output-on-failure
swift test
```

## What exists

- **C++ core** behind `include/clipd.h`. Coordinator pattern: `ClipStore` +
  `FuzzyMatcher` + `Log`. Crash-safe append-only log with CRC32 + torn-write
  truncation + compaction via atomic rename + replay recovery. Compaction is
  now fsync-durable (`F_FULLFSYNC` temp + directory `fsync` around the rename);
  appends are deliberately not fsync'd (see *Durability* in the README).
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

## Future work (deferred — see `prd_clipd.md` → Future work)

- **Indexed search for scale:** trie / n-gram index to take search sublinear,
  with a synthetic 1M-entry benchmark. Today's linear scan is imperceptible to
  ~50k and degrades around ~1M.
- **Encryption-at-rest:** the log is plaintext today; concealed/transient skip is
  the floor, not security. This is the real fix.
- **FuzzyMatcher scoring floor:** subsequence matching returns all in-order hits
  with no score floor (a `FuzzyMatcher`/core change with its own tests; correct
  by design per the PRD — confirm before touching the core).
- **Concurrent compaction**, image/file clipboard support, pinned/favorite
  entries, and the technical blog post.

## Invariants to hold (from CLAUDE.md — non-negotiable)

- Core is a coordinator (durability lives in `Log`); `FuzzyMatcher` is pure;
  `ClipStore` stays behind its narrow interface; recovery/eviction contract holds.
- Swift shell stays thin (UI + polling + hotkey + the one serial queue only).
- TDD: failing test first, watch it fail, then pass. Done = tests green AND both
  sanitizers clean. **Don't commit unless asked.** Wanting to change the core is
  a signal to revisit the plan, not to reach across the C API.
