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
  own; it only wires ClipStore + FuzzyMatcher + Log together.
- **FuzzyMatcher is pure** — recency is passed in as a parameter; it never
  reaches into the store or any global state.
- **ClipStore stays behind its narrow interface** so the backing (list+map) is
  swappable for a contiguous layout without touching callers.
- **Recovery & eviction contract holds**: replay re-derives the live set in
  chronological order (never resurrects an evicted entry); raising the cap can
  recover evicted entries from the log *only before* the next compaction.
- **Swift shell stays thin** — UI, pasteboard polling, hotkey, and one serial
  `DispatchQueue` only; no dedup/scoring/storage. Every C call is serialized on
  that queue, and search results are copied into Swift values then handed back
  to `clipd_free_results` (no C++ pointer outlives the call).

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
  secure today — say so.
