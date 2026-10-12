"""Serialized-size computation for protobuf fields.

These helpers report how many bytes a value *would* occupy on the wire, without
actually encoding it. They mirror the `protobuf.fields` `write_*` helpers
one-to-one, so `<type>_field_size(...)` always equals `len(encoded)`.

Two uses:

- **Reserve exact capacity.** Sum a message's field sizes, then build the output
  buffer with `List[Byte](capacity=...)` so encoding does zero reallocations.
- **Length-delimited framing.** A sub-message must write its byte length *before*
  its bytes, so its size has to be known up front anyway.
"""

from std.bit import count_leading_zeros

from protobuf.wire import zigzag_encode


def varint_size(value: UInt64) -> Int:
    """Returns the number of bytes `value` occupies as a varint (1 to 10)."""
    # A varint carries 7 payload bits per byte, so the size is
    # ceil(bit_width / 7). `| 1` gives zero a width of 1, and
    # (bits * 9 + 64) >> 6 equals ceil(bits / 7) for every bits in 1..64.
    var bits = 64 - Int(count_leading_zeros(value | 1))
    return (bits * 9 + 64) >> 6


def tag_size(field_number: Int) -> Int:
    """Returns the byte size of a field tag for `field_number`."""
    assert field_number >= 1, "tag_size: field_number must be >= 1"
    assert field_number <= 0x1FFFFFFF, "tag_size: field_number exceeds 2^29-1"
    return varint_size(UInt64(field_number) << 3)


def uint64_field_size(field_number: Int, value: UInt64) -> Int:
    """Returns the encoded size of a `uint64`/`uint32`/`enum` field."""
    return tag_size(field_number) + varint_size(value)


def int64_field_size(field_number: Int, value: Int64) -> Int:
    """Returns the encoded size of an `int64`/`int32` field."""
    return tag_size(field_number) + varint_size(UInt64(value))


def sint64_field_size(field_number: Int, value: Int64) -> Int:
    """Returns the encoded size of a `sint64`/`sint32` (ZigZag) field."""
    return tag_size(field_number) + varint_size(zigzag_encode(value))


def bool_field_size(field_number: Int) -> Int:
    """Returns the encoded size of a `bool` field (always tag + 1)."""
    return tag_size(field_number) + 1


def fixed32_field_size(field_number: Int) -> Int:
    """Returns the encoded size of a `fixed32`/`sfixed32`/`float` field."""
    return tag_size(field_number) + 4


def fixed64_field_size(field_number: Int) -> Int:
    """Returns the encoded size of a `fixed64`/`sfixed64`/`double` field."""
    return tag_size(field_number) + 8


def bytes_field_size(field_number: Int, value: Span[Byte, _]) -> Int:
    """Returns the encoded size of a `bytes` (or embedded message) field."""
    return tag_size(field_number) + varint_size(UInt64(len(value))) + len(value)


def string_field_size(field_number: Int, value: String) -> Int:
    """Returns the encoded size of a `string` field."""
    return bytes_field_size(field_number, value.as_bytes())
