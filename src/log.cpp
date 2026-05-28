#include "log.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <array>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <utility>

#include "crc32.hpp"

namespace clipd {
namespace {

constexpr size_t kHeaderSize = 8;     // uint32 length + uint32 crc32
constexpr size_t kTimestampSize = 8;  // int64 timestamp

// Flush a file's contents to stable storage. On Apple, plain fsync only pushes
// to the drive's write cache; F_FULLFSYNC forces a barrier to the platter/flash,
// which is what crash-durability actually requires. Throws on failure so a
// dropped sync never masquerades as a durable write.
void full_fsync_file(const std::filesystem::path& path) {
  int fd = ::open(path.c_str(), O_WRONLY);
  if (fd < 0) {
    throw std::runtime_error("clipd: cannot open log to fsync: " + path.string());
  }
#if defined(__APPLE__)
  int rc = ::fcntl(fd, F_FULLFSYNC);
#else
  int rc = ::fdatasync(fd);
#endif
  if (rc != 0) {
    ::close(fd);
    throw std::runtime_error("clipd: failed to fsync log: " + path.string());
  }
  if (::close(fd) != 0) {
    throw std::runtime_error("clipd: failed to close log after fsync: " + path.string());
  }
}

// fsync a directory so a rename of one of its entries is itself durable. Plain
// fsync (not F_FULLFSYNC) is the right call for directory metadata. Throws on
// failure.
void fsync_dir(const std::filesystem::path& dir) {
  int fd = ::open(dir.c_str(), O_RDONLY);
  if (fd < 0) {
    throw std::runtime_error("clipd: cannot open log directory to fsync: " +
                             dir.string());
  }
  if (::fsync(fd) != 0) {
    ::close(fd);
    throw std::runtime_error("clipd: failed to fsync log directory: " +
                             dir.string());
  }
  if (::close(fd) != 0) {
    throw std::runtime_error("clipd: failed to close log directory after fsync: " +
                             dir.string());
  }
}

// Little-endian (de)serialization, independent of host byte order.
void put_u32(std::string& out, uint32_t v) {
  for (int i = 0; i < 4; ++i) out.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
}
void put_i64(std::string& out, int64_t v) {
  auto u = static_cast<uint64_t>(v);
  for (int i = 0; i < 8; ++i) out.push_back(static_cast<char>((u >> (8 * i)) & 0xFF));
}
uint32_t get_u32(const char* p) {
  uint32_t v = 0;
  for (int i = 0; i < 4; ++i)
    v |= static_cast<uint32_t>(static_cast<unsigned char>(p[i])) << (8 * i);
  return v;
}
int64_t get_i64(const char* p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; ++i)
    v |= static_cast<uint64_t>(static_cast<unsigned char>(p[i])) << (8 * i);
  return static_cast<int64_t>(v);
}

// Serialize one record: [length][crc32][payload], payload = [timestamp][text].
std::string encode_record(const Entry& e) {
  std::string payload;
  payload.reserve(kTimestampSize + e.text.size());
  put_i64(payload, e.timestamp);
  payload.append(e.text);

  std::string record;
  record.reserve(kHeaderSize + payload.size());
  put_u32(record, static_cast<uint32_t>(payload.size()));
  put_u32(record, crc32(payload));
  record.append(payload);
  return record;
}

std::string read_file(const std::filesystem::path& path) {
  std::ifstream f(path, std::ios::binary);
  if (!f) return {};
  return std::string((std::istreambuf_iterator<char>(f)),
                     std::istreambuf_iterator<char>());
}

}  // namespace

Log::Log(std::filesystem::path path) : path_(std::move(path)) {}

void Log::open() {
  // Open for append: creates the file if missing and verifies it's writable.
  // A missing/unwritable path leaves the stream in a fail state, which we
  // surface rather than silently ignore (a dropped write must not look like a
  // success to callers up the stack).
  std::ofstream f(path_, std::ios::binary | std::ios::app);
  if (!f) {
    throw std::runtime_error("clipd: cannot open log for writing: " +
                             path_.string());
  }
}

void Log::append(const Entry& e) {
  std::ofstream f(path_, std::ios::binary | std::ios::app);
  if (!f) {
    throw std::runtime_error("clipd: cannot open log for append: " +
                             path_.string());
  }
  std::string record = encode_record(e);
  f.write(record.data(), static_cast<std::streamsize>(record.size()));
  if (!f) {
    throw std::runtime_error("clipd: failed to append to log: " +
                             path_.string());
  }
}

void Log::replay(const std::function<void(const Entry&)>& on_entry) {
  const std::string buf = read_file(path_);
  size_t pos = 0;
  size_t valid_end = 0;

  while (pos + kHeaderSize <= buf.size()) {
    uint32_t length = get_u32(buf.data() + pos);
    uint32_t stored_crc = get_u32(buf.data() + pos + 4);
    size_t payload_start = pos + kHeaderSize;

    // Torn tail: header promises more than the file holds, or a payload too
    // small to even contain the timestamp.
    if (length < kTimestampSize) break;
    if (payload_start + length > buf.size()) break;

    const char* payload = buf.data() + payload_start;
    if (crc32(std::string_view(payload, length)) != stored_crc) break;

    int64_t timestamp = get_i64(payload);
    std::string text(payload + kTimestampSize, length - kTimestampSize);
    on_entry(Entry{std::move(text), timestamp});

    pos = payload_start + length;
    valid_end = pos;
  }

  // Truncate any torn tail in place, leaving a clean, fully-valid log.
  if (valid_end < buf.size()) {
    std::filesystem::resize_file(path_, valid_end);
  }
}

void Log::compact(const std::vector<Entry>& live) {
  std::filesystem::path tmp = path_;
  tmp += ".tmp";
  {
    std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
    for (const Entry& e : live) {
      std::string record = encode_record(e);
      f.write(record.data(), static_cast<std::streamsize>(record.size()));
    }
    f.flush();
  }
  // Force the temp file's bytes to stable storage BEFORE the rename, so a crash
  // can never leave a renamed-but-unwritten (empty/partial) log in place.
  full_fsync_file(tmp);
  // Atomic replace: a crash leaves either the old or the new complete log.
  std::filesystem::rename(tmp, path_);
  // Persist the rename itself: fsync the containing directory so the new
  // directory entry survives a crash. parent_path() is empty for a bare
  // relative filename, where the directory is the current one.
  std::filesystem::path dir = path_.parent_path();
  if (dir.empty()) dir = ".";
  fsync_dir(dir);
}

uint64_t Log::size_bytes() const {
  std::error_code ec;
  auto size = std::filesystem::file_size(path_, ec);
  return ec ? 0 : size;
}

}  // namespace clipd
