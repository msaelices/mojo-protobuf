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
var output = List[Byte]()
write_int64(1, user_id, output)
write_string(2, name, output)
write_bool(3, is_active, output)
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

## The `Message` trait

`protobuf.message` turns a struct into a serializable message. The trait's three
methods — `encode_to`, `merge_field`, and `encoded_size` — have **default
implementations driven by reflection**, so the common case needs no
serialization code at all:

```mojo
@fieldwise_init
struct Person(Message):
    var id: Int64
    var name: String

    def __init__(out self):  # the only requirement: default-constructible
        self.id = 0
        self.name = String("")

var bytes = encode(Person(id=1, name=String("ada")))
var p = decode[Person](Span(bytes))
```

Reflection walks the struct's fields and serializes each by its type, assigning
**field number = the field's 1-based position**. Supported field types are
`Int`, `Int32`, `Int64`, `UInt32`, `UInt64`, `Bool`, `String`, `Float32`,
`Float64`, and `List[Byte]` (protobuf `bytes`); the machine-width `Int` maps to
an `int64` varint. A field whose type itself conforms to `Message` is encoded as
a **nested message** (length-delimited), so message composition works out of the
box. Any other type is a compile error (unless you override the methods).

Truly recursive messages (a type that contains itself, e.g. a tree node) can't
be plain fields — they'd be infinitely sized — so they need indirection (an
`OwnedPointer` field) and an explicit override; the reflection default covers
acyclic nesting. `decode` default-constructs the message, so
fields absent from the wire keep their defaults — protobuf's missing-field
semantics — and `encode` reserves the buffer with `encoded_size()`, so it does
zero reallocations (see [`protobuf.size`](wire-format.md)).

### Overriding for control

For non-sequential or sparse field numbers, types reflection doesn't cover
(nested messages, repeated, floats, …), wire-type validation of known fields, or
canonical proto3 default-omission, implement the methods yourself. This is the
shape a `protoc` generator emits per message:

```mojo
@fieldwise_init
struct Tagged(Message):
    var x: Int64        # field 5
    var y: String       # field 12

    def __init__(out self):
        self.x = 0
        self.y = String("")

    def encoded_size(self) -> Int:
        return int64_field_size(5, self.x) + string_field_size(12, self.y)

    def encode_to(self, mut output: List[Byte]):
        write_int64(5, self.x, output)
        write_string(12, self.y, output)

    def merge_field(
        mut self, field_number: Int, wire_type: Int,
        data: Span[Byte, _], mut pos: Int,
    ) raises:
        if field_number == 5:
            self.x = read_int64(data, pos)
        elif field_number == 12:
            self.y = read_string(data, pos)
        else:
            skip_field(data, pos, wire_type)
```

## What's next

This is the contract the `protoc` code generator will emit: for each message in
a `.proto` file it will produce a struct like `Person` above, calling the
`write_*`/`read_*` helpers inside the generated `encode_to`/`merge_field`.
