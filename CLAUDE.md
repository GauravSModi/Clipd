# CLAUDE.md

## Project

Clipd — fast, local-first clipboard history for macOS. C++ core does the real
engineering (store, fuzzy search, crash-safe storage); a thin Swift menu-bar
shell comes later.

4-phase project, each phase gets its own approved plan cycle:
1. **C++ core** (standalone, CLI-driven) — **DONE**
2. C API boundary (`extern "C"` lib + flat header)
3. Swift shell (menu bar, pasteboard polling, hotkey)
4. Polish (eviction, persistence hardening, README/benchmarks)

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
