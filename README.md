# mojo-protobuf

A pure-[Mojo](https://www.modular.com/mojo) implementation of
[Protocol Buffers](https://protobuf.dev/).

> **Status: work in progress.** The wire-format runtime, the typed field layer,
> a reflection-derived typed-message API, and a `protoc` plugin
> (`protoc-gen-mojo`) for proto3 scalars, `optional`, and nested messages are
> implemented; repeated fields and enums are next.

## Why

Protobuf is the lingua franca of gRPC and many service protocols (Kubernetes,
LiveKit, data pipelines, …). There is no solid pure-Mojo implementation yet, so
Mojo code that needs to speak these protocols has to fall back to Python interop.
The goal of this project is to provide a native, fast, dependency-free protobuf
runtime and code generator.

## Example

Conform a struct to `Message` and you get protobuf serialization for free — the
wire format is derived from the fields by reflection, with no boilerplate:

```mojo
from protobuf.message import Message, decode, encode


@fieldwise_init
struct Point(Message):
    var x: Int
    var y: Int

    def __init__(out self):  # default-constructible, for decode()
        self.x = 0
        self.y = 0


@fieldwise_init
struct Line(Message):
    var start: Point         # a nested message — also just works
    var end: Point
    var label: String

    def __init__(out self):
        self.start = Point()
        self.end = Point()
        self.label = String("")


def main() raises:
    var data = encode(Line(Point(0, 0), Point(3, 4), "diagonal"))  # serialize
    var line = decode[Line](Span(data))                            # deserialize
    print(line.label, line.end.x, line.end.y)                      # diagonal 3 4
```

Make a scalar field `Optional[T]` for proto3 **explicit presence**: an absent
(`None`) field emits nothing and decodes back to `None`, so "unset" is
distinguishable from a default value.

Need custom field numbers or types reflection doesn't cover? Override
`encode_to` / `merge_field` / `encoded_size` — see
[the messages guide](./docs/concepts/messages.md).

## Code generation from `.proto`

`protoc-gen-mojo` is a [protoc](https://protobuf.dev/) plugin that emits Mojo
`Message` structs from `.proto` files:

```bash
protoc -I proto \
  --plugin=protoc-gen-mojo=codegen/protoc-gen-mojo \
  --mojo_out=src your.proto
```

Each message becomes a struct conforming to `Message` with the real (possibly
non-sequential) field numbers, so the generated code round-trips against the
reference protobuf implementation on the wire. v1 covers proto3 singular scalars,
`optional` scalars (explicit presence), and singular nested messages; repeated
fields, maps, oneofs, and enums raise a clear generator error for now. See
[the code generation guide](./docs/concepts/codegen.md).

## Documentation

Design notes and concept guides live in [`docs/`](./docs/):

- [The protobuf wire format](./docs/concepts/wire-format.md) — varints, ZigZag,
  field tags, and wire types.
- [Messages and fields](./docs/concepts/messages.md) — typed fields, the decode
  loop, and forward compatibility via `skip_field`.
- [Code generation](./docs/concepts/codegen.md) — the `protoc-gen-mojo` plugin,
  the proto-to-Mojo type mapping, and what it emits.

## Roadmap

1. ✅ **Wire-format runtime** (`protobuf.wire`) — varint / ZigZag / fixed-width /
   length-delimited codecs for the four protobuf wire types.
2. ✅ **Typed field layer** (`protobuf.fields`) — typed `write_*`/`read_*` helpers
   and `skip_field` for unknown fields.
3. ✅ **Typed-message API** (`protobuf.message`) — the `Message` trait with
   reflection-derived `encode`/`decode`/`encoded_size`, overridable per message.
4. ✅ **`protoc` plugin** (`protoc-gen-mojo`) — generate Mojo message structs from
   `.proto` files (proto3 scalars, `optional`, nested messages).
5. ⏳ **Repeated fields, maps, enums, oneofs** — in the runtime and the generator.
6. **Generated bindings** — real schemas such as
   [`livekit/protocol`](https://github.com/livekit/protocol).

## Development

This project uses [pixi](https://pixi.sh) for environment management.

```bash
# Install the environment (once)
pixi install

# Run the tests
pixi run test

# Format the code
pixi run format
```

## License

[MIT](./LICENSE) © Manuel Saelices
