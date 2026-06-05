from std.testing import assert_equal, TestSuite

from protobuf.fields import write_int64, write_sint64, write_string
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
    assert_equal(varint_size(UInt64.MAX), 10)


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


def test_constant_field_sizes() raises:
    assert_equal(bool_field_size(1), 1 + 1)
    assert_equal(fixed32_field_size(1), 1 + 4)
    assert_equal(fixed64_field_size(1), 1 + 8)
    assert_equal(uint64_field_size(1, 300), 1 + 2)


def test_bytes_field_size() raises:
    var payload: List[Byte] = [Byte(1), Byte(2), Byte(3)]
    assert_equal(bytes_field_size(4, Span(payload)), 1 + 1 + 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
