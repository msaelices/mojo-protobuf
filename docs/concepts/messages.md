# Messages and fields

This page builds on [the wire format](wire-format.md). It explains how a whole
message is assembled from fields, and the layer in `protobuf.fields` that makes
that ergonomic.

## A message is a sequence of fields

A serialized message is just `(tag, value)` pairs back to back, with no overall
length or terminator:

```
[tag][value][tag][value]...
```

To decode, you read a tag, look at its field number, read the value, and
repeat until the buffer runs out. The `protobuf.fields` module provides one
typed helper per scalar type so you don't hand-write tag + value each time.

## Writing

Each `write_*` helper emits the field tag *and* the value:

```mojo
var out = List[Byte]()
write_int64(1, user_id, out)
write_string(2, name, out)
write_bool(3, is_active, out)
```

| Helper | protobuf types |
|---|---|
| `write_uint64` | `uint32`, `uint64`, `enum` |
| `write_int64` | `int32`, `int64` (two's-complement varint) |
| `write_sint64` | `sint32`, `sint64` (ZigZag) |
| `write_bool` | `bool` |
| `write_fixed32` | `fixed32`, `sfixed32`, `float` (bit-cast) |
| `write_fixed64` | `fixed64`, `sfixed64`, `double` (bit-cast) |
| `write_bytes` | `bytes`, embedded messages |
| `write_string` | `string` (UTF-8) |

## Reading and the decode loop

Reading is split in two: read the **tag** with `decode_tag`, then read the
**value** with the matching `read_*` helper. The standard pattern is a dispatch
loop:

```mojo
var pos = 0
while pos < len(data):
    var field_number, wire_type = decode_tag(data, pos)
    if field_number == 1:
        user_id = read_int64(data, pos)
    elif field_number == 2:
        name = read_string(data, pos)
    elif field_number == 3:
        is_active = read_bool(data, pos)
    else:
        skip_field(data, pos, wire_type)
```

`read_string` validates UTF-8 and raises on invalid bytes; `read_bytes` returns
a zero-copy view into the input.

## Why `skip_field` matters: forward compatibility

The `else` branch above is the key to protobuf's forward compatibility. If a
message contains a field this decoder doesn't know (added by a newer schema),
`skip_field` uses the wire type to advance past the value without understanding
it — so old code keeps working against new data. `skip_field` is also where the
illegal/deprecated wire types (groups `3`/`4`, and `6`/`7`) are rejected.

## What's next

This field layer is the foundation a typed-message API and the `protoc` code
generator will build on: generated code will simply call these `write_*`/
`read_*` helpers inside per-message `encode`/`decode` methods.
