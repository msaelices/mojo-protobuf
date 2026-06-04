# mojo-protobuf

A pure-[Mojo](https://www.modular.com/mojo) implementation of
[Protocol Buffers](https://protobuf.dev/).

> **Status: early scaffold.** No functionality is implemented yet — this repo
> currently only sets up the project structure, tooling, and CI.

## Why

Protobuf is the lingua franca of gRPC and many service protocols (Kubernetes,
LiveKit, data pipelines, …). There is no solid pure-Mojo implementation yet, so
Mojo code that needs to speak these protocols has to fall back to Python interop.
The goal of this project is to provide a native, fast, dependency-free protobuf
runtime and code generator.

## Roadmap

1. **Wire-format runtime** — varint / zigzag / length-delimited encode and
   decode for the four protobuf wire types.
2. **Message API** — a way to declare and (de)serialize messages.
3. **`protoc` plugin** — generate Mojo message structs from `.proto` files.
4. **Generated bindings** — real schemas such as
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
