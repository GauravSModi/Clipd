#include "fuzzy_matcher.hpp"

#include <gtest/gtest.h>

using clipd::fuzzy::score;

TEST(FuzzyMatcher, MatchesSubsequence) {
  EXPECT_TRUE(score("abc", "aXbXc", 0.0f).has_value());
}

TEST(FuzzyMatcher, RejectsNonSubsequence) {
  EXPECT_FALSE(score("xyz", "abc", 0.0f).has_value());
}

TEST(FuzzyMatcher, RejectsOutOfOrder) {
  // 'c' before 'a' is not a subsequence of "abc".
  EXPECT_FALSE(score("ca", "abc", 0.0f).has_value());
}

TEST(FuzzyMatcher, IsCaseInsensitive) {
  EXPECT_TRUE(score("ABC", "abc", 0.0f).has_value());
  EXPECT_TRUE(score("abc", "ABC", 0.0f).has_value());
}

TEST(FuzzyMatcher, EmptyQueryMatchesAnything) {
  EXPECT_TRUE(score("", "anything", 0.0f).has_value());
  EXPECT_TRUE(score("", "", 0.0f).has_value());
}

TEST(FuzzyMatcher, ContiguousBeatsScattered) {
  auto contiguous = score("abc", "abcde", 0.0f);
  auto scattered = score("abc", "axbxc", 0.0f);
  ASSERT_TRUE(contiguous && scattered);
  EXPECT_GT(*contiguous, *scattered);
}

TEST(FuzzyMatcher, WordBoundaryBeatsMidWord) {
  // Same query, same match position (index 2); only boundary status differs.
  auto boundary = score("f", "x_file", 0.0f);   // 'f' follows a separator
  auto mid_word = score("f", "xxfile", 0.0f);   // 'f' is mid-word
  ASSERT_TRUE(boundary && mid_word);
  EXPECT_GT(*boundary, *mid_word);
}

TEST(FuzzyMatcher, CamelCaseBoundaryBeatsMidWord) {
  auto camel = score("f", "myFile", 0.0f);   // lower->Upper transition at 'F'
  auto mid_word = score("f", "myfile", 0.0f);
  ASSERT_TRUE(camel && mid_word);
  EXPECT_GT(*camel, *mid_word);
}

TEST(FuzzyMatcher, EarlierPositionBeatsLater) {
  // Same candidate length; both 'a's are at a boundary, so position decides.
  auto early = score("a", "a___", 0.0f);
  auto late = score("a", "___a", 0.0f);
  ASSERT_TRUE(early && late);
  EXPECT_GT(*early, *late);
}

TEST(FuzzyMatcher, HigherRecencyBeatsLowerForEqualMatch) {
  auto recent = score("ab", "ab", 1.0f);
  auto old = score("ab", "ab", 0.0f);
  ASSERT_TRUE(recent && old);
  EXPECT_GT(*recent, *old);
}

TEST(FuzzyMatcher, HandlesMultibyteCandidateWithoutCorruption) {
  // "café" is c,a,f,<0xC3><0xA9>. ASCII subsequence "caf" should still match,
  // and a multibyte byte must not crash or be split.
  EXPECT_TRUE(score("caf", "caf\xC3\xA9", 0.0f).has_value());
  EXPECT_TRUE(score("cf", "caf\xC3\xA9", 0.0f).has_value());
  // A non-ASCII byte is treated as an ordinary, non-boundary character: a query
  // requiring a byte not present must not match.
  EXPECT_FALSE(score("z", "caf\xC3\xA9", 0.0f).has_value());
}
