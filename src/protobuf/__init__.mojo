"""mojo-protobuf: a pure-Mojo Protocol Buffers implementation.

This package is a work in progress. The planned surface area is:

- A wire-format runtime (varint / zigzag / length-delimited encode and decode).
- A `protoc` plugin that generates Mojo message structs from `.proto` files.
- Generated bindings for real schemas (e.g. `livekit/protocol`).

Nothing is implemented yet beyond this scaffold.
"""

comptime VERSION = "0.1.0"
"""The package version."""
