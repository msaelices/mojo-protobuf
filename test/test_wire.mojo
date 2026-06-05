from std.testing import assert_equal, assert_raises, TestSuite

from protobuf import VERSION
from protobuf.wire import (
    WIRE_LEN,
    decode_tag,
    decode_varint,
    encode_tag,
    encode_varint,
    zigzag_decode,
    zigzag_encode,
)


def test_version() raises:
    assert_equal(String(VERSION), "0.1.0")


def _roundtrip_varint(value: UInt64) raises:
    var buf = List[Byte]()
    encode_varint(value, buf)
    var pos = 0
    var got = decode_varint(Span(buf), pos)
    assert_equal(got, value)
    assert_equal(pos, len(buf))


def test_varint_roundtrip() raises:
    _roundtrip_varint(0)
    _roundtrip_varint(1)
    _roundtrip_varint(127)
    _roundtrip_varint(128)
    _roundtrip_varint(300)
    _roundtrip_varint(UInt64.MAX)


def test_varint_known_encoding() raises:
    # 150 -> 0x96 0x01 (canonical protobuf example).
    var buf = List[Byte]()
    encode_varint(150, buf)
    assert_equal(len(buf), 2)
    assert_equal(buf[0], Byte(0x96))
    assert_equal(buf[1], Byte(0x01))


def test_varint_truncated() raises:
    var data: List[Byte] = [Byte(0x80)]  # continuation bit set, no next byte
    var pos = 0
    with assert_raises():
        _ = decode_varint(Span(data), pos)


def test_zigzag_known() raises:
    assert_equal(zigzag_encode(0), 0)
    assert_equal(zigzag_encode(-1), 1)
    assert_equal(zigzag_encode(1), 2)
    assert_equal(zigzag_encode(-2), 3)


def test_zigzag_roundtrip() raises:
    var vals: List[Int64] = [0, 1, -1, 100, -100, Int64.MAX, Int64.MIN]
    for v in vals:
        assert_equal(zigzag_decode(zigzag_encode(v)), v)


def test_tag() raises:
    var buf = List[Byte]()
    encode_tag(3, WIRE_LEN, buf)  # (3 << 3) | 2 == 26
    assert_equal(buf[0], Byte(26))
    var pos = 0
    var fnum, wtype = decode_tag(Span(buf), pos)
    assert_equal(fnum, 3)
    assert_equal(wtype, WIRE_LEN)


def test_varint_max_is_10_bytes() raises:
    var buf = List[Byte]()
    encode_varint(UInt64.MAX, buf)
    assert_equal(len(buf), 10)


def test_varint_overlong_raises() raises:
    # 10 continuation bytes: the loop passes 64 bits without terminating.
    var data: List[Byte] = [
        Byte(0x80), Byte(0x80), Byte(0x80), Byte(0x80), Byte(0x80),
        Byte(0x80), Byte(0x80), Byte(0x80), Byte(0x80), Byte(0x80),
    ]
    var pos = 0
    with assert_raises():
        _ = decode_varint(Span(data), pos)


def test_varint_stops_midbuffer() raises:
    # Decoding one value must leave `pos` at the next field's first byte.
    var data: List[Byte] = [Byte(0x01), Byte(0xFF)]
    var pos = 0
    var got = decode_varint(Span(data), pos)
    assert_equal(got, 1)
    assert_equal(pos, 1)


def test_varint_noncanonical_10th_byte() raises:
    # Lenient: high bits in the 10th byte are masked (see decode_varint notes).
    # 9 zero-payload bytes then 0x7F -> 0x7F << 63.
    var data: List[Byte] = [
        Byte(0x80), Byte(0x80), Byte(0x80), Byte(0x80), Byte(0x80),
        Byte(0x80), Byte(0x80), Byte(0x80), Byte(0x80), Byte(0x7F),
    ]
    var pos = 0
    var got = decode_varint(Span(data), pos)
    assert_equal(got, UInt64(0x8000000000000000))


def test_decode_tag_truncated_raises() raises:
    var data: List[Byte] = [Byte(0x80)]  # truncated varint
    var pos = 0
    with assert_raises():
        _ = decode_tag(Span(data), pos)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
