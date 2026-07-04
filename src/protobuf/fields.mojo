"""Typed protobuf field codecs.

A protobuf message is a flat sequence of `(tag, value)` pairs. This module adds
a typed layer on top of `protobuf.wire`: each `write_*` helper emits the field
tag and then the value; each `read_*` helper reads a value (the caller reads the
tag first, via `decode_tag`, and dispatches on the field number). `skip_field`
discards an unknown field's value, which is what makes forward compatibility
work.

Scope: 32-bit varint types (`int32`/`uint32`/`sint32`) ride the 64-bit helpers,
and `float`/`double` ride `fixed32`/`fixed64` with a bit-cast — both are
wire-compatible. Dedicated typed wrappers will arrive with the message API.

A typical decode loop:

```mojo
var pos = 0
while pos < len(data):
    var field_number, wire_type = decode_tag(data, pos)
    if field_number == 1:
        id = read_int64(data, pos)
    elif field_number == 2:
        name = read_string(data, pos)
    else:
        skip_field(data, pos, wire_type)
```
"""

from std.memory import pack_bits
from std.sys import simd_width_of

from protobuf.wire import (
    WIRE_I32,
    WIRE_I64,
    WIRE_LEN,
    WIRE_VARINT,
    decode_bytes,
    decode_fixed,
    decode_fixed32,
    decode_fixed64,
    decode_varint,
    encode_bytes,
    encode_fixed,
    encode_fixed32,
    encode_fixed64,
    encode_tag,
    encode_varint,
    zigzag_decode,
    zigzag_encode,
)


# ===-----------------------------------------------------------------------===#
# Writers (tag + value)
# ===-----------------------------------------------------------------------===#


def write_uint64(field_number: Int, value: UInt64, mut output: List[Byte]):
    """Writes a `uint64`/`uint32`/`enum` field as a varint."""
    encode_tag(field_number, WIRE_VARINT, output)
    encode_varint(value, output)


def write_int64(field_number: Int, value: Int64, mut output: List[Byte]):
    """Writes an `int64`/`int32` field as a varint (two's complement)."""
    encode_tag(field_number, WIRE_VARINT, output)
    encode_varint(UInt64(value), output)


def write_sint64(field_number: Int, value: Int64, mut output: List[Byte]):
    """Writes a `sint64`/`sint32` field as a ZigZag varint."""
    encode_tag(field_number, WIRE_VARINT, output)
    encode_varint(zigzag_encode(value), output)


def write_bool(field_number: Int, value: Bool, mut output: List[Byte]):
    """Writes a `bool` field as a varint (`0` or `1`)."""
    encode_tag(field_number, WIRE_VARINT, output)
    encode_varint(UInt64(1) if value else UInt64(0), output)


def write_fixed32(field_number: Int, value: UInt32, mut output: List[Byte]):
    """Writes a `fixed32`/`sfixed32` field as 4 little-endian bytes.

    For `float`, use `write_float`.
    """
    encode_tag(field_number, WIRE_I32, output)
    encode_fixed32(value, output)


def write_fixed64(field_number: Int, value: UInt64, mut output: List[Byte]):
    """Writes a `fixed64`/`sfixed64` field as 8 little-endian bytes.

    For `double`, use `write_double`.
    """
    encode_tag(field_number, WIRE_I64, output)
    encode_fixed64(value, output)


def write_float(field_number: Int, value: Float32, mut output: List[Byte]):
    """Writes a `float` field (4 little-endian bytes of its IEEE-754 bits)."""
    encode_tag(field_number, WIRE_I32, output)
    encode_fixed[DType.float32](value, output)


def write_double(field_number: Int, value: Float64, mut output: List[Byte]):
    """Writes a `double` field (8 little-endian bytes of its IEEE-754 bits)."""
    encode_tag(field_number, WIRE_I64, output)
    encode_fixed[DType.float64](value, output)


def write_bytes(
    field_number: Int, value: Span[Byte, _], mut output: List[Byte]
):
    """Writes a `bytes` (or embedded message) field, length-delimited."""
    encode_tag(field_number, WIRE_LEN, output)
    encode_bytes(value, output)


def write_string(field_number: Int, value: String, mut output: List[Byte]):
    """Writes a `string` field (its UTF-8 bytes), length-delimited."""
    encode_tag(field_number, WIRE_LEN, output)
    encode_bytes(value.as_bytes(), output)


# ===-----------------------------------------------------------------------===#
# Readers (value only; read the tag first with `decode_tag`)
# ===-----------------------------------------------------------------------===#


def read_uint64(data: Span[Byte, _], mut pos: Int) raises -> UInt64:
    """Reads a varint `uint64`/`uint32`/`enum` value (tag already consumed).

    Raises:
        If the input is truncated.
    """
    return decode_varint(data, pos)


def read_int64(data: Span[Byte, _], mut pos: Int) raises -> Int64:
    """Reads a varint `int64`/`int32` value, two's complement (tag consumed).

    Raises:
        If the input is truncated.
    """
    return Int64(decode_varint(data, pos))


def read_sint64(data: Span[Byte, _], mut pos: Int) raises -> Int64:
    """Reads a ZigZag `sint64`/`sint32` value (tag already consumed).

    Raises:
        If the input is truncated.
    """
    return zigzag_decode(decode_varint(data, pos))


def read_bool(data: Span[Byte, _], mut pos: Int) raises -> Bool:
    """Reads a `bool` value; any non-zero varint is `True` (tag consumed).

    Raises:
        If the input is truncated.
    """
    return decode_varint(data, pos) != 0


def read_fixed32(data: Span[Byte, _], mut pos: Int) raises -> UInt32:
    """Reads a `fixed32`/`sfixed32`/`float` value, 4 LE bytes (tag consumed).

    Raises:
        If fewer than 4 bytes remain.
    """
    return decode_fixed32(data, pos)


def read_fixed64(data: Span[Byte, _], mut pos: Int) raises -> UInt64:
    """Reads a `fixed64`/`sfixed64`/`double` value, 8 LE bytes (tag consumed).

    Raises:
        If fewer than 8 bytes remain.
    """
    return decode_fixed64(data, pos)


def read_float(data: Span[Byte, _], mut pos: Int) raises -> Float32:
    """Reads a `float` value, 4 LE bytes (tag already consumed).

    Raises:
        If fewer than 4 bytes remain.
    """
    return decode_fixed[DType.float32](data, pos)


def read_double(data: Span[Byte, _], mut pos: Int) raises -> Float64:
    """Reads a `double` value, 8 LE bytes (tag already consumed).

    Raises:
        If fewer than 8 bytes remain.
    """
    return decode_fixed[DType.float64](data, pos)


def read_bytes(
    data: Span[Byte, _], mut pos: Int
) raises -> Span[Byte, data.origin]:
    """Reads a `bytes` value as a zero-copy view into `data` (tag consumed).

    Raises:
        If the length prefix is malformed or exceeds the buffer.
    """
    return decode_bytes(data, pos)


@always_inline
def _all_ascii(s: Span[Byte, _]) -> Bool:
    """Returns whether every byte is < 0x80 (i.e. plain ASCII)."""
    comptime W = simd_width_of[DType.uint8]()
    var n = len(s)
    var ptr = s.unsafe_ptr()
    var i = 0
    var acc = SIMD[DType.uint8, W](0)
    while i + W <= n:
        acc |= ptr.load[width=W](i)
        i += W
    if (acc.reduce_or() & 0x80) != 0:
        return False
    while i < n:
        if ptr[i] >= 0x80:
            return False
        i += 1
    return True


def read_string(data: Span[Byte, _], mut pos: Int) raises -> String:
    """Reads a `string` value, validating its UTF-8 (tag already consumed).

    ASCII (the common case) is valid UTF-8 by definition, so an all-ASCII value
    skips the full UTF-8 validator — which is slow for short strings — after a
    cheap SIMD high-bit scan. Non-ASCII bytes still go through full validation.

    Raises:
        If the bytes are not valid UTF-8, or the length is malformed.
    """
    var view = decode_bytes(data, pos)
    if _all_ascii(view):
        return String(unsafe_from_utf8=view)
    return String(from_utf8=view)


# ===-----------------------------------------------------------------------===#
# Packed repeated varint decode (SIMD fast path)
# ===-----------------------------------------------------------------------===#


@always_inline
def _packed_simd_prefix[
    dtype: DType
](blob: Span[Byte, _], mut out: List[Scalar[dtype]]) -> Int:
    """Bulk-decodes the leading run of 1-byte varints from `blob` via SIMD.

    A varint with the continuation bit clear is a single byte whose value is the
    byte itself (0-127). A SIMD chunk with no continuation bits is therefore a
    run of `W` such values, extracted at once. Returns the number of bytes (=
    values) consumed; stops at the first chunk holding a multi-byte varint, so
    the caller finishes with the scalar loop (large-value arrays pay at most one
    SIMD load).
    """
    comptime W = simd_width_of[DType.uint8]()
    var n = len(blob)
    var ptr = blob.unsafe_ptr()
    var i = 0
    while i + W <= n:
        var chunk = ptr.load[width=W](i)
        var hi = (chunk & SIMD[DType.uint8, W](0x80)).cast[DType.bool]()
        if pack_bits(hi) != 0:
            break  # a multi-byte varint starts in this chunk
        for k in range(W):
            out.append(Scalar[dtype](chunk[k]))
        i += W
    return i


def read_packed_signed[
    dtype: DType
](blob: Span[Byte, _], mut out: List[Scalar[dtype]]) raises:
    """Decodes a packed `int32`/`int64` blob (back-to-back varints) into `out`.

    Uses the SIMD prefix fast path for the common small-value case, then the
    scalar two's-complement varint reader for the remainder.
    """
    out.reserve(len(out) + len(blob))  # at most one value per byte
    var pos = _packed_simd_prefix[dtype](blob, out)
    while pos < len(blob):
        out.append(Scalar[dtype](read_int64(blob, pos)))


def read_packed_unsigned[
    dtype: DType
](blob: Span[Byte, _], mut out: List[Scalar[dtype]]) raises:
    """Decodes a packed `uint32`/`uint64` blob (varints) into `out`.

    Uses the SIMD prefix fast path for the common small-value case, then the
    scalar varint reader for the remainder.
    """
    out.reserve(len(out) + len(blob))  # at most one value per byte
    var pos = _packed_simd_prefix[dtype](blob, out)
    while pos < len(blob):
        out.append(Scalar[dtype](read_uint64(blob, pos)))


# ===-----------------------------------------------------------------------===#
# Skipping unknown fields
# ===-----------------------------------------------------------------------===#


def skip_field(data: Span[Byte, _], mut pos: Int, wire_type: Int) raises:
    """Advances `pos` past the value of an unknown field.

    This is the forward-compatibility primitive: a decoder that doesn't
    recognise a field number skips its value and keeps going.

    Args:
        data: The byte view to read from.
        pos: The current read offset; advanced past the value.
        wire_type: The wire type from the field tag.

    Raises:
        If the value is truncated, or `wire_type` is not a known value
        (the deprecated group types 3/4 and the illegal 6/7 are rejected here).
    """
    if wire_type == WIRE_VARINT:
        _ = decode_varint(data, pos)
    elif wire_type == WIRE_I64:
        if pos + 8 > len(data):
            raise Error("skip_field: truncated I64")
        pos += 8
    elif wire_type == WIRE_LEN:
        var length = decode_varint(data, pos)
        var remaining = len(data) - pos
        if length > UInt64(remaining):
            raise Error("skip_field: length exceeds buffer")
        pos += Int(length)
    elif wire_type == WIRE_I32:
        if pos + 4 > len(data):
            raise Error("skip_field: truncated I32")
        pos += 4
    else:
        raise Error("skip_field: invalid wire type")
