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

  inline bool launches_gamescope(const std::vector<std::string> &arguments) {
    return names_program(arguments, "gamescope") || names_program(arguments, "hermes-gamescope-launch");
  }

  inline std::string kwin_script(const std::string &output, const std::vector<std::string> &classes, const std::vector<std::uint32_t> &gamescope_pids) {
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
    // The games Steam starts are windows of their own: Proton gives each the
    // class steam_app_<appid>. Placing only Steam's own window left a game
    // launched from Big Picture on the primary monitor while the stream showed
    // Big Picture's empty output. They follow Steam onto the stream's output.
    const bool steam_games = std::find(classes.begin(), classes.end(), "steam") != classes.end();
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
           "const steamGames = " + (steam_games ? "true" : "false") + ";\n"
           "function streamed(window) {\n"
           "  return classes.includes(window.resourceClass) ||\n"
           "         (steamGames && String(window.resourceClass).startsWith(\"steam_app_\"));\n"
           "}\n"
           "function place(window) {\n"
           "  if (!output || !window.normalWindow || !streamed(window) || window.output === output) {\n"
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
           "  print(\"Hermes: moved \" + window.resourceClass + \" to \" + output.name);\n"
           "}\n"
           "// A client can still pick its own output when it goes fullscreen. Steam\n"
           "// opens Big Picture, is moved here, moves itself back to the primary\n"
           "// monitor and goes fullscreen there; place it again once it has.\n"
           "// A game can also be fullscreen from its first frame, or move itself\n"
           "// back to the monitor it chose: place it again when it leaves the\n"
           "// stream's output, a few times, so a window that insists is not fought\n"
           "// forever. Its class may only be known once it is set, too.\n"
           "function watch(window) {\n"
           "  // One budget for every placement after the first: a game that moves\n"
           "  // back to the monitor it chose each time is left there, not fought.\n"
           "  let replaced = 0;\n"
           "  const again = () => {\n"
           "    if (replaced < 5 && output && window.output !== output && streamed(window)) {\n"
           "      ++replaced;\n"
           "      place(window);\n"
           "    }\n"
           "  };\n"
           "  if (window.fullScreenChanged) {\n"
           "    window.fullScreenChanged.connect(() => {\n"
           "      if (window.fullScreen) {\n"
           "        again();\n"
           "      }\n"
           "    });\n"
           "  }\n"
           "  if (window.outputChanged) {\n"
           "    window.outputChanged.connect(again);\n"
           "  }\n"
           "  if (window.windowClassChanged) {\n"
           "    window.windowClassChanged.connect(() => place(window));\n"
           "  }\n"
           "  // Last, so a move back during this first placement is seen.\n"
           "  place(window);\n"
           "}\n"
           "workspace.windowList().forEach(watch);\n"
           "workspace.windowAdded.connect(watch);\n";
  }
}  // namespace platf::window_placement
