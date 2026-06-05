# mojo-protobuf documentation

Design notes and concept guides for the project. The goal is that the knowledge
behind each change outlives the pull request that introduced it.

## Concepts

Background you need to understand the code — protocol and format explainers,
written for someone who programs but doesn't already know protobuf.

- [The protobuf wire format](concepts/wire-format.md) — how bytes encode fields:
  varints, ZigZag, field tags, and wire types, with worked examples.
- [Messages and fields](concepts/messages.md) — how a message is assembled from
  typed fields, the decode loop, and why `skip_field` enables forward
  compatibility.

## Design

Decisions specific to *this* implementation — public APIs, the code generator,
performance work. (Nothing here yet; the first design note will land with the
message API.)

## How this is organized

| Folder | Contains |
|---|---|
| `concepts/` | Background on protobuf itself (format, encoding, semantics). |
| `design/` | Choices we make in this codebase (APIs, codegen, SIMD fast paths). |

**Convention:** any PR that introduces a new area should add or update a page
here, so the explanation lives in the repo rather than only in the PR
description. Link new pages from this index.
