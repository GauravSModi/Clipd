#pragma once

#include <filesystem>

namespace clipd {

// Force a file's contents to stable storage. On Apple, plain fsync only pushes
// to the drive's write cache; F_FULLFSYNC forces a barrier to the platter/flash,
// which is what crash-durability actually requires. Throws on failure so a
// dropped sync never masquerades as a durable write.
void full_fsync_file(const std::filesystem::path& path);

// fsync a directory so a rename of one of its entries is itself durable. Plain
// fsync (not F_FULLFSYNC) is the right call for directory metadata. Throws on
// failure.
void fsync_dir(const std::filesystem::path& dir);

}  // namespace clipd
