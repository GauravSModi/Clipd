#include "log.hpp"

#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>

#include "crc32.hpp"
#include "durable_file.hpp"

namespace clipd {
namespace {

constexpr char kMagic[4] = {'C', 'L', 'P', 'D'};
constexpr uint32_t kVersion = 1;
constexpr size_t kHeaderSize = 8;       // 4-byte magic + uint32 version
constexpr size_t kRecordHeaderSize = 8; // uint32 length + uint32 crc32
constexpr size_t kTimestampSize = 8;    // int64 timestamp

// Record type tags. Pin/unpin/tombstone/clear are reserved for feature 2.
constexpr uint8_t kTypeText = 0;
constexpr uint8_t kTypeImage = 1;
constexpr uint8_t kTypeFile = 2;

// Smallest valid v1 body sizes (excluding the variable tail).
constexpr size_t kTextHeadSize = 1 + kTimestampSize;   // type + ts (+ text tail)
constexpr size_t kFileHeadSize = 1 + kTimestampSize;   // type + ts (+ path tail)
constexpr size_t kImageHeadSize =
    1 + kTimestampSize + 8 + 4 + 4 + 1;                // type+ts+size+w+h+fmt (+id tail)

// Little-endian (de)serialization, independent of host byte order.
void put_u8(std::string& out, uint8_t v) { out.push_back(static_cast<char>(v)); }
void put_u32(std::string& out, uint32_t v) {
  for (int i = 0; i < 4; ++i) out.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
}
void put_u64(std::string& out, uint64_t v) {
  for (int i = 0; i < 8; ++i) out.push_back(static_cast<char>((v >> (8 * i)) & 0xFF));
}
void put_i64(std::string& out, int64_t v) { put_u64(out, static_cast<uint64_t>(v)); }

uint32_t get_u32(const char* p) {
  uint32_t v = 0;
  for (int i = 0; i < 4; ++i)
    v |= static_cast<uint32_t>(static_cast<unsigned char>(p[i])) << (8 * i);
  return v;
}
uint64_t get_u64(const char* p) {
  uint64_t v = 0;
  for (int i = 0; i < 8; ++i)
    v |= static_cast<uint64_t>(static_cast<unsigned char>(p[i])) << (8 * i);
  return v;
}
int64_t get_i64(const char* p) { return static_cast<int64_t>(get_u64(p)); }

// Build a record's payload ([type][body]) for `e`.
std::string encode_payload(const Entry& e) {
  std::string body;
  switch (e.kind) {
    case Kind::Text:
      put_u8(body, kTypeText);
      put_i64(body, e.timestamp);
      body.append(e.text);
      break;
    case Kind::File:
      put_u8(body, kTypeFile);
      put_i64(body, e.timestamp);
      body.append(e.text);  // for File, text is the path
      break;
    case Kind::Image:
      put_u8(body, kTypeImage);
      put_i64(body, e.timestamp);
      put_u64(body, e.byte_size);
      put_u32(body, e.width);
      put_u32(body, e.height);
      put_u8(body, static_cast<uint8_t>(e.image_format));
      body.append(e.id);  // id (hex) is the variable tail; the blob filename
      break;
  }
  return body;
}

// Frame a payload: [length][crc32][payload].
std::string frame_record(const std::string& payload) {
  std::string record;
  record.reserve(kRecordHeaderSize + payload.size());
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

bool starts_with_magic(const std::string& buf) {
  return buf.size() >= sizeof(kMagic) &&
         std::memcmp(buf.data(), kMagic, sizeof(kMagic)) == 0;
}

// Decode one v1 payload into `out`. Returns false if the payload is structurally
// too short for its tag (treated as a torn record by replay).
bool decode_v1_payload(const char* p, size_t len, Entry& out) {
  if (len < 1) return false;
  uint8_t type = static_cast<uint8_t>(p[0]);
  switch (type) {
    case kTypeText:
      if (len < kTextHeadSize) return false;
      out.kind = Kind::Text;
      out.timestamp = get_i64(p + 1);
      out.text.assign(p + kTextHeadSize, len - kTextHeadSize);
      return true;
    case kTypeFile:
      if (len < kFileHeadSize) return false;
      out.kind = Kind::File;
      out.timestamp = get_i64(p + 1);
      out.text.assign(p + kFileHeadSize, len - kFileHeadSize);
      return true;
    case kTypeImage:
      if (len < kImageHeadSize) return false;
      out.kind = Kind::Image;
      out.timestamp = get_i64(p + 1);
      out.byte_size = get_u64(p + 1 + kTimestampSize);
      out.width = get_u32(p + 1 + kTimestampSize + 8);
      out.height = get_u32(p + 1 + kTimestampSize + 12);
      out.image_format =
          static_cast<ImageFormat>(static_cast<uint8_t>(p[1 + kTimestampSize + 16]));
      out.id.assign(p + kImageHeadSize, len - kImageHeadSize);
      return true;
    default:
      return false;  // unknown type: treat as a torn/corrupt tail
  }
}

}  // namespace

Log::Log(std::filesystem::path path) : path_(std::move(path)) {}

void Log::open() {
  std::error_code ec;
  bool exists = std::filesystem::exists(path_, ec);
  uint64_t size = exists ? std::filesystem::file_size(path_, ec) : 0;

  // A missing, empty, or sub-header-sized file holds no recoverable data (a
  // legacy v0 record is at least 16 bytes), so (re)initialize it with a v1
  // header. An existing v1 or legacy log is left untouched.
  if (!exists || size < kHeaderSize) {
    std::ofstream f(path_, std::ios::binary | std::ios::trunc);
    if (!f) {
      throw std::runtime_error("clipd: cannot open log for writing: " +
                               path_.string());
    }
    std::string header(kMagic, sizeof(kMagic));
    put_u32(header, kVersion);
    f.write(header.data(), static_cast<std::streamsize>(header.size()));
    if (!f) {
      throw std::runtime_error("clipd: failed to write log header: " +
                               path_.string());
    }
  }
}

void Log::append(const Entry& e) {
  std::ofstream f(path_, std::ios::binary | std::ios::app);
  if (!f) {
    throw std::runtime_error("clipd: cannot open log for append: " +
                             path_.string());
  }
  std::string record = frame_record(encode_payload(e));
  f.write(record.data(), static_cast<std::streamsize>(record.size()));
  if (!f) {
    throw std::runtime_error("clipd: failed to append to log: " + path_.string());
  }
}

void Log::replay(const std::function<void(const Entry&)>& on_entry) {
  const std::string buf = read_file(path_);
  const bool v1 = starts_with_magic(buf);
  size_t pos = v1 ? kHeaderSize : 0;
  size_t valid_end = pos;

  while (pos + kRecordHeaderSize <= buf.size()) {
    uint32_t length = get_u32(buf.data() + pos);
    uint32_t stored_crc = get_u32(buf.data() + pos + 4);
    size_t payload_start = pos + kRecordHeaderSize;

    if (payload_start + length > buf.size()) break;  // header promises too much
    const char* payload = buf.data() + payload_start;
    if (crc32(std::string_view(payload, length)) != stored_crc) break;

    Entry e;
    if (v1) {
      if (!decode_v1_payload(payload, length, e)) break;
    } else {
      // Legacy v0: untagged payload = [int64 timestamp][text].
      if (length < kTimestampSize) break;
      e.kind = Kind::Text;
      e.timestamp = get_i64(payload);
      e.text.assign(payload + kTimestampSize, length - kTimestampSize);
    }
    on_entry(e);

    pos = payload_start + length;
    valid_end = pos;
  }

  // Truncate any torn tail in place, never below the header for a v1 log.
  if (valid_end < buf.size()) {
    std::filesystem::resize_file(path_, valid_end);
  }
}

void Log::compact(const std::vector<Entry>& live) {
  std::filesystem::path tmp = path_;
  tmp += ".tmp";
  {
    std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
    std::string header(kMagic, sizeof(kMagic));
    put_u32(header, kVersion);
    f.write(header.data(), static_cast<std::streamsize>(header.size()));
    for (const Entry& e : live) {
      std::string record = frame_record(encode_payload(e));
      f.write(record.data(), static_cast<std::streamsize>(record.size()));
    }
    f.flush();
  }
  // Force the temp file's bytes to stable storage BEFORE the rename, so a crash
  // can never leave a renamed-but-unwritten log in place.
  full_fsync_file(tmp);
  std::filesystem::rename(tmp, path_);
  std::filesystem::path dir = path_.parent_path();
  if (dir.empty()) dir = ".";
  fsync_dir(dir);
}

bool Log::is_legacy() const {
  const std::string buf = read_file(path_);
  return !buf.empty() && !starts_with_magic(buf);
}

uint64_t Log::size_bytes() const {
  std::error_code ec;
  auto size = std::filesystem::file_size(path_, ec);
  return ec ? 0 : size;
}

}  // namespace clipd
