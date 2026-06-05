# mojo-protobuf

A pure-[Mojo](https://www.modular.com/mojo) implementation of
[Protocol Buffers](https://protobuf.dev/).

> **Status: work in progress.** The wire-format runtime and a typed field layer
> are implemented; a typed-message API and a `protoc` code generator are next.

## Why

Protobuf is the lingua franca of gRPC and many service protocols (Kubernetes,
LiveKit, data pipelines, …). There is no solid pure-Mojo implementation yet, so
Mojo code that needs to speak these protocols has to fall back to Python interop.
The goal of this project is to provide a native, fast, dependency-free protobuf
runtime and code generator.

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
3. ⏳ **Typed-message API** — structs with generated `encode`/`decode`.
4. **`protoc` plugin** — generate Mojo message structs from `.proto` files.
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
