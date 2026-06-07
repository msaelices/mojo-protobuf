# LiveKit bindings example

mojo-protobuf generating and using bindings for a real production schema:
[LiveKit](https://github.com/livekit/protocol)'s `livekit_models.proto`, used by
the LiveKit server and SDKs.

The `.proto` files under `proto/` are vendored **unmodified** from
`livekit/protocol` (Apache 2.0 — see the license header in each file).
`livekit_models.proto` alone is 51 messages and exercises essentially every
feature of the generator at once:

- nested messages and **repeated** nested messages (`ParticipantInfo.tracks`)
- **maps** (`ParticipantInfo.attributes: map<string, string>`)
- **enums**, including nested ones (`TrackType`, `ParticipantInfo.State`, …)
- **oneofs**
- **cross-file references** (`MetricsBatch` from `livekit_metrics.proto`)
- the **`google.protobuf.Timestamp`** well-known type (`RTPStats` timing fields)

The generated Mojo is wire-compatible with any other protobuf implementation, so
these structs interoperate directly with a LiveKit server or its Go/Rust/Python
SDKs.

## Run it

```bash
pixi run livekit-gen     # generate gen/*.mojo from proto/
pixi run livekit-demo    # build, encode, decode a ParticipantInfo + RTPStats
pixi run livekit-test    # round-trip regression test
```

`livekit-demo` and `livekit-test` generate the bindings first. The generated
`gen/*.mojo` is not committed (regenerated on demand), like the rest of the
project's protoc output.

## Generating your own

```bash
protoc -I examples/livekit/proto \
  --plugin=protoc-gen-mojo=codegen/protoc-gen-mojo \
  --mojo_out=OUTDIR \
  livekit_models.proto livekit_metrics.proto
```

Pass every `.proto` you reference as a generation target (here both
`livekit_models` and `livekit_metrics`, since the former imports the latter);
`google/protobuf/timestamp.proto` is handled by the builtin
`protobuf.well_known` module and does not need to be passed. `logger/options.proto`
is only needed by protoc to parse the custom field options and is not generated.
Add `src` and the output directory to the Mojo import path to use the result.
