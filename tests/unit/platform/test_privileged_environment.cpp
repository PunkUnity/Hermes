/**
 * @file tests/unit/platform/test_privileged_environment.cpp
 * @brief GUI module variables are removed before Hermes runs with capabilities.
 */
#include "../../tests_common.h"

#include <cstdlib>
#include <src/platform/linux/privileged_environment.h>
#include <string>

namespace {
  namespace env = platf::privileged_environment;
}

TEST(PrivilegedEnvironment, EveryModuleVariableIsRemoved) {
  for (const auto variable : env::module_variables) {
    ASSERT_EQ(::setenv(std::string {variable}.c_str(), "/tmp/untrusted", 1), 0);
  }
  ASSERT_TRUE(env::sanitize());
  for (const auto variable : env::module_variables) {
    EXPECT_EQ(std::getenv(std::string {variable}.c_str()), nullptr) << variable;
  }
}

TEST(PrivilegedEnvironment, OtherVariablesAreKept) {
  ASSERT_EQ(::setenv("HERMES_TEST_KEPT", "yes", 1), 0);
  ASSERT_EQ(::setenv("WAYLAND_DISPLAY", "wayland-0", 1), 0);
  ASSERT_TRUE(env::sanitize());
  EXPECT_STREQ(std::getenv("HERMES_TEST_KEPT"), "yes");
  EXPECT_STREQ(std::getenv("WAYLAND_DISPLAY"), "wayland-0");
  ::unsetenv("HERMES_TEST_KEPT");
}

TEST(PrivilegedEnvironment, NothingToRemoveIsFine) {
  ASSERT_TRUE(env::sanitize());
  EXPECT_TRUE(env::sanitize());
}
