#include "blob_store.hpp"

#include <fstream>
#include <stdexcept>
#include <utility>

#include "durable_file.hpp"

namespace clipd {
namespace {

// A blob id is always a 64-char lowercase-hex sha256 digest. Validating before
// using it as a filename keeps a malformed/hostile id (the read id can arrive
// from outside via the C API) from escaping the blob directory.
bool is_valid_id(const std::string& id) {
  if (id.size() != 64) return false;
  for (char c : id) {
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  }
  return true;
}

std::string read_file(const std::filesystem::path& path) {
  std::ifstream f(path, std::ios::binary);
  return std::string((std::istreambuf_iterator<char>(f)),
                     std::istreambuf_iterator<char>());
}

}  // namespace

BlobStore::BlobStore(std::filesystem::path dir) : dir_(std::move(dir)) {}

void BlobStore::open() { std::filesystem::create_directories(dir_); }

void BlobStore::put(const std::string& id, const uint8_t* data, size_t len) {
  if (!is_valid_id(id)) {
    throw std::runtime_error("clipd: refusing to store blob with invalid id");
  }
  std::filesystem::path final_path = dir_ / id;
  if (std::filesystem::exists(final_path)) return;  // write-once dedup

  std::filesystem::create_directories(dir_);
  std::filesystem::path tmp = dir_ / (id + ".tmp");
  {
    std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
    if (!f) {
      throw std::runtime_error("clipd: cannot open blob temp for writing");
    }
    f.write(reinterpret_cast<const char*>(data), static_cast<std::streamsize>(len));
    f.flush();
    if (!f) throw std::runtime_error("clipd: failed to write blob");
  }
  // Durable before the rename, then persist the rename via a directory fsync —
  // same contract as the log's compaction.
  full_fsync_file(tmp);
  std::filesystem::rename(tmp, final_path);
  fsync_dir(dir_);
}

bool BlobStore::exists(const std::string& id) const {
  if (!is_valid_id(id)) return false;
  return std::filesystem::is_regular_file(dir_ / id);
}

std::optional<std::string> BlobStore::get(const std::string& id) const {
  if (!exists(id)) return std::nullopt;
  return read_file(dir_ / id);
}

void BlobStore::gc(const std::unordered_set<std::string>& live_ids) {
  std::error_code ec;
  if (!std::filesystem::is_directory(dir_, ec)) return;
  for (const auto& entry : std::filesystem::directory_iterator(dir_, ec)) {
    if (!entry.is_regular_file()) continue;
    const std::string name = entry.path().filename().string();
    // Reclaim a stray temp file (interrupted put) or any blob not in the live
    // set.
    if (name.size() > 4 && name.substr(name.size() - 4) == ".tmp") {
      std::filesystem::remove(entry.path(), ec);
    } else if (live_ids.find(name) == live_ids.end()) {
      std::filesystem::remove(entry.path(), ec);
    }
  }
}

}  // namespace clipd
