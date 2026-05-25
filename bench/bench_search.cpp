// Benchmark: fuzzy search latency over a populated store, plus peak memory.
// Numbers feed the README (Phase 4). Validates the PRD target: <1ms over 10k.

#include <sys/resource.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <random>
#include <string>
#include <vector>

#include "core.hpp"

namespace {

namespace fs = std::filesystem;

std::string synthetic_entry(std::mt19937& rng, int i) {
  static const char* words[] = {"alpha",  "beta",   "gamma",  "delta",
                                 "config", "server", "client", "module",
                                 "handle", "buffer", "render", "commit"};
  std::uniform_int_distribution<int> pick(0, 11);
  return std::string(words[pick(rng)]) + "_" + words[pick(rng)] + "_" +
         std::to_string(i);
}

double bench_one_size(size_t n) {
  fs::path log = fs::temp_directory_path() / ("clipd_bench_" + std::to_string(n));
  fs::remove(log);

  std::mt19937 rng(1234);
  clipd::Core core(log, n + 1, 1ull << 40 /* no auto-compact */);
  core.start();
  for (size_t i = 0; i < n; ++i) {
    core.add(synthetic_entry(rng, static_cast<int>(i)), static_cast<int64_t>(i));
  }

  const std::vector<std::string> queries = {"cfg", "srvr", "mod", "hbf",
                                            "rndr", "ab",  "dlt", "cmt"};
  constexpr int kReps = 200;
  std::vector<double> samples;
  samples.reserve(kReps * queries.size());

  for (int r = 0; r < kReps; ++r) {
    for (const auto& q : queries) {
      auto t0 = std::chrono::high_resolution_clock::now();
      auto results = core.search(q, 20, static_cast<int64_t>(n));
      auto t1 = std::chrono::high_resolution_clock::now();
      samples.push_back(
          std::chrono::duration<double, std::milli>(t1 - t0).count());
      asm volatile("" ::"r"(results.size()) : "memory");  // don't optimize away
    }
  }

  std::sort(samples.begin(), samples.end());
  double sum = 0;
  for (double s : samples) sum += s;
  double mean = sum / samples.size();
  double p50 = samples[samples.size() / 2];
  double p99 = samples[(samples.size() * 99) / 100];

  std::printf("  n=%-6zu  mean=%.4f ms  p50=%.4f ms  p99=%.4f ms\n", n, mean,
              p50, p99);
  fs::remove(log);
  return mean;
}

}  // namespace

int main() {
  std::printf("clipd fuzzy-search benchmark (subsequence scan + scoring)\n");
  bench_one_size(10000);
  bench_one_size(50000);

  struct rusage ru{};
  getrusage(RUSAGE_SELF, &ru);
  // macOS reports ru_maxrss in bytes; Linux in kilobytes.
#if defined(__APPLE__)
  double peak_mb = static_cast<double>(ru.ru_maxrss) / (1024.0 * 1024.0);
#else
  double peak_mb = static_cast<double>(ru.ru_maxrss) / 1024.0;
#endif
  std::printf("peak resident memory: %.1f MB\n", peak_mb);
  return 0;
}
