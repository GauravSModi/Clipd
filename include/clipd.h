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
 * Text encoding: `text`/`path` arguments and the `text`/`id` result fields are
 * NUL-terminated C strings (matched as bytes; matching is ASCII-oriented
 * upstream). An embedded NUL truncates the string. Binary image payloads use the
 * length-carrying calls (clipd_add_image / clipd_read_blob) instead.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to a clipboard-history core instance. */
typedef struct ClipdCore ClipdCore;

/* What a captured entry holds. */
typedef enum {
  CLIPD_TEXT = 0,
  CLIPD_IMAGE = 1, /* bytes live in the blob store; fetch with clipd_read_blob */
  CLIPD_FILE = 2,  /* a file reference; `text` is the path */
} ClipdKind;

/* Image encoding, so the shell can write the right pasteboard type on paste-back. */
typedef enum {
  CLIPD_IMAGE_PNG = 0,
  CLIPD_IMAGE_TIFF = 1,
} ClipdImageFormat;

/* One search hit. `text` and `id` point into the owning ClipdResults block and
 * are valid only until clipd_free_results() is called on that result set.
 *   text  — display string: the text (TEXT), the path (FILE), or a synthesized
 *           label like "image 1024x768 png" (IMAGE).
 *   id    — sha256-hex identity; for an IMAGE it is also the blob key to pass to
 *           clipd_read_blob().
 *   byte_size — blob byte size (IMAGE) or text/path length, for display/quotas.
 *   width/height — image pixel dimensions (0 for non-image). */
typedef struct {
  const char* text;    /* NUL-terminated, owned by the ClipdResults block */
  const char* id;      /* NUL-terminated, owned by the ClipdResults block */
  int64_t timestamp;   /* epoch milliseconds */
  uint64_t byte_size;
  float score;         /* higher ranks better */
  ClipdKind kind;
  uint32_t width;
  uint32_t height;
} ClipdMatch;

/* A search result set: allocated as a single block by clipd_search() and freed
 * in one call by clipd_free_results(). */
typedef struct {
  ClipdMatch* matches;  /* `count` elements, best-first */
  size_t count;
} ClipdResults;

/* Store/log statistics. */
typedef struct {
  size_t entry_count;   /* live entries in the store */
  uint64_t log_bytes;   /* on-disk log size */
  uint64_t store_bytes; /* summed byte_size of the live set (byte-budget usage) */
} ClipdStats;

/*
 * Create a core backed by `log_path` and start it (open + replay + maybe
 * compact/migrate). `max_entries` caps the live count; `max_bytes` caps the
 * summed byte_size of the live set (0 = unbounded); `max_blob_bytes` rejects a
 * single image larger than the cap (0 = no per-image limit);
 * `compact_threshold_bytes` is the log size above which start() compacts. Image
 * blobs live alongside the log in a sibling "<log_path>.blobs" directory.
 *
 * Returns a handle the caller must release with clipd_destroy(), or NULL on
 * failure (e.g. the log path is not writable, or replay failed).
 */
ClipdCore* clipd_create(const char* log_path, size_t max_entries,
                        uint64_t compact_threshold_bytes, uint64_t max_bytes,
                        uint64_t max_blob_bytes);

/* Destroy a handle from clipd_create(). NULL is a safe no-op. */
void clipd_destroy(ClipdCore* core);

/*
 * Record a copy of `text` stamped at `timestamp_ms` (epoch ms). The record is
 * made durable before the in-memory store is updated, so a failed write leaves
 * the store unchanged. Returns 0 on success, nonzero on failure.
 */
int clipd_add(ClipdCore* core, const char* text, int64_t timestamp_ms);

/*
 * Record an image copy of `len` bytes (`data`) stamped at `timestamp_ms`. The
 * caller supplies pixel `width`/`height` and `image_format` (a ClipdImageFormat)
 * — the core never decodes the image. The bytes are written to the blob store
 * (content-addressed, durable) before the referencing record, and an identical
 * image is deduplicated. Returns 0 on success, nonzero on failure. An image
 * larger than the configured per-image cap is silently skipped (returns 0).
 */
int clipd_add_image(ClipdCore* core, const uint8_t* data, size_t len,
                    uint32_t width, uint32_t height, int image_format,
                    int64_t timestamp_ms);

/*
 * Record a file copy by reference: `path` is stored, the file's contents are
 * not. Returns 0 on success, nonzero on failure.
 */
int clipd_add_file(ClipdCore* core, const char* path, int64_t timestamp_ms);

/*
 * Fetch the bytes of the blob identified by `id` (an IMAGE match's `id`). On
 * success returns a freshly allocated buffer of *out_len bytes that the caller
 * MUST release with clipd_free_blob(); on failure (unknown id, malformed id, or
 * allocation failure) returns NULL and leaves *out_len untouched.
 */
const uint8_t* clipd_read_blob(ClipdCore* core, const char* id, size_t* out_len);

/* Free a buffer returned by clipd_read_blob(). NULL is a safe no-op. */
void clipd_free_blob(const uint8_t* blob);

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
