from std.random import random_ui64, seed
from std.testing import assert_equal, TestSuite

from protobuf.fields import (
    write_bool,
    write_bytes,
    write_fixed32,
    write_fixed64,
    write_int64,
    write_sint64,
    write_string,
    write_uint64,
)
from protobuf.wire import zigzag_encode
from protobuf.size import (
    bool_field_size,
    bytes_field_size,
    fixed32_field_size,
    fixed64_field_size,
    int64_field_size,
    sint64_field_size,
    string_field_size,
    tag_size,
    uint64_field_size,
    varint_size,
)


def test_varint_size() raises:
    assert_equal(varint_size(0), 1)
    assert_equal(varint_size(127), 1)
    assert_equal(varint_size(128), 2)
    assert_equal(varint_size(16383), 2)
    assert_equal(varint_size(16384), 3)
    assert_equal(varint_size(2097151), 3)  # 2^21 - 1
    assert_equal(varint_size(2097152), 4)  # 2^21
    assert_equal(varint_size(72057594037927935), 8)  # 2^56 - 1
    assert_equal(varint_size(9223372036854775808), 10)  # 2^63
    assert_equal(varint_size(UInt64.MAX), 10)


def _varint_size_loop(value: UInt64) -> Int:
    # The original shift-loop implementation, kept as the reference.
    var n = 1
    var v = value >> 7
    while v > 0:
        n += 1
        v >>= 7
    return n


def test_varint_size_matches_shift_loop_at_boundaries() raises:
    assert_equal(varint_size(0), _varint_size_loop(0))
    assert_equal(varint_size(UInt64.MAX), _varint_size_loop(UInt64.MAX))
    # Every power of two and its neighbours, which covers both sides of each
    # 7-bit boundary (2^7k - 1 and 2^7k).
    for i in range(64):
        var p = UInt64(1) << UInt64(i)
        assert_equal(varint_size(p - 1), _varint_size_loop(p - 1))
        assert_equal(varint_size(p), _varint_size_loop(p))
        assert_equal(varint_size(p + 1), _varint_size_loop(p + 1))
        assert_equal(varint_size(~p), _varint_size_loop(~p))
    for k in range(1, 10):
        var edge = UInt64(1) << UInt64(7 * k)
        assert_equal(varint_size(edge - 1), k)
        assert_equal(varint_size(edge), k + 1)


def test_varint_size_matches_shift_loop_on_random_values() raises:
    seed(20261012)
    for _ in range(20_000):
        # Shift by a random amount so every bit width is equally likely.
        var r = random_ui64(0, UInt64.MAX)
        var v = random_ui64(0, UInt64.MAX) >> (r & 63)
        assert_equal(varint_size(v), _varint_size_loop(v))


def test_varint_size_matches_shift_loop_on_signed_edges() raises:
    # int32/int64 fields sign-extend to 64 bits; sint fields go through ZigZag.
    var edges: List[Int64] = [
        0,
        1,
        -1,
        63,
        64,
        -64,
        -65,
        Int64(Int32.MAX),
        Int64(Int32.MIN),
        Int64(Int32.MAX) + 1,
        Int64(Int32.MIN) - 1,
        Int64.MAX,
        Int64.MIN,
    ]
    for v in edges:
        var raw = UInt64(v)
        assert_equal(varint_size(raw), _varint_size_loop(raw))
        var zz = zigzag_encode(v)
        assert_equal(varint_size(zz), _varint_size_loop(zz))


def test_tag_size() raises:
    assert_equal(tag_size(1), 1)
    assert_equal(tag_size(15), 1)
    assert_equal(tag_size(16), 2)  # (16 << 3) == 128 -> 2 bytes
    assert_equal(tag_size(2047), 2)
    assert_equal(tag_size(2048), 3)


def test_int64_field_size_matches_encoding() raises:
    var vals: List[Int64] = [0, -1, 300, Int64.MIN, Int64.MAX]
    for v in vals:
        var buf = List[Byte]()
        write_int64(5, v, buf)
        assert_equal(int64_field_size(5, v), len(buf))


def test_sint64_field_size_matches_encoding() raises:
    var vals: List[Int64] = [0, -1, 1, Int64.MIN, Int64.MAX]
    for v in vals:
        var buf = List[Byte]()
        write_sint64(2, v, buf)
        assert_equal(sint64_field_size(2, v), len(buf))


def test_string_field_size_matches_encoding() raises:
    var vals: List[String] = [String(""), String("hi"), String("héllo")]
    for s in vals:
        var buf = List[Byte]()
        write_string(7, s, buf)
        assert_equal(string_field_size(7, s), len(buf))


def test_uint64_field_size_matches_encoding() raises:
    var vals: List[UInt64] = [0, 300, UInt64.MAX]
    for v in vals:
        var buf = List[Byte]()
        write_uint64(3, v, buf)
        assert_equal(uint64_field_size(3, v), len(buf))


def test_bool_field_size_matches_encoding() raises:
    var tbuf = List[Byte]()
    write_bool(1, True, tbuf)
    assert_equal(bool_field_size(1), len(tbuf))
    var fbuf = List[Byte]()
    write_bool(1, False, fbuf)
    assert_equal(bool_field_size(1), len(fbuf))


def test_fixed_field_sizes_match_encoding() raises:
    var b32 = List[Byte]()
    write_fixed32(5, 0xCAFEBABE, b32)
    assert_equal(fixed32_field_size(5), len(b32))
    var b64 = List[Byte]()
    write_fixed64(6, UInt64.MAX, b64)
    assert_equal(fixed64_field_size(6), len(b64))


def test_bytes_field_size_matches_encoding() raises:
    var payload: List[Byte] = [Byte(1), Byte(2), Byte(3)]
    var buf = List[Byte]()
    write_bytes(4, Span(payload), buf)
    assert_equal(bytes_field_size(4, Span(payload)), len(buf))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
