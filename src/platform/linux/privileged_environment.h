/**
 * @file src/platform/linux/privileged_environment.h
 * @brief Keep GUI toolkits from loading modules the environment names while Hermes holds capabilities.
 */
#pragma once

#include <array>
#include <cstdlib>
#include <string>
#include <string_view>

namespace platf::privileged_environment {

  /**
   * @brief Variables that make Qt, GTK, GIO or GdkPixbuf load code from a path.
   *
   * The tray is Qt, and its platform theme can pull in GTK and GIO. The
   * dynamic loader ignores LD_PRELOAD for a binary with file capabilities, but
   * these toolkits read their own variables, so a module named here would run
   * with the capabilities Hermes holds (CAP_SYS_ADMIN for KMS capture).
   */
  inline constexpr std::array<std::string_view, 12> module_variables {
    "GDK_PIXBUF_MODULEDIR",
    "GDK_PIXBUF_MODULE_FILE",
    "GIO_EXTRA_MODULES",
    "GTK3_MODULES",
    "GTK_EXE_PREFIX",
    "GTK_IM_MODULE_FILE",
    "GTK_MODULES",
    "GTK_PATH",
    "QML2_IMPORT_PATH",
    "QML_IMPORT_PATH",
    "QT_PLUGIN_PATH",
    "QT_QPA_PLATFORM_PLUGIN_PATH",
  };

  /**
   * @brief Remove every module variable from the process environment.
   * @return `true` when none is left; `false` if one could not be removed.
   */
  inline bool sanitize() {
    for (const auto variable : module_variables) {
      if (::unsetenv(std::string {variable}.c_str()) != 0) {
        return false;
      }
    }
    return true;
  }

}  // namespace platf::privileged_environment
