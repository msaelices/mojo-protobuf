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

    Notes:
        Like the reference C++/Go decoders, a non-canonical 10th byte (payload
        bits above bit 63) is accepted leniently: the extra bits are masked off
        rather than rejected.
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
        field_number: The field number (1 to 2^29-1).
        wire_type: One of the `WIRE_*` constants.
        out: The byte buffer to append to.
    """
    assert field_number >= 1, "encode_tag: field_number must be >= 1"
    assert field_number <= 0x1FFFFFFF, "encode_tag: field_number exceeds 2^29-1"
    assert (
        wire_type == WIRE_VARINT
        or wire_type == WIRE_I64
        or wire_type == WIRE_LEN
        or wire_type == WIRE_I32
    ), "encode_tag: invalid wire_type"
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

    Notes:
        This only splits the tag bits; it does not validate that `wire_type` is
        a known value or that `field_number` is legal. Those checks belong to
        the value-reading layer (which rejects wire types 3/4/6/7).
    """
    var key = decode_varint(data, pos)
    return (Int(key >> 3), Int(key & 0x7))


# ===-----------------------------------------------------------------------===#
# Fixed-width values (WIRE_I32 / WIRE_I64)
# ===-----------------------------------------------------------------------===#


def encode_fixed32(value: UInt32, mut out: List[Byte]):
    """Appends a 32-bit value as 4 little-endian bytes (`WIRE_I32`).

    Args:
        value: The value to encode (fixed32/sfixed32, or a bit-cast float).
        out: The byte buffer to append to.
    """
    out.append(Byte(value & 0xFF))
    out.append(Byte((value >> 8) & 0xFF))
    out.append(Byte((value >> 16) & 0xFF))
    out.append(Byte((value >> 24) & 0xFF))


def decode_fixed32(data: Span[Byte, _], mut pos: Int) raises -> UInt32:
    """Reads 4 little-endian bytes from `data` at `pos`, advancing `pos`.

    Args:
        data: The byte view to read from.
        pos: The current read offset; advanced by 4.

    Returns:
        The decoded 32-bit value.

    Raises:
        If fewer than 4 bytes remain.
    """
    if pos + 4 > len(data):
        raise Error("decode_fixed32: truncated input")
    var r = (
        UInt32(data[pos])
        | (UInt32(data[pos + 1]) << 8)
        | (UInt32(data[pos + 2]) << 16)
        | (UInt32(data[pos + 3]) << 24)
    )
    pos += 4
    return r


def encode_fixed64(value: UInt64, mut out: List[Byte]):
    """Appends a 64-bit value as 8 little-endian bytes (`WIRE_I64`).

    Args:
        value: The value to encode (fixed64/sfixed64, or a bit-cast double).
        out: The byte buffer to append to.
    """
    var v = value
    for _ in range(8):
        out.append(Byte(v & 0xFF))
        v >>= 8


def decode_fixed64(data: Span[Byte, _], mut pos: Int) raises -> UInt64:
    """Reads 8 little-endian bytes from `data` at `pos`, advancing `pos`.

    Args:
        data: The byte view to read from.
        pos: The current read offset; advanced by 8.

    Returns:
        The decoded 64-bit value.

    Raises:
        If fewer than 8 bytes remain.
    """
    if pos + 8 > len(data):
        raise Error("decode_fixed64: truncated input")
    var r: UInt64 = 0
    for i in range(8):
        r |= UInt64(data[pos + i]) << (UInt64(i) * 8)
    pos += 8
    return r


# ===-----------------------------------------------------------------------===#
# Length-delimited values (WIRE_LEN)
# ===-----------------------------------------------------------------------===#


def encode_bytes(data: Span[Byte, _], mut out: List[Byte]):
    """Appends a length-delimited field: a varint length, then the bytes.

    Used for `bytes`, `string`, embedded messages, and packed repeated fields.

    Args:
        data: The payload bytes.
        out: The byte buffer to append to.
    """
    encode_varint(UInt64(len(data)), out)
    for b in data:
        out.append(b)


def decode_bytes(
    data: Span[Byte, _], mut pos: Int
) raises -> Span[Byte, data.origin]:
    """Reads a length-delimited field, returning a view into `data`.

    The returned span borrows `data`; no bytes are copied.

    Args:
        data: The byte view to read from.
        pos: The current read offset; advanced past the length and payload.

    Returns:
        A view of the payload bytes.

    Raises:
        If the length prefix is malformed or exceeds the remaining buffer.
    """
    var length64 = decode_varint(data, pos)
    var remaining = len(data) - pos
    if length64 > UInt64(remaining):
        raise Error("decode_bytes: length exceeds buffer")
    var length = Int(length64)
    var start = pos
    pos += length
    return data[start : start + length]
