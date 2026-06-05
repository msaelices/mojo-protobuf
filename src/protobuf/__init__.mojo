"""mojo-protobuf: a pure-Mojo Protocol Buffers implementation.

This package is a work in progress. The planned surface area is:

- A wire-format runtime (varint / zigzag / length-delimited encode and decode).
- A `protoc` plugin that generates Mojo message structs from `.proto` files.
- Generated bindings for real schemas (e.g. `livekit/protocol`).

So far three layers are implemented:

- `protobuf.wire`: wire-format primitives (varints, ZigZag, field tags,
  fixed-width and length-delimited values).
- `protobuf.fields`: a typed field layer (typed `write_*`/`read_*` helpers and
  `skip_field` for unknown fields).
- `protobuf.message`: the `Message` trait and generic `encode`/`decode` for
  whole messages.

Code generation (a `protoc` plugin emitting `Message` structs) is still to come.
"""

comptime VERSION = "0.1.0"
"""The package version."""
