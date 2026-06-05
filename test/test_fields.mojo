from std.memory import bitcast
from std.testing import assert_equal, assert_raises, TestSuite

from protobuf.wire import decode_tag
from protobuf.fields import (
    read_bool,
    read_bytes,
    read_double,
    read_fixed32,
    read_fixed64,
    read_float,
    read_int64,
    read_sint64,
    read_string,
    read_uint64,
    skip_field,
    write_bool,
    write_bytes,
    write_double,
    write_fixed32,
    write_fixed64,
    write_float,
    write_int64,
    write_sint64,
    write_string,
    write_uint64,
)


def test_scalar_field_roundtrips() raises:
    var output = List[Byte]()
    write_uint64(1, 300, output)
    write_int64(2, -5, output)
    write_sint64(3, -5, output)
    write_bool(4, True, output)
    write_fixed32(5, 0xCAFEBABE, output)
    write_fixed64(6, 0x1122334455667788, output)

    var pos = 0
    _ = decode_tag(Span(output), pos)
    assert_equal(read_uint64(Span(output), pos), 300)
    _ = decode_tag(Span(output), pos)
    assert_equal(read_int64(Span(output), pos), -5)
    _ = decode_tag(Span(output), pos)
    assert_equal(read_sint64(Span(output), pos), -5)
    _ = decode_tag(Span(output), pos)
    assert_equal(read_bool(Span(output), pos), True)
    _ = decode_tag(Span(output), pos)
    assert_equal(read_fixed32(Span(output), pos), 0xCAFEBABE)
    _ = decode_tag(Span(output), pos)
    assert_equal(read_fixed64(Span(output), pos), 0x1122334455667788)
    assert_equal(pos, len(output))


def test_message_roundtrip() raises:
    # A small multi-field message, encoded then decoded with a dispatch loop.
    var output = List[Byte]()
    write_int64(1, -5, output)
    write_string(2, "héllo", output)  # non-ASCII to exercise UTF-8
    write_bool(3, True, output)

    var pos = 0
    var got_id: Int64 = 0
    var got_name = String("")
    var got_active = False
    while pos < len(output):
        var field_number, wire_type = decode_tag(Span(output), pos)
        if field_number == 1:
            got_id = read_int64(Span(output), pos)
        elif field_number == 2:
            got_name = read_string(Span(output), pos)
        elif field_number == 3:
            got_active = read_bool(Span(output), pos)
        else:
            skip_field(Span(output), pos, wire_type)

    assert_equal(got_id, -5)
    assert_equal(got_name, "héllo")
    assert_equal(got_active, True)


def test_skip_unknown_field() raises:
    var output = List[Byte]()
    write_string(5, "ignore me", output)  # unknown LEN field
    write_fixed32(6, 999, output)  # unknown I32 field
    write_int64(1, 42, output)  # known

    var pos = 0
    var got: Int64 = 0
    while pos < len(output):
        var field_number, wire_type = decode_tag(Span(output), pos)
        if field_number == 1:
            got = read_int64(Span(output), pos)
        else:
            skip_field(Span(output), pos, wire_type)

    assert_equal(got, 42)


def test_skip_invalid_wire_type_raises() raises:
    var data = List[Byte]()
    var pos = 0
    with assert_raises():
        skip_field(Span(data), pos, 3)  # deprecated group type -> rejected


def test_bytes_roundtrip() raises:
    var payload: List[Byte] = [Byte(0x00), Byte(0xFF), Byte(0x10)]  # binary
    var output = List[Byte]()
    write_bytes(7, Span(payload), output)
    var pos = 0
    var field_number, _ = decode_tag(Span(output), pos)
    assert_equal(field_number, 7)
    var view = read_bytes(Span(output), pos)
    assert_equal(len(view), 3)
    assert_equal(view[0], Byte(0x00))
    assert_equal(view[1], Byte(0xFF))
    assert_equal(pos, len(output))


def test_read_string_invalid_utf8_raises() raises:
    var data: List[Byte] = [Byte(2), Byte(0xFF), Byte(0xFE)]  # len 2, bad UTF-8
    var pos = 0
    with assert_raises():
        _ = read_string(Span(data), pos)


def test_skip_field_malformed_raises() raises:
    # truncated VARINT (continuation bit set, no next byte)
    var v: List[Byte] = [Byte(0x80)]
    var p = 0
    with assert_raises():
        skip_field(Span(v), p, 0)  # WIRE_VARINT

    # truncated I64 (needs 8, has 1)
    var i64: List[Byte] = [Byte(1)]
    p = 0
    with assert_raises():
        skip_field(Span(i64), p, 1)  # WIRE_I64

    # truncated I32 (needs 4, has 2)
    var i32: List[Byte] = [Byte(1), Byte(2)]
    p = 0
    with assert_raises():
        skip_field(Span(i32), p, 5)  # WIRE_I32

    # LEN claims 10 bytes but only 3 follow
    var ln: List[Byte] = [Byte(10), Byte(1), Byte(2), Byte(3)]
    p = 0
    with assert_raises():
        skip_field(Span(ln), p, 2)  # WIRE_LEN


def test_varint_boundary_values() raises:
    var output = List[Byte]()
    write_int64(1, Int64.MIN, output)
    write_int64(2, Int64.MAX, output)
    write_uint64(3, UInt64.MAX, output)
    write_sint64(4, Int64.MIN, output)

    var pos = 0
    _ = decode_tag(Span(output), pos)
    assert_equal(read_int64(Span(output), pos), Int64.MIN)
    _ = decode_tag(Span(output), pos)
    assert_equal(read_int64(Span(output), pos), Int64.MAX)
    _ = decode_tag(Span(output), pos)
    assert_equal(read_uint64(Span(output), pos), UInt64.MAX)
    _ = decode_tag(Span(output), pos)
    assert_equal(read_sint64(Span(output), pos), Int64.MIN)
    assert_equal(pos, len(output))


def test_float_roundtrip() raises:
    var buf = List[Byte]()
    write_float(1, Float32(3.14), buf)
    assert_equal(len(buf), 1 + 4)  # tag + fixed32
    var pos = 0
    var fnum, _ = decode_tag(Span(buf), pos)
    assert_equal(fnum, 1)
    assert_equal(read_float(Span(buf), pos), Float32(3.14))


def test_double_roundtrip() raises:
    var buf = List[Byte]()
    write_double(2, Float64(-2.5), buf)
    assert_equal(len(buf), 1 + 8)  # tag + fixed64
    var pos = 0
    var fnum, _ = decode_tag(Span(buf), pos)
    assert_equal(fnum, 2)
    assert_equal(read_double(Span(buf), pos), Float64(-2.5))


def _float_bits_roundtrip(bits: UInt32) raises:
    var buf = List[Byte]()
    write_float(1, bitcast[DType.float32](bits), buf)
    var pos = 0
    _ = decode_tag(Span(buf), pos)
    assert_equal(read_float(Span(buf), pos).to_bits[DType.uint32](), bits)


def test_float_special_values() raises:
    # Bit patterns must survive exactly (compare bits, since NaN != NaN).
    _float_bits_roundtrip(0x80000000)  # -0.0
    _float_bits_roundtrip(0x7F800000)  # +Inf
    _float_bits_roundtrip(0xFF800000)  # -Inf
    _float_bits_roundtrip(0x7FC00000)  # NaN
    _float_bits_roundtrip(0x00000001)  # smallest subnormal


def _double_bits_roundtrip(bits: UInt64) raises:
    var buf = List[Byte]()
    write_double(1, bitcast[DType.float64](bits), buf)
    var pos = 0
    _ = decode_tag(Span(buf), pos)
    assert_equal(read_double(Span(buf), pos).to_bits[DType.uint64](), bits)


def test_double_special_values() raises:
    _double_bits_roundtrip(0x8000000000000000)  # -0.0
    _double_bits_roundtrip(0x7FF0000000000000)  # +Inf
    _double_bits_roundtrip(0xFFF0000000000000)  # -Inf
    _double_bits_roundtrip(0x7FF8000000000000)  # NaN
    _double_bits_roundtrip(0x0000000000000001)  # smallest subnormal


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
