#ifndef CLIPD_H
#define CLIPD_H

/*
 * clipd — flat C API over the C++ clipboard-history core.
 *
 * Memory ownership (inviolable): the C++ side owns every allocation it returns
 * and is the only side that frees it. Do NOT free a ClipdResults (or any `text`
 * pointer inside it) with your own allocator; hand it back to
 * clipd_free_results(). The two sides may use different allocators, so freeing
 * across the boundary is undefined behavior.
 *
 * Threading: a ClipdCore is NOT thread-safe and holds no locks by design. The
 * caller must serialize every call against a given handle onto one queue (the
 * Swift shell drives all calls — including compaction — from a single serial
 * dispatch queue). Concurrent calls on the same handle are undefined behavior.
 *
 * Errors: no C++ exception ever crosses this boundary. Pointer-returning calls
 * yield NULL on failure; int-returning calls yield nonzero on failure.
 *
 * Text encoding: `text` arguments and results are NUL-terminated C strings
 * (matched as bytes; matching is ASCII-oriented upstream). An embedded NUL
 * truncates the string. A binary-safe, length-carrying API is Future Work.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a clipboard-history core instance. */
typedef struct ClipdCore ClipdCore;

/* One search hit. `text` points into the owning ClipdResults block and is valid
 * only until clipd_free_results() is called on that result set. */
typedef struct {
  const char* text;   /* NUL-terminated, owned by the ClipdResults block */
  int64_t timestamp;  /* epoch milliseconds */
  float score;        /* higher ranks better */
} ClipdMatch;

/* A search result set: allocated as a single block by clipd_search() and freed
 * in one call by clipd_free_results(). */
typedef struct {
  ClipdMatch* matches;  /* `count` elements, best-first */
  size_t count;
} ClipdResults;

/* Store/log statistics. */
typedef struct {
  size_t entry_count;  /* live entries in the store */
  uint64_t log_bytes;  /* on-disk log size */
} ClipdStats;

/*
 * Create a core backed by `log_path` and start it (open + replay + maybe
 * compact). `max_entries` caps the live set; `compact_threshold_bytes` is the
 * log size above which start() compacts.
 *
 * Returns a handle the caller must release with clipd_destroy(), or NULL on
 * failure (e.g. the log path is not writable, or replay failed).
 */
ClipdCore* clipd_create(const char* log_path, size_t max_entries,
                        uint64_t compact_threshold_bytes);

/* Destroy a handle from clipd_create(). NULL is a safe no-op. */
void clipd_destroy(ClipdCore* core);

/*
 * Record a copy of `text` stamped at `timestamp_ms` (epoch ms). The record is
 * made durable before the in-memory store is updated, so a failed write leaves
 * the store unchanged. Returns 0 on success, nonzero on failure.
 */
int clipd_add(ClipdCore* core, const char* text, int64_t timestamp_ms);

/*
 * Return up to `max_results` entries matching `query`, best-first, scoring
 * recency relative to `now_ms` (epoch ms). An empty query returns the most
 * recent entries.
 *
 * Returns a result set the caller must release with clipd_free_results(), or
 * NULL on failure. A successful search with no matches returns a non-NULL
 * result with count == 0 — distinct from the NULL failure case.
 */
ClipdResults* clipd_search(ClipdCore* core, const char* query,
                           size_t max_results, int64_t now_ms);

/* Free a result set from clipd_search() (a single free of the block). NULL is a
 * safe no-op. */
void clipd_free_results(ClipdResults* results);

/* Rewrite the log to exactly the live set. Returns 0 on success, nonzero on
 * failure. */
int clipd_compact(ClipdCore* core);

/* Fill *out with current statistics. Returns 0 on success, nonzero on failure
 * (including a NULL argument). */
int clipd_stats(ClipdCore* core, ClipdStats* out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CLIPD_H */
