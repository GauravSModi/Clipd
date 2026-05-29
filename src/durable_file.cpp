#include "durable_file.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <stdexcept>

namespace clipd {

void full_fsync_file(const std::filesystem::path& path) {
  int fd = ::open(path.c_str(), O_WRONLY);
  if (fd < 0) {
    throw std::runtime_error("clipd: cannot open file to fsync: " + path.string());
  }
#if defined(__APPLE__)
  int rc = ::fcntl(fd, F_FULLFSYNC);
#else
  int rc = ::fdatasync(fd);
#endif
  if (rc != 0) {
    ::close(fd);
    throw std::runtime_error("clipd: failed to fsync file: " + path.string());
  }
  if (::close(fd) != 0) {
    throw std::runtime_error("clipd: failed to close file after fsync: " +
                             path.string());
  }
}

void fsync_dir(const std::filesystem::path& dir) {
  int fd = ::open(dir.c_str(), O_RDONLY);
  if (fd < 0) {
    throw std::runtime_error("clipd: cannot open directory to fsync: " +
                             dir.string());
  }
  if (::fsync(fd) != 0) {
    ::close(fd);
    throw std::runtime_error("clipd: failed to fsync directory: " + dir.string());
  }
  if (::close(fd) != 0) {
    throw std::runtime_error("clipd: failed to close directory after fsync: " +
                             dir.string());
  }
}

}  // namespace clipd
