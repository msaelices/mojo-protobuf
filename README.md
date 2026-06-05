# mojo-protobuf

A pure-[Mojo](https://www.modular.com/mojo) implementation of
[Protocol Buffers](https://protobuf.dev/).

> **Status: work in progress.** The wire-format runtime, the typed field layer,
> and a reflection-derived typed-message API are implemented; a `protoc` code
> generator is next.

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
    var label: String

    def __init__(out self):  # default-constructible, for decode()
        self.x = 0
        self.y = 0
        self.label = String("")


def main() raises:
    var data = encode(Point(3, 4, "origin"))   # serialize
    var p = decode[Point](Span(data))          # deserialize
    print(p.x, p.y, p.label)                   # 3 4 origin
```

Need custom field numbers or types reflection doesn't cover? Override
`encode_to` / `merge_field` / `encoded_size` — see
[the messages guide](./docs/concepts/messages.md).

## Documentation

Design notes and concept guides live in [`docs/`](./docs/):

- [The protobuf wire format](./docs/concepts/wire-format.md) — varints, ZigZag,
  field tags, and wire types.
- [Messages and fields](./docs/concepts/messages.md) — typed fields, the decode
  loop, and forward compatibility via `skip_field`.

## Roadmap

1. ✅ **Wire-format runtime** (`protobuf.wire`) — varint / ZigZag / fixed-width /
   length-delimited codecs for the four protobuf wire types.
2. ✅ **Typed field layer** (`protobuf.fields`) — typed `write_*`/`read_*` helpers
   and `skip_field` for unknown fields.
3. ✅ **Typed-message API** (`protobuf.message`) — the `Message` trait with
   reflection-derived `encode`/`decode`/`encoded_size`, overridable per message.
4. ⏳ **`protoc` plugin** — generate Mojo message structs from `.proto` files.
5. **Generated bindings** — real schemas such as
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
