/**
 * @file tests/unit/test_stream.cpp
 * @brief Test src/stream.*
 */

#include <cstdint>
#include <functional>
#include <optional>
#include <string_view>
#include <utility>
#include <string>
#include <vector>

namespace stream {
  std::vector<uint8_t> concat_and_insert(uint64_t insert_size, uint64_t slice_size, const std::string_view &data1, const std::string_view &data2);
}

#include "../tests_common.h"

TEST(ConcatAndInsertTests, ConcatNoInsertionTest) {
  char b1[] = {'a', 'b'};
  char b2[] = {'c', 'd', 'e'};
  auto res = stream::concat_and_insert(0, 2, std::string_view {b1, sizeof(b1)}, std::string_view {b2, sizeof(b2)});
  auto expected = std::vector<uint8_t> {'a', 'b', 'c', 'd', 'e'};
  ASSERT_EQ(res, expected);
}

TEST(ConcatAndInsertTests, ConcatLargeStrideTest) {
  char b1[] = {'a', 'b'};
  char b2[] = {'c', 'd', 'e'};
  auto res = stream::concat_and_insert(1, sizeof(b1) + sizeof(b2) + 1, std::string_view {b1, sizeof(b1)}, std::string_view {b2, sizeof(b2)});
  auto expected = std::vector<uint8_t> {0, 'a', 'b', 'c', 'd', 'e'};
  ASSERT_EQ(res, expected);
}

TEST(ConcatAndInsertTests, ConcatSmallStrideTest) {
  char b1[] = {'a', 'b'};
  char b2[] = {'c', 'd', 'e'};
  auto res = stream::concat_and_insert(1, 1, std::string_view {b1, sizeof(b1)}, std::string_view {b2, sizeof(b2)});
  auto expected = std::vector<uint8_t> {0, 'a', 0, 'b', 0, 'c', 0, 'd', 0, 'e'};
  ASSERT_EQ(res, expected);
}

namespace stream {
  std::optional<std::pair<std::uint16_t, std::string_view>> parse_control_packet(const std::uint8_t *data, std::size_t size);

  struct encrypted_control_t {
    std::uint32_t seq;
    std::string_view tagged_cipher;
  };

  std::optional<encrypted_control_t> parse_encrypted_control(std::string_view payload);
  std::optional<std::string_view> parse_legacy_input(std::string_view payload);
}  // namespace stream

namespace {
  /// The bytes after an encrypted control packet's type: length (LE), seq (LE), then `body`.
  std::string encrypted_payload(std::uint16_t length, std::uint32_t seq, std::size_t body) {
    std::string payload;
    payload.push_back(static_cast<char>(length & 0xFF));
    payload.push_back(static_cast<char>(length >> 8));
    for (int i = 0; i < 4; ++i) {
      payload.push_back(static_cast<char>((seq >> (8 * i)) & 0xFF));
    }
    payload.append(body, 'x');
    return payload;
  }
}  // namespace

TEST(ControlPacketTests, APacketShorterThanItsTypeIsDropped) {
  const std::uint8_t one[] = {0x01};
  EXPECT_FALSE(stream::parse_control_packet(one, 0));
  EXPECT_FALSE(stream::parse_control_packet(one, sizeof(one)));
  EXPECT_FALSE(stream::parse_control_packet(nullptr, 4));
}

TEST(ControlPacketTests, TheTypeAndPayloadAreSplit) {
  const std::uint8_t packet[] = {0x01, 0x00, 'a', 'b'};
  const auto message = stream::parse_control_packet(packet, sizeof(packet));
  ASSERT_TRUE(message);
  EXPECT_EQ(message->first, 0x0001);
  EXPECT_EQ(message->second, "ab");

  const auto bare = stream::parse_control_packet(packet, 2);
  ASSERT_TRUE(bare);
  EXPECT_TRUE(bare->second.empty());
}

TEST(ControlPacketTests, AnEncryptedMessageFittingItsBytesIsAccepted) {
  // seq (4) + tag (16) + encrypted type and length (4) + 3 bytes of data
  const auto payload = encrypted_payload(27, 0x01020304, 23);
  const auto message = stream::parse_encrypted_control(payload);
  ASSERT_TRUE(message);
  EXPECT_EQ(message->seq, 0x01020304u);
  EXPECT_EQ(message->tagged_cipher.size(), 23u);
  EXPECT_EQ(message->tagged_cipher.data(), payload.data() + 6);
}

TEST(ControlPacketTests, AnEncryptedMessageClaimingMoreThanArrivedIsDropped) {
  // The client says 1000 bytes; 23 arrived after the sequence number.
  EXPECT_FALSE(stream::parse_encrypted_control(encrypted_payload(1000, 1, 23)));
  EXPECT_FALSE(stream::parse_encrypted_control(encrypted_payload(0xFFFF, 1, 23)));
  // One byte more than arrived.
  EXPECT_FALSE(stream::parse_encrypted_control(encrypted_payload(28, 1, 23)));
}

TEST(ControlPacketTests, ARuntEncryptedMessageIsDropped) {
  EXPECT_FALSE(stream::parse_encrypted_control(""));
  EXPECT_FALSE(stream::parse_encrypted_control(std::string_view {"\x18\x00\x01", 3}));
  // Shorter than seq + tag + the encrypted type and length.
  EXPECT_FALSE(stream::parse_encrypted_control(encrypted_payload(23, 1, 19)));
  EXPECT_TRUE(stream::parse_encrypted_control(encrypted_payload(24, 1, 20)));
}

TEST(ControlPacketTests, LegacyInputMustFitItsLength) {
  // Big-endian length, then that many bytes.
  const std::string fits {"\x00\x00\x00\x03" "abc", 7};
  const auto cipher = stream::parse_legacy_input(fits);
  ASSERT_TRUE(cipher);
  EXPECT_EQ(*cipher, "abc");

  EXPECT_FALSE(stream::parse_legacy_input(std::string_view {"\x00\x00", 2}));
  EXPECT_FALSE(stream::parse_legacy_input(std::string_view {"\x00\x00\x00\x04" "abc", 7}));
  // A negative length used to become a huge size.
  EXPECT_FALSE(stream::parse_legacy_input(std::string_view {"\xff\xff\xff\xff" "abc", 7}));
}
