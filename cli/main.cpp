// clipd-cli: a scriptable front-end to the clipd core, used for manual
// exploration, the torn-write recovery demo, and benchmarking. All real logic
// lives in (and is tested through) the core library; this is a thin adapter.

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core.hpp"
#include "entry.hpp"
#include "log.hpp"

namespace {

constexpr size_t kDefaultMaxEntries = 10000;
constexpr uint64_t kDefaultCompactThreshold = 4ull * 1024 * 1024;  // 4 MiB

int64_t now_ms() {
  using namespace std::chrono;
  return duration_cast<milliseconds>(system_clock::now().time_since_epoch())
      .count();
}

const char* kind_str(clipd::Kind kind) {
  switch (kind) {
    case clipd::Kind::Image:
      return "image";
    case clipd::Kind::File:
      return "file";
    case clipd::Kind::Text:
    default:
      return "text";
  }
}

std::string read_file_bytes(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  return std::string((std::istreambuf_iterator<char>(f)),
                     std::istreambuf_iterator<char>());
}

[[noreturn]] void usage() {
  std::cerr <<
      "usage: clipd-cli --log <path> <command> [args]\n"
      "  add \"<text>\"                 capture a text copy\n"
      "  add-file <path>               capture a file copy (by reference)\n"
      "  add-image <path> [--width N] [--height N] [--format png|tiff]\n"
      "                                capture a file's bytes as an image\n"
      "  read-blob <id>                write a blob's bytes to stdout\n"
      "  pin <id>                      pin (favorite) an entry by id\n"
      "  unpin <id>                    unpin an entry by id\n"
      "  delete <id>                   delete an entry by id\n"
      "  clear                         clear history, keeping pinned entries\n"
      "  search \"<query>\" [--max N] [--now <ms>]\n"
      "  list [--max N]                show N most-recent entries\n"
      "  compact                       rewrite the log to the live set\n"
      "  stats                         entry count, log size, store bytes\n"
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

// Columns: timestamp, kind, pinned (1/0), id, score, text.
void print_results(const std::vector<clipd::ScoredEntry>& results) {
  for (const auto& r : results) {
    std::cout << r.entry.timestamp << '\t' << kind_str(r.entry.kind) << '\t'
              << (r.entry.pinned ? 1 : 0) << '\t' << r.entry.id << '\t' << r.score
              << '\t' << r.entry.text << '\n';
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

  if (command == "add-file") {
    if (args.empty()) usage();
    core.start();
    core.add_file(args[0], now_ms());
    return 0;
  }

  if (command == "add-image") {
    auto width = take_flag(args, "--width");
    auto height = take_flag(args, "--height");
    auto format = take_flag(args, "--format");
    if (args.empty()) usage();
    std::string bytes = read_file_bytes(args[0]);
    clipd::ImageFormat fmt = (format && *format == "tiff")
                                 ? clipd::ImageFormat::Tiff
                                 : clipd::ImageFormat::Png;
    core.start();
    core.add_image(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(),
                   width ? static_cast<uint32_t>(std::stoul(*width)) : 0,
                   height ? static_cast<uint32_t>(std::stoul(*height)) : 0, fmt,
                   now_ms());
    return 0;
  }

  if (command == "read-blob") {
    if (args.empty()) usage();
    core.start();
    auto bytes = core.read_blob(args[0]);
    if (!bytes) {
      std::cerr << "no blob for id: " << args[0] << '\n';
      return 1;
    }
    std::cout.write(bytes->data(), static_cast<std::streamsize>(bytes->size()));
    return 0;
  }

  if (command == "pin" || command == "unpin") {
    if (args.empty()) usage();
    core.start();
    core.set_pinned(args[0], command == "pin");
    return 0;
  }

  if (command == "delete") {
    if (args.empty()) usage();
    core.start();
    core.remove(args[0]);
    return 0;
  }

  if (command == "clear") {
    core.start();
    core.clear();
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
              << "\nstore_bytes: " << s.store_bytes << '\n';
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
