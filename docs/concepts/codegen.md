# Code generation

`protoc-gen-mojo` is a [protoc](https://protobuf.dev/) plugin that turns
`.proto` files into Mojo `Message` structs. protoc does the parsing and hands the
plugin a `CodeGeneratorRequest` (itself a protobuf message) on stdin; the plugin
walks the descriptors and writes the generated Mojo source back on stdout.

The plugin is written in Python (it reuses the mature `protobuf` library to read
descriptors) and emits **pure Mojo** that depends only on this runtime. Writing
the plugin in Mojo would be circular: the request it must decode uses repeated
fields, enums, and oneofs that the runtime does not implement yet.

## Running it

```bash
protoc -I proto \
  --plugin=protoc-gen-mojo=codegen/protoc-gen-mojo \
  --mojo_out=src your.proto
```

`your.proto` becomes `your.mojo` under the `--mojo_out` directory. Add that
directory and `src` to the Mojo import path (`mojo run -I src -I out ...`).

## What it emits

Each message becomes a struct conforming to [`Message`](messages.md) with the
three wire methods written out explicitly, using the field's **real number** from
the `.proto` (not its position), so non-sequential and sparse field numbers work:

```proto
message Person {
  int64 id = 1;
  string name = 5;            // non-sequential
  optional int64 age = 8;     // explicit presence
  Point location = 10;        // nested message
}
```

generates a `struct Person(Message)` whose `encode_to`/`merge_field`/
`encoded_size` call `write_int64(1, ...)`, `write_string(5, ...)`, etc. This is
the same shape the [overriding section](messages.md#overriding-for-control) shows
by hand. Because the field numbers and wire types match the spec, the output
round-trips against the reference protobuf implementation on the wire (encode in
Mojo, decode in Python and vice versa).

## Type mapping (v1)

| proto3 type | Mojo type | notes |
|---|---|---|
| `double` / `float` | `Float64` / `Float32` | fixed64 / fixed32 |
| `int64` / `int32` | `Int64` / `Int32` | `int32` via the `int64` varint |
| `uint64` / `uint32` | `UInt64` / `UInt32` | |
| `sint64` / `sint32` | `Int64` / `Int32` | ZigZag |
| `bool` | `Bool` | |
| `string` | `String` | UTF-8 validated on decode |
| `bytes` | `List[Byte]` | owns its data (copied out of the input) |
| message `M` | `M` | length-delimited nested message |
| `optional <scalar>` | `Optional[T]` | proto3 explicit presence |
| `repeated <scalar>` | `List[T]` | proto3 **packed** (see below) |
| `repeated string`/`bytes`/`M` | `List[String]` / `List[List[Byte]]` / `List[M]` | non-packed (see below) |
| `map<K, V>` | `Dict[K, V]` | see below |
| `enum E` | `Int32` | + `comptime E_VALUE = Int32(n)` constants |

Nested message *definitions* (a `message` declared inside another) are flattened
to top-level structs named `Outer_Inner`. Generated structs are `Copyable`, so
they can be held in a `List` and built with list literals
(`r.tags = [Tag("k", "v")]`).

### Enums

A proto3 `enum` is wire-identical to `int32` (a two's-complement varint) and is
*open* — unknown values are preserved — so an enum field becomes a bare `Int32`
and the named values are emitted as module-level constants,
`comptime <Enum>_<VALUE> = Int32(n)` (nested enums flatten to `Outer_Inner`).
Compare and assign with the constants: `thing.color = Color_GREEN`. `repeated`
enums pack like `repeated int32`.

### Packed repeated scalars

A `repeated` numeric/bool field becomes a `List[T]` and is encoded **packed**
(proto3 default): one length-delimited field holding the values back-to-back,
no per-element tags (varint types as back-to-back varints, `float`/`double` as
back-to-back fixed-width). On decode both forms are accepted — the packed
length-delimited blob and the non-packed one-tag-per-element form — per the
proto3 spec. The output is byte-identical to the reference protobuf.

### Non-packed repeated (string / bytes / message)

`repeated string`, `repeated bytes`, and `repeated <message>` are **not** packed
(proto3 only packs numeric scalars): each element is its own `tag + value` field,
emitted once per element on encode and appended on each occurrence on decode.
They map to `List[String]`, `List[List[Byte]]`, and `List[M]`.

### Maps

A `map<K, V>` becomes a `Dict[K, V]`. On the wire a map is sugar for a
non-packed `repeated` entry message `{ K key = 1; V value = 2; }`, so each pair
encodes as its own length-delimited submessage. Keys are integral, `bool`, or
`string`; values may be any singular type (scalar, `string`, `bytes`, nested
message, or `enum`). Unlike normal proto3 fields, a map entry always serializes
both key and value even at their default value, and the last occurrence of a
key wins on decode. The output is byte-identical to the reference protobuf.

## Not yet supported

These raise a clear generator error rather than emitting wrong code:

- `oneof`
- `fixed32/64`, `sfixed32/64`
- `group` (a deprecated proto2 feature) and proto2 syntax in general
- cross-file message references (a field whose type is defined in an imported
  `.proto`)

Singular message fields are modeled as a plain nested struct (always encoded),
not `Optional[M]`, so message-level presence is not yet distinguished from an
empty message; canonical proto3 omission of default-valued scalars is likewise a
follow-up.
