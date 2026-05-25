#include "fuzzy_matcher.hpp"

#include <algorithm>

namespace clipd::fuzzy {
namespace {

// Scoring weights. Tuned by the ordering properties asserted in the tests, not
// by exact magnitudes.
constexpr float kMatchCredit = 1.0f;
constexpr float kContiguityBonus = 1.5f;
constexpr float kBoundaryBonus = 2.0f;
constexpr float kPositionPenaltyPerChar = 0.05f;
constexpr float kMaxPositionPenalty = 0.9f;  // keep total score positive
constexpr float kRecencyWeight = 0.5f;
constexpr float kEmptyQueryBase = 1.0f;  // lets recency order an empty query

// ASCII-only helpers. Bytes >= 0x80 are treated as ordinary characters: not
// letters, not separators. This keeps UTF-8 multibyte sequences from being
// split or misclassified — we never decode code points, only inspect bytes.
bool is_ascii(unsigned char c) { return c < 0x80; }

bool is_ascii_alnum(unsigned char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
         (c >= 'A' && c <= 'Z');
}

bool is_ascii_lower(unsigned char c) { return c >= 'a' && c <= 'z'; }
bool is_ascii_upper(unsigned char c) { return c >= 'A' && c <= 'Z'; }

unsigned char ascii_lower(unsigned char c) {
  return is_ascii_upper(c) ? static_cast<unsigned char>(c - 'A' + 'a') : c;
}

bool chars_match(unsigned char a, unsigned char b) {
  return ascii_lower(a) == ascii_lower(b);
}

// A boundary is the start of a word/segment: index 0, a character following an
// ASCII separator (any non-alphanumeric ASCII byte), or a lower->Upper ASCII
// transition (camelCase). Non-ASCII bytes are never boundaries.
bool is_boundary(std::string_view s, size_t i) {
  if (i == 0) return true;
  unsigned char prev = static_cast<unsigned char>(s[i - 1]);
  unsigned char cur = static_cast<unsigned char>(s[i]);
  if (is_ascii(prev) && !is_ascii_alnum(prev)) return true;  // after separator
  if (is_ascii_lower(prev) && is_ascii_upper(cur)) return true;  // camelCase
  return false;
}

}  // namespace

std::optional<float> score(std::string_view query, std::string_view candidate,
                           float recency_factor) {
  auto with_recency = [&](float base) {
    return base * (1.0f + kRecencyWeight * recency_factor);
  };

  if (query.empty()) {
    return with_recency(kEmptyQueryBase);
  }

  float base = 0.0f;
  size_t qi = 0;
  size_t first_match = 0;
  bool have_first = false;
  size_t prev_match_index = 0;
  bool have_prev = false;

  for (size_t ci = 0; ci < candidate.size() && qi < query.size(); ++ci) {
    if (!chars_match(static_cast<unsigned char>(query[qi]),
                     static_cast<unsigned char>(candidate[ci]))) {
      continue;
    }
    base += kMatchCredit;
    if (!have_first) {
      first_match = ci;
      have_first = true;
    }
    if (have_prev && ci == prev_match_index + 1) {
      base += kContiguityBonus;
    }
    if (is_boundary(candidate, ci)) {
      base += kBoundaryBonus;
    }
    prev_match_index = ci;
    have_prev = true;
    ++qi;
  }

  if (qi != query.size()) {
    return std::nullopt;  // not a subsequence
  }

  float penalty = std::min(static_cast<float>(first_match) * kPositionPenaltyPerChar,
                           kMaxPositionPenalty);
  base -= penalty;
  return with_recency(base);
}

}  // namespace clipd::fuzzy
