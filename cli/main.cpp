// clipd-cli: a scriptable front-end to the clipd core, used for manual
// exploration, the torn-write recovery demo, and benchmarking. All real logic
// lives in (and is tested through) the core library; this is a thin adapter.

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core.hpp"
#include "log.hpp"

namespace {

constexpr size_t kDefaultMaxEntries = 10000;
constexpr uint64_t kDefaultCompactThreshold = 4ull * 1024 * 1024;  // 4 MiB

int64_t now_ms() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(system_clock::now().time_since_epoch())
      .count();
}

[[noreturn]] void usage() {
  std::cerr <<
      "usage: clipd-cli --log <path> <command> [args]\n"
      "  add \"<text>\"                 capture a copy\n"
      "  search \"<query>\" [--max N] [--now <ms>]\n"
      "  list [--max N]                show N most-recent entries\n"
      "  compact                       rewrite the log to the live set\n"
      "  stats                         entry count and log size\n"
      "  replay                        validate the log, report any truncation\n";
  std::exit(2);
}

// Pull "--flag value" pairs out of args, returning the value if present.
std::optional<std::string> take_flag(std::vector<std::string>& args,
                                     std::string_view flag) {
  for (size_t i = 0; i + 1 < args.size(); ++i) {
    if (args[i] == flag) {
      std::string value = args[i + 1];
      args.erase(args.begin() + i, args.begin() + i + 2);
      return value;
    }
  }
  return std::nullopt;
}

void print_results(const std::vector<clipd::ScoredEntry>& results) {
  for (const auto& r : results) {
    std::cout << r.entry.timestamp << '\t' << r.score << '\t' << r.entry.text
              << '\n';
  }
}

}  // namespace

int main(int argc, char** argv) {
  std::vector<std::string> args(argv + 1, argv + argc);

  auto log_path = take_flag(args, "--log");
  if (!log_path || args.empty()) usage();

  const std::string command = args[0];
  args.erase(args.begin());

  clipd::Core core(*log_path, kDefaultMaxEntries, kDefaultCompactThreshold);

  if (command == "add") {
    if (args.empty()) usage();
    core.start();
    core.add(args[0], now_ms());
    return 0;
  }

  if (command == "search") {
    auto max = take_flag(args, "--max");
    auto now = take_flag(args, "--now");
    if (args.empty()) usage();
    core.start();
    print_results(core.search(args[0],
                              max ? std::stoul(*max) : 20,
                              now ? std::stoll(*now) : now_ms()));
    return 0;
  }

  if (command == "list") {
    auto max = take_flag(args, "--max");
    core.start();
    print_results(core.search("", max ? std::stoul(*max) : 20, now_ms()));
    return 0;
  }

  if (command == "compact") {
    core.start();
    uint64_t before = core.stats().log_bytes;
    core.compact();
    uint64_t after = core.stats().log_bytes;
    std::cout << "compacted: " << before << " -> " << after << " bytes\n";
    return 0;
  }

  if (command == "stats") {
    core.start();
    auto s = core.stats();
    std::cout << "entries: " << s.entry_count << "\nlog_bytes: " << s.log_bytes
              << '\n';
    return 0;
  }

  if (command == "replay") {
    // Report raw valid-record count and whether a torn tail was truncated.
    clipd::Log log(*log_path);
    log.open();
    uint64_t before = log.size_bytes();
    size_t valid = 0;
    log.replay([&](const clipd::Entry&) { ++valid; });
    uint64_t after = log.size_bytes();
    std::cout << "valid records: " << valid << '\n';
    if (after < before) {
      std::cout << "truncated torn tail: " << before << " -> " << after
                << " bytes\n";
    } else {
      std::cout << "log clean (no truncation)\n";
    }
    return 0;
  }

  usage();
}
