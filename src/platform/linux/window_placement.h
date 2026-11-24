/**
 * @file src/platform/linux/window_placement.h
 * @brief Identify supported launch commands and build scoped KWin placement scripts.
 */
#pragma once

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>
#include <vector>

namespace platf::window_placement {

  // Arguments have already been unquoted by the same split_unix() parser used
  // for application commands elsewhere in process.cpp. Never execute a shell
  // just to find out what an application entry launches.
  inline bool names_program(const std::vector<std::string> &arguments, std::string_view program) {
    return std::any_of(arguments.begin(), arguments.end(), [program](const auto &argument) {
      return std::filesystem::path {argument}.filename() == program;
    });
  }

  inline bool opens_big_picture(const std::vector<std::string> &arguments) {
    const bool steam = names_program(arguments, "steam") ||
                       (names_program(arguments, "flatpak") &&
                        std::find(arguments.begin(), arguments.end(), "com.valvesoftware.Steam") != arguments.end());
    return steam && std::any_of(arguments.begin(), arguments.end(), [](std::string_view argument) {
      return argument == "steam://open/bigpicture" || argument.starts_with("steam://open/bigpicture?") ||
             argument == "-gamepadui" || argument == "-bigpicture" || argument == "-tenfoot";
    });
  }

  /**
   * Whether a command starts Steam: `steam` itself (also behind a wrapper
   * such as `setsid`), the Flatpak, or a `steam://` link, which the running
   * Steam handles.
   */
  inline bool launches_steam(const std::vector<std::string> &arguments) {
    return names_program(arguments, "steam") ||
           std::find(arguments.begin(), arguments.end(), "com.valvesoftware.Steam") != arguments.end() ||
           std::any_of(arguments.begin(), arguments.end(), [](std::string_view argument) {
             return argument.starts_with("steam://");
           });
  }

  inline bool launches_gamescope(const std::vector<std::string> &arguments) {
    return names_program(arguments, "gamescope") || names_program(arguments, "hermes-gamescope-launch");
  }

  /**
   * Whether the command starts a Gamescope whose own client is Steam: the
   * shipped launcher, which always runs `steam -bigpicture`, or a gamescope
   * command that names steam.
   *
   * Steam runs once per user. A Steam started inside a new Gamescope while
   * another one is running hands its request to that one and exits, and
   * Gamescope exits with it.
   */
  inline bool gamescope_runs_steam(const std::vector<std::string> &arguments) {
    if (names_program(arguments, "hermes-gamescope-launch")) {
      return true;
    }
    return names_program(arguments, "gamescope") &&
           (names_program(arguments, "steam") ||
            std::find(arguments.begin(), arguments.end(), "com.valvesoftware.Steam") != arguments.end());
  }

  /**
   * The KWin script that moves the streamed application's windows to @p output.
   *
   * @param mirror The output overlaps the monitor it mirrors. KWin gives a
   * fullscreen window the first output under its centre, and a mirror shares
   * its centre with the monitor, so a fullscreen Gamescope always lands on the
   * monitor and reaches the stream at the monitor's shape. In a mirror the
   * launched Gamescope covers the output with a borderless window kept above
   * the panels instead. Gamescope exits with the session, so nothing is left
   * borderless on the desktop afterwards; Steam is never covered.
   */
  inline std::string kwin_script(const std::string &output, const std::vector<std::string> &classes, const std::vector<std::uint32_t> &gamescope_pids, bool mirror = false) {
    // Both names become JavaScript string literals. Restrict them before
    // interpolation, including when this helper is called outside VDISPLAY.
    if (output.empty() || output.size() > 64 || classes.empty() ||
        !std::all_of(output.begin(), output.end(), [](unsigned char c) {
          return std::isalnum(c) || c == '-' || c == '_';
        })) {
      return {};
    }
    std::string class_list;
    for (const auto &window_class : classes) {
      if (window_class.empty() || window_class.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789.-_") != std::string::npos) {
        return {};
      }
      class_list += (class_list.empty() ? "\"" : ", \"") + window_class + '"';
    }
    std::string pid_list;
    for (const auto pid : gamescope_pids) {
      if (pid > 1) {
        pid_list += (pid_list.empty() ? "" : ", ") + std::to_string(pid);
      }
    }

    return "// Hermes: position only the streamed application's windows.\n"
           "const output = workspace.screens.find(screen => screen.name === \"" + output + "\");\n"
           "const classes = [" + class_list + "];\n"
           "const gamescopePids = [" + pid_list + "];\n"
           "const mirror = " + (mirror ? "true" : "false") + ";\n"
           "const covered = [];\n"
           "let outputGone = false;\n"
           "// In a mirror the output overlaps the monitor and shares its centre, and\n"
           "// KWin makes a window fullscreen on the first output under its centre:\n"
           "// the monitor. Cover the output with the window instead.\n"
           "function isCovered(window) {\n"
           "  const area = output.geometry;\n"
           "  const frame = window.frameGeometry;\n"
           "  return !window.fullScreen && window.noBorder && window.keepAbove && frame.x === area.x && frame.y === area.y &&\n"
           "         frame.width === area.width && frame.height === area.height;\n"
           "}\n"
           "function cover(window) {\n"
           "  if (isCovered(window)) {\n"
           "    return;\n"
           "  }\n"
           "  const area = output.geometry;\n"
           "  window.fullScreen = false;\n"
           "  window.noBorder = true;\n"
           "  window.keepAbove = true;\n"
           "  window.frameGeometry = {x: area.x, y: area.y, width: area.width, height: area.height};\n"
           "  if (!covered.includes(window)) {\n"
           "    covered.push(window);\n"
           "    if (window.closed) {\n"
           "      window.closed.connect(() => covered.splice(covered.indexOf(window), 1));\n"
           "    }\n"
           "    // KWin keeps windows clear of the panels when an output changes size\n"
           "    // and can move this one after it was covered; cover it again, a\n"
           "    // bounded number of times so two placements cannot fight forever.\n"
           "    let recovers = 0;\n"
           "    if (window.frameGeometryChanged) {\n"
           "      window.frameGeometryChanged.connect(() => {\n"
           "        if (covered.includes(window) && !isCovered(window) && !window.fullScreen && recovers < 20) {\n"
           "          recovers += 1;\n"
           "          cover(window);\n"
           "        }\n"
           "      });\n"
           "    }\n"
           "  }\n"
           "}\n"
           "// Gamescope can outlive the output (a session parked at the login\n"
           "// screen): give it back plain fullscreen rather than leave a borderless\n"
           "// window above the desktop's panels.\n"
           "function uncover(window) {\n"
           "  window.keepAbove = false;\n"
           "  window.noBorder = false;\n"
           "  window.fullScreen = true;\n"
           "}\n"
           "if (mirror && output && output.geometryChanged) {\n"
           "  output.geometryChanged.connect(() => covered.slice().forEach(cover));\n"
           "}\n"
           "if (mirror && output && workspace.screensChanged) {\n"
           "  const outputName = output.name;\n"
           "  workspace.screensChanged.connect(() => {\n"
           "    if (!workspace.screens.some(screen => screen.name === outputName)) {\n"
           "      outputGone = true;\n"
           "      covered.splice(0).forEach(uncover);\n"
           "    }\n"
           "  });\n"
           "}\n"
           "function place(window) {\n"
           "  if (!output || outputGone || !window.normalWindow || !classes.includes(window.resourceClass)) {\n"
           "    return;\n"
           "  }\n"
           "  if (mirror && window.resourceClass === \"gamescope\" && gamescopePids.includes(window.pid)) {\n"
           "    cover(window);\n"
           "    return;\n"
           "  }\n"
           "  if (window.output === output) {\n"
           "    return;\n"
           "  }\n"
           "  // Other Gamescope instances belong to the local desktop. The shipped\n"
           "  // launcher execs Gamescope, preserving the PID Hermes started. Custom\n"
           "  // launchers that fork it instead are left alone, never matched by class.\n"
           "  if (window.resourceClass === \"gamescope\" && !gamescopePids.includes(window.pid)) {\n"
           "    return;\n"
           "  }\n"
           "  const wasFullScreen = window.fullScreen;\n"
           "  if (wasFullScreen) {\n"
           "    window.fullScreen = false;\n"
           "  }\n"
           "  workspace.sendClientToScreen(window, output);\n"
           "  if (wasFullScreen) {\n"
           "    window.fullScreen = true;\n"
           "  }\n"
           "}\n"
           "// A client can still pick its own output when it goes fullscreen. Steam\n"
           "// opens Big Picture, is moved here, moves itself back to the primary\n"
           "// monitor and goes fullscreen there; place it again once it has.\n"
           "function watch(window) {\n"
           "  place(window);\n"
           "  if (window.fullScreenChanged) {\n"
           "    window.fullScreenChanged.connect(() => {\n"
           "      if (window.fullScreen) {\n"
           "        place(window);\n"
           "      }\n"
           "    });\n"
           "  }\n"
           "}\n"
           "workspace.windowList().forEach(watch);\n"
           "workspace.windowAdded.connect(watch);\n";
  }
}  // namespace platf::window_placement
