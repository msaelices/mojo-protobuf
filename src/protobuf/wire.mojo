"""Protocol Buffers wire-format primitives.

The protobuf wire format encodes each field as a *tag* (a varint packing the
field number and wire type) followed by the field value. This module implements
the low-level building blocks shared by every field type: base-128 varints,
ZigZag signed encoding, and field tags.

See <https://protobuf.dev/programming-guides/encoding/>.
"""

# Wire types (the low 3 bits of a field tag).
comptime WIRE_VARINT = 0
"""int32/int64/uint32/uint64/sint32/sint64/bool/enum."""
comptime WIRE_I64 = 1
"""fixed64/sfixed64/double."""
comptime WIRE_LEN = 2
"""string/bytes/embedded messages/packed repeated fields."""
comptime WIRE_I32 = 5
"""fixed32/sfixed32/float."""


def encode_varint(value: UInt64, mut out: List[Byte]):
    """Appends `value` to `out` as a base-128 varint (LEB128).

    Each byte holds 7 bits of the value, little-endian, with the high bit set on
    every byte except the last.

    Args:
        value: The value to encode.
        out: The byte buffer to append to.
    """
    var v = value
    while v >= 0x80:
        out.append(Byte((v & 0x7F) | 0x80))
        v >>= 7
    out.append(Byte(v))


def decode_varint(data: Span[Byte, _], mut pos: Int) raises -> UInt64:
    """Decodes a base-128 varint from `data` starting at `pos`.

    On success, `pos` is advanced past the consumed bytes.

    Args:
        data: The byte view to read from.
        pos: The current read offset; advanced in place.

    Returns:
        The decoded value.

    Raises:
        If the input ends mid-varint, or the varint exceeds 64 bits.
    """
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while shift < 64:
        if pos >= len(data):
            raise Error("decode_varint: truncated input")
        var b = data[pos]
        pos += 1
        result |= UInt64(b & 0x7F) << shift
        if (b & 0x80) == 0:
            return result
        shift += 7
    raise Error("decode_varint: varint exceeds 64 bits")


def zigzag_encode(value: Int64) -> UInt64:
    """Maps a signed integer to an unsigned one so small magnitudes stay small.

    Used by `sint32`/`sint64`. `0 -> 0`, `-1 -> 1`, `1 -> 2`, `-2 -> 3`, ...

    Args:
        value: The signed value.

    Returns:
        The ZigZag-encoded unsigned value.
    """
    return UInt64((value << 1) ^ (value >> 63))


def zigzag_decode(value: UInt64) -> Int64:
    """Inverts `zigzag_encode`.

    Args:
        value: The ZigZag-encoded unsigned value.

    Returns:
        The original signed value.
    """
    return Int64(value >> 1) ^ -Int64(value & 1)


def encode_tag(field_number: Int, wire_type: Int, mut out: List[Byte]):
    """Appends a field tag (`field_number << 3 | wire_type`) as a varint.

    Args:
        field_number: The field number.
        wire_type: One of the `WIRE_*` constants.
        out: The byte buffer to append to.
    """
    encode_varint(UInt64((field_number << 3) | wire_type), out)


def decode_tag(data: Span[Byte, _], mut pos: Int) raises -> Tuple[Int, Int]:
    """Decodes a field tag from `data` at `pos`, advancing `pos`.

    Args:
        data: The byte view to read from.
        pos: The current read offset; advanced in place.

    Returns:
        A `(field_number, wire_type)` tuple.

    Raises:
        If the underlying varint is malformed.
    """
    var key = decode_varint(data, pos)
    return (Int(key >> 3), Int(key & 0x7))
