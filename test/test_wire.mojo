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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
