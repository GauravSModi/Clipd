#pragma once

#include <optional>
#include <string_view>

namespace clipd::fuzzy {

// Score `candidate` against `query` using a subsequence match with a quality
// heuristic (contiguity, word/camelCase boundary, and position), then fold in
// recency.
//
// Returns std::nullopt iff `query` is not a (case-insensitive) subsequence of
// `candidate`. Higher scores rank better.
//
// Purity: this function depends only on its arguments. `recency_factor`
// (expected in [0, 1], where 1 == most recent) is supplied by the caller; the
// matcher never reaches into any store.
//
// ASCII-only (v1): case-folding and boundary detection target ASCII. Bytes
// >= 0x80 are treated as ordinary, non-boundary characters and matched
// byte-for-byte, so UTF-8 multibyte sequences are never split or misclassified.
// Full Unicode handling is Future Work.
std::optional<float> score(std::string_view query, std::string_view candidate,
                           float recency_factor);

}  // namespace clipd::fuzzy
