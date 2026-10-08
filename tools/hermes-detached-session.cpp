// SPDX-License-Identifier: GPL-3.0-only
// Session supervisor for a private, same-user stock Plasma desktop.
// The broker owns the unit/mount namespace. This program never edits KDE config.
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
  namespace fs = std::filesystem;
  using namespace std::chrono_literals;
  volatile std::sig_atomic_t stopping = 0;
  void stop_signal(int) { stopping = 1; }
  std::string env(const char *key) {
    const auto *value = std::getenv(key);
    return value ? value : "";
  }
  void set(const char *key, const std::string &value) {
    if (::setenv(key, value.c_str(), 1)) throw std::runtime_error("Could not set session environment");
  }
  pid_t spawn(std::vector<std::string> args, int output = -1) {
    std::vector<char *> words;
    for (auto &arg : args) words.push_back(arg.data());
    words.push_back(nullptr);
    const pid_t pid = ::fork();
    if (pid < 0) throw std::runtime_error("Could not fork session child");
    if (pid == 0) {
      ::setpgid(0, 0);
      if (output >= 0) {
        // Only the reader is nonblocking; child programs expect blocking stdout.
        const int flags = ::fcntl(output, F_GETFL);
        if (flags < 0 || ::fcntl(output, F_SETFL, flags & ~O_NONBLOCK) < 0 ||
            ::dup2(output, STDOUT_FILENO) < 0) ::_exit(126);
      }
      ::execv(words[0], words.data());
      ::_exit(127);
    }
    ::setpgid(pid, pid);
    return pid;
  }
  void terminate(pid_t pid) {
    if (pid <= 0) return;
    ::kill(-pid, SIGTERM);
    const auto deadline = std::chrono::steady_clock::now() + 3s;
    int status = 0;
    while (std::chrono::steady_clock::now() < deadline) {
      const pid_t waited = ::waitpid(pid, &status, WNOHANG);
      if (waited == pid || (waited < 0 && errno == ECHILD)) return;
      std::this_thread::sleep_for(20ms);
    }
    ::kill(-pid, SIGKILL);
    // Do not wait indefinitely for an uninterruptible child; the owning unit
    // also has KillMode=control-group and a bounded TimeoutStopSec.
    for (int n = 0; n < 100; ++n) {
      const pid_t waited = ::waitpid(pid, &status, WNOHANG);
      if (waited == pid || (waited < 0 && errno == ECHILD)) return;
      std::this_thread::sleep_for(10ms);
    }
  }
  std::string run(const std::vector<std::string> &args, std::chrono::seconds timeout) {
    int descriptors[2];
    if (::pipe2(descriptors, O_CLOEXEC | O_NONBLOCK)) throw std::runtime_error("Could not create child pipe");
    pid_t pid;
    try { pid = spawn(args, descriptors[1]); }
    catch (...) { ::close(descriptors[0]); ::close(descriptors[1]); throw; }
    ::close(descriptors[1]);
    std::string result;
    int status = 0;
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    bool complete = false;
    while (!stopping && std::chrono::steady_clock::now() < deadline) {
      char bytes[4096];
      for (;;) {
        const auto count = ::read(descriptors[0], bytes, sizeof(bytes));
        if (count <= 0) break;
        if (result.size() + count > 65536) {
          ::close(descriptors[0]); terminate(pid);
          throw std::runtime_error("Session child output exceeded limit");
        }
        result.append(bytes, count);
      }
      const pid_t waited = ::waitpid(pid, &status, WNOHANG);
      if (waited == pid) { complete = true; break; }
      if (waited < 0 && errno != EINTR) break;
      std::this_thread::sleep_for(10ms);
    }
    // Drain bytes written immediately before the child exited.
    char bytes[4096];
    for (;;) {
      const auto count = ::read(descriptors[0], bytes, sizeof(bytes));
      if (count <= 0) break;
      if (result.size() + count <= 65536) result.append(bytes, count);
    }
    ::close(descriptors[0]);
    if (!complete) { terminate(pid); throw std::runtime_error("Session child timed out or was interrupted: " + args.front()); }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) throw std::runtime_error("Session child failed: " + args.front());
    return result;
  }
  bool owns(const std::string &name) {
    const auto reply = run({"/usr/bin/gdbus", "call", "--session", "--dest", "org.freedesktop.DBus",
      "--object-path", "/org/freedesktop/DBus", "--method", "org.freedesktop.DBus.NameHasOwner", name}, 2s);
    if (reply == "(true,)\n") return true;
    if (reply == "(false,)\n") return false;
    throw std::runtime_error("Unexpected private D-Bus ownership reply");
  }
  fs::path runtime_dir() {
    const fs::path path = env("XDG_RUNTIME_DIR");
    const auto name = path.filename().string();
    struct stat info {};
    if (path.parent_path() != "/run" || !name.starts_with("hermes-desktop-u") ||
        ::lstat(path.c_str(), &info) || !S_ISDIR(info.st_mode) || info.st_uid != ::getuid() ||
        (info.st_mode & 077) != 0 || ::getuid() == 0) {
      throw std::runtime_error("Refusing to run outside a private same-user Hermes runtime directory");
    }
    return path;
  }
  void write_private(const fs::path &path, const std::string &value) {
    const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) throw std::runtime_error("Could not write session file: " + path.string());
    std::size_t offset = 0;
    while (offset < value.size()) {
      const auto size = ::write(fd, value.data() + offset, value.size() - offset);
      if (size < 0 && errno == EINTR) continue;
      if (size <= 0) { ::close(fd); throw std::runtime_error("Could not write session state"); }
      offset += size;
    }
    ::close(fd);
  }
  std::string desktop_exec(const std::string &path) {
    std::string result = "\"";
    for (char c : path) {
      if (c == '\n' || c == '\r' || c == '%') throw std::runtime_error("Unsupported executable path in desktop metadata");
      if (c == '\\' || c == '"' || c == '$' || c == '`') result += '\\';
      result += c;
    }
    return result + "\"";
  }
  int dimension(const char *value) {
    const std::string text = value;
    if (text.empty() || text.size() > 5 || !std::all_of(text.begin(), text.end(), [](char c) { return c >= '0' && c <= '9'; }))
      throw std::runtime_error("Invalid detached output dimension");
    const int n = std::stoi(text);
    if (n < 64 || n > 16384) throw std::runtime_error("Detached output dimension outside supported range");
    return n;
  }
  void supervise(const fs::path &root) {
    pid_t plasma = -1;
    try {
      const auto deadline = std::chrono::steady_clock::now() + 8s;
      while (!owns("org.kde.KWinWrapper")) {
        if (stopping || std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("Private KWin wrapper did not become ready");
        std::this_thread::sleep_for(100ms);
      }
      if (owns("org.freedesktop.systemd1")) throw std::runtime_error("Refusing a desktop bus with a shared user manager");
      if (env("WAYLAND_DISPLAY") != "hermes-detached") throw std::runtime_error("Unexpected private Wayland socket");
      const auto private_bus = env("DBUS_SESSION_BUS_ADDRESS");
      if (private_bus.empty() || private_bus.find('\n') != std::string::npos) throw std::runtime_error("Invalid private session bus address");
      plasma = spawn({"/usr/bin/startplasma-wayland"});
      const auto ready_deadline = std::chrono::steady_clock::now() + 35s;
      bool ready = false;
      while (!stopping) {
        int status = 0;
        const pid_t waited = ::waitpid(plasma, &status, WNOHANG);
        if (waited == plasma) { plasma = -1; throw std::runtime_error("Private Plasma exited"); }
        if (waited < 0 && errno != EINTR) throw std::runtime_error("Could not observe private Plasma process");
        if (!ready) {
          if (owns("org.kde.plasmashell") && owns("org.kde.ksmserver") && !owns("org.kde.KSplash")) {
            write_private(root / "ready.tmp", "WAYLAND_DISPLAY=hermes-detached\nDBUS_SESSION_BUS_ADDRESS=" + private_bus + "\n");
            fs::rename(root / "ready.tmp", root / "ready");
            std::cout << "PRIVATE PLASMA READY" << std::endl;
            ready = true;
          } else if (std::chrono::steady_clock::now() >= ready_deadline) {
            throw std::runtime_error("Private Plasma startup timed out");
          }
        }
        std::this_thread::sleep_for(100ms);
      }
    } catch (const std::exception &failure) {
      std::cerr << failure.what() << std::endl;
      try { write_private(root / "failure", failure.what()); } catch (...) {}
    }
    std::error_code ignored;
    fs::remove(root / "ready", ignored);
    terminate(plasma);
    // KWin's wrapper restarts on nonzero child exits. Failures are reported in
    // the generation's private status file; normal exit always ends this unit.
  }
}
int main(int argc, char **argv) {
  const bool child = env("HERMES_DETACHED_STAGE") == "session";
  try {
    ::umask(0077);
    ::signal(SIGTERM, stop_signal);
    ::signal(SIGINT, stop_signal);
    const auto root = runtime_dir();
    if (child) { supervise(root); return 0; }
    if (argc != 5 || std::string(argv[1]) != "--bootstrap") throw std::runtime_error("Usage: hermes-detached-session --bootstrap WIDTH HEIGHT HERMES_EXECUTABLE");
    const auto width = std::to_string(dimension(argv[2]));
    const auto height = std::to_string(dimension(argv[3]));
    const auto executable = fs::canonical(argv[4]);
    if (!executable.is_absolute() || ::access(executable.c_str(), X_OK)) throw std::runtime_error("Hermes executable is unavailable");
    if (owns("org.freedesktop.systemd1")) throw std::runtime_error("Bootstrap requires a private session bus");
    fs::create_directories(root / "data/applications");
    fs::create_directories(root / "cache");
    write_private(root / "data/applications/org.hermes.DetachedTransport.desktop",
      "[Desktop Entry]\nType=Application\nName=Hermes Detached Transport\nExec=" + desktop_exec(executable.string()) +
      "\nX-KDE-Wayland-Interfaces=org_kde_kwin_fake_input,zkde_screencast_unstable_v1\n");
    set("XDG_CACHE_HOME", (root / "cache").string());
    auto data_dirs = env("XDG_DATA_DIRS");
    if (data_dirs.empty()) data_dirs = "/usr/local/share:/usr/share";
    set("XDG_DATA_DIRS", (root / "data").string() + ":" + data_dirs);
    run({"/usr/bin/kbuildsycoca6", "--noincremental"}, 10s);
    set("HERMES_DETACHED_STAGE", "session");
    const auto self = fs::canonical("/proc/self/exe").string();
    std::vector<std::string> args {"/usr/bin/kwin_wayland_wrapper", "--virtual", "--width", width, "--height", height,
      "--output-count", "1", "--socket", "hermes-detached", "--xwayland", "--no-lockscreen", "--exit-with-session", self};
    std::vector<char *> words;
    for (auto &arg : args) words.push_back(arg.data());
    words.push_back(nullptr);
    ::execv(words[0], words.data());
    throw std::runtime_error("Could not execute stock KWin wrapper");
  } catch (const std::exception &failure) {
    std::cerr << failure.what() << std::endl;
    return child ? 0 : 1;
  }
}
