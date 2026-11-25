/**
 * @file tests/unit/test_input_packets.cpp
 * @brief Input packets are size-checked before they are read as structures.
 */
#include <cstdint>
#include <cstring>
#include <vector>

extern "C" {
#include <moonlight-common-c/src/Input.h>
#include <moonlight-common-c/src/Limelight.h>
}

#include "../tests_common.h"

#include <src/input.h>

namespace {
  /// A packet of `total` bytes whose header declares `declared` bytes after the size field.
  std::vector<std::uint8_t> packet(std::uint32_t magic, std::uint32_t declared, std::size_t total) {
    std::vector<std::uint8_t> bytes(total, 0);
    const std::uint32_t size_be = __builtin_bswap32(declared);
    if (total >= sizeof(size_be)) {
      std::memcpy(bytes.data(), &size_be, sizeof(size_be));
    }
    if (total >= sizeof(NV_INPUT_HEADER)) {
      std::memcpy(bytes.data() + sizeof(size_be), &magic, sizeof(magic));
    }
    return bytes;
  }

  /// A well-formed fixed-size packet.
  template<typename Packet>
  std::vector<std::uint8_t> fixed(std::uint32_t magic) {
    return packet(magic, sizeof(Packet) - sizeof(std::uint32_t), sizeof(Packet));
  }
}  // namespace

TEST(InputPacketTests, WellFormedPacketsOfEveryTypeAreAccepted) {
  EXPECT_TRUE(input::is_valid_packet(fixed<NV_REL_MOUSE_MOVE_PACKET>(MOUSE_MOVE_REL_MAGIC_GEN5)));
  EXPECT_TRUE(input::is_valid_packet(fixed<NV_ABS_MOUSE_MOVE_PACKET>(MOUSE_MOVE_ABS_MAGIC)));
  EXPECT_TRUE(input::is_valid_packet(fixed<NV_MOUSE_BUTTON_PACKET>(MOUSE_BUTTON_DOWN_EVENT_MAGIC_GEN5)));
  EXPECT_TRUE(input::is_valid_packet(fixed<NV_SCROLL_PACKET>(SCROLL_MAGIC_GEN5)));
  EXPECT_TRUE(input::is_valid_packet(fixed<SS_HSCROLL_PACKET>(SS_HSCROLL_MAGIC)));
  EXPECT_TRUE(input::is_valid_packet(fixed<NV_KEYBOARD_PACKET>(KEY_DOWN_EVENT_MAGIC)));
  EXPECT_TRUE(input::is_valid_packet(fixed<NV_MULTI_CONTROLLER_PACKET>(MULTI_CONTROLLER_MAGIC_GEN5)));
  EXPECT_TRUE(input::is_valid_packet(fixed<SS_TOUCH_PACKET>(SS_TOUCH_MAGIC)));
  EXPECT_TRUE(input::is_valid_packet(fixed<SS_PEN_PACKET>(SS_PEN_MAGIC)));
  EXPECT_TRUE(input::is_valid_packet(fixed<SS_CONTROLLER_ARRIVAL_PACKET>(SS_CONTROLLER_ARRIVAL_MAGIC)));
  EXPECT_TRUE(input::is_valid_packet(fixed<SS_CONTROLLER_TOUCH_PACKET>(SS_CONTROLLER_TOUCH_MAGIC)));
  EXPECT_TRUE(input::is_valid_packet(fixed<SS_CONTROLLER_MOTION_PACKET>(SS_CONTROLLER_MOTION_MAGIC)));
  EXPECT_TRUE(input::is_valid_packet(fixed<SS_CONTROLLER_BATTERY_PACKET>(SS_CONTROLLER_BATTERY_MAGIC)));
}

TEST(InputPacketTests, APacketShorterThanItsHeaderIsDropped) {
  EXPECT_FALSE(input::is_valid_packet({}));
  EXPECT_FALSE(input::is_valid_packet(packet(MOUSE_MOVE_REL_MAGIC_GEN5, 4, 7)));
}

TEST(InputPacketTests, AFixedPacketShorterThanItsStructureIsDropped) {
  // The header is complete and honest, but the controller state didn't arrive:
  // batching would write past the buffer.
  constexpr auto controller = sizeof(NV_MULTI_CONTROLLER_PACKET);
  EXPECT_FALSE(input::is_valid_packet(packet(MULTI_CONTROLLER_MAGIC_GEN5, 4, sizeof(NV_INPUT_HEADER))));
  EXPECT_FALSE(input::is_valid_packet(packet(MULTI_CONTROLLER_MAGIC_GEN5, controller - 4, controller - 1)));
  EXPECT_FALSE(input::is_valid_packet(packet(SS_TOUCH_MAGIC, 4, sizeof(NV_INPUT_HEADER))));
}

TEST(InputPacketTests, ADeclaredSizeOtherThanTheStructuresIsDropped) {
  constexpr auto keyboard = sizeof(NV_KEYBOARD_PACKET);
  EXPECT_FALSE(input::is_valid_packet(packet(KEY_DOWN_EVENT_MAGIC, keyboard - 4 - 1, keyboard)));
  EXPECT_FALSE(input::is_valid_packet(packet(KEY_DOWN_EVENT_MAGIC, keyboard - 4 + 1, keyboard + 1)));
}

TEST(InputPacketTests, ADeclaredSizeBeyondTheBytesReceivedIsDropped) {
  EXPECT_FALSE(input::is_valid_packet(packet(UTF8_TEXT_EVENT_MAGIC, 4 + 30, sizeof(NV_INPUT_HEADER) + 3)));
  EXPECT_FALSE(input::is_valid_packet(packet(0x12345678, 0xFFFFFFFF, sizeof(NV_INPUT_HEADER))));
}

TEST(InputPacketTests, TextIsBoundedAndNotShorterThanItsMagic) {
  EXPECT_TRUE(input::is_valid_packet(packet(UTF8_TEXT_EVENT_MAGIC, 4 + 3, sizeof(NV_INPUT_HEADER) + 3)));
  EXPECT_TRUE(input::is_valid_packet(packet(UTF8_TEXT_EVENT_MAGIC, 4 + UTF8_TEXT_EVENT_MAX_COUNT, sizeof(NV_INPUT_HEADER) + UTF8_TEXT_EVENT_MAX_COUNT)));
  EXPECT_FALSE(input::is_valid_packet(packet(UTF8_TEXT_EVENT_MAGIC, 4 + UTF8_TEXT_EVENT_MAX_COUNT + 1, sizeof(NV_INPUT_HEADER) + UTF8_TEXT_EVENT_MAX_COUNT + 1)));
  // A size below the magic's own 4 bytes used to underflow the text length.
  EXPECT_FALSE(input::is_valid_packet(packet(UTF8_TEXT_EVENT_MAGIC, 2, sizeof(NV_INPUT_HEADER))));
}

TEST(InputPacketTests, AnUnknownTypeWithHonestSizesIsQueued) {
  // The dispatch ignores it without reading a structure.
  EXPECT_TRUE(input::is_valid_packet(packet(0x12345678, 4, sizeof(NV_INPUT_HEADER))));
}
