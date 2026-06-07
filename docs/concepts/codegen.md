# Code generation

`protoc-gen-mojo` is a [protoc](https://protobuf.dev/) plugin that turns
`.proto` files into Mojo `Message` structs. protoc does the parsing and hands the
plugin a `CodeGeneratorRequest` (itself a protobuf message) on stdin; the plugin
walks the descriptors and writes the generated Mojo source back on stdout.

The plugin is written in Python (it reuses the mature `protobuf` library to read
descriptors) and emits **pure Mojo** that depends only on this runtime. A Mojo
rewrite is possible now that the runtime covers the wire features the
`CodeGeneratorRequest` itself uses, but reusing the reference descriptor parser
keeps the plugin small.

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
| `optional <scalar>` / `optional M` | `Optional[T]` | proto3 explicit presence |
| `oneof { ... }` | each member `Optional[T]` | at most one set (see below) |
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
key wins on decode. Each entry's bytes match the reference protobuf exactly;
entry *order* follows `Dict` iteration, which (like a proto map) is
unspecified.

### Oneofs

A `oneof` groups fields where at most one is set. Each member becomes its own
`Optional[T]` (message members included, so `sub` below is `Optional[Sub]`):

```proto
message M {
  oneof payload {
    string text = 3;
    int32 count = 4;
    Sub sub = 5;
  }
}
```

On the wire a oneof is nothing special: each member is a normal field with its
own number, and at most one is serialized. Encoding writes whichever member is
present; a scalar member set to its default value is still written (oneof
presence is independent of value). Decoding any member clears the others, so the
proto3 *last-one-wins* rule holds and a decoded message keeps at most one member
present. There is no `WhichOneof` accessor: test the members directly
(`if m.text:`). Setting a member does **not** auto-clear the others, so set at
most one yourself; messages produced by `decode` always satisfy this.

### Cross-file references

A field whose type is defined in an imported `.proto` resolves across files: the
generator builds a registry over every file protoc passes it (the targets plus
their transitive imports) and emits a `from <module> import <Struct>` line, where
the module path mirrors the source file (`foo/bar.proto` -> `foo.bar`).

```proto
// common.proto, package common
message Geo { double lat = 1; double lng = 2; }

// place.proto, package place
import "common.proto";
message Place { common.Geo location = 2; repeated common.Geo near = 3; }
```

`place.mojo` gets `from common import Geo` and fields `location: Geo`,
`near: List[Geo]`. A cross-file *enum* needs no import (it lowers to `Int32`);
its named constants live in the imported module. Generate the imported `.proto`
**as a generation target too** (pass both to protoc) and add the output dir to
the Mojo import path so the emitted module imports resolve. References that
would not compile are rejected with a clear error rather than emitted: a type
whose `.proto` is not a generation target (an ungenerated dependency, a proto2
file, or a well-known type), and a flattened struct name that would clash across
imported files or with a local struct.

### Well-known types

`google.protobuf.Timestamp` and `google.protobuf.Duration` map to the builtin
`protobuf.well_known` module (both are `{ int64 seconds = 1; int32 nanos = 2; }`)
instead of being generated; a field of either type emits
`from protobuf.well_known import Timestamp` / `Duration` and works as a singular,
repeated, or map-value field. No need to pass `timestamp.proto`/`duration.proto`
as a generation target. Other well-known types (`Any`, `Struct`, …) are not yet
backed and raise a clear error.

## Not yet supported

These raise a clear generator error rather than emitting wrong code:

- `fixed32/64`, `sfixed32/64`
- `group` (a deprecated proto2 feature) and proto2 syntax in general
- well-known types other than `Timestamp`/`Duration` (`Any`, `Struct`, …)

## Default-value omission

Encoding follows the canonical proto3 rule: a *plain* singular field that holds
its default value is omitted from the wire (a numeric/enum `0`, `false`, an empty
string or bytes, and an all-default — zero-size — nested message). The output is
byte-identical to the reference protobuf. `optional` fields, `oneof` members,
`repeated`, and `map` are unaffected: an `optional`/`oneof` scalar set to its
default *is* written (presence is tracked separately), and empty repeated/map
fields were already omitted.

One consequence: a plain singular message field has no presence bit, so an
explicitly-set-but-empty message and an unset one both omit. Mark the field
`optional` (or put it in a `oneof`) for an `Optional[M]` that distinguishes
present-but-empty from absent.
