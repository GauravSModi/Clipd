#include "log.hpp"

#include <array>
#include <cstring>
#include <fstream>
#include <utility>

#include "crc32.hpp"

namespace clipd {
namespace {

constexpr size_t kHeaderSize = 8;     // uint32 length + uint32 crc32
constexpr size_t kTimestampSize = 8;  // int64 timestamp

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
  if (!std::filesystem::exists(path_)) {
    std::ofstream f(path_, std::ios::binary);  // create empty
  }
}

void Log::append(const Entry& e) {
  std::ofstream f(path_, std::ios::binary | std::ios::app);
  std::string record = encode_record(e);
  f.write(record.data(), static_cast<std::streamsize>(record.size()));
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
  // Atomic replace: a crash leaves either the old or the new complete log.
  std::filesystem::rename(tmp, path_);
}

uint64_t Log::size_bytes() const {
  std::error_code ec;
  auto size = std::filesystem::file_size(path_, ec);
  return ec ? 0 : size;
}

}  // namespace clipd
