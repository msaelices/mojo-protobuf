# Cross-implementation benchmark

Decode/encode across mojo-protobuf and the popular protobuf libraries, on the
**same wire bytes**, for three messages:

- **`packed`** — a packed `repeated int64` of 2000 small values (`packed.bin`):
  the bulk-numeric path, where Mojo's SIMD decode applies.
- **`person`** — a string-heavy record: id, name, email, bool, double, int32,
  and a nested `Address` (`person.bin`): no SIMD path, dominated by `String`
  allocation and UTF-8 validation.
- **`participant`** — a real LiveKit `ParticipantInfo` (`participant.bin`):
  carved verbatim from `livekit/protocol` (two `TrackInfo`s with nested video
  layers, a `map<string,string>` of attributes, permissions, several enums).
  This is the message LiveKit's Go server actually serializes, so the
  head-to-head against `protobuf-go` is the one that matters.

Each harness times one decode / one encode per op, warm, best of several runs.

## Running

```bash
pixi run bash benchmarks/compare/run.sh   # needs Go + Rust toolchains on PATH
```

Generated bindings (`gen/`, `go/pb/`, `rust/target/`) are not committed; the
script regenerates them. `protoc-gen-go` (`go install
google.golang.org/protobuf/cmd/protoc-gen-go@latest`) is required for the Go
harness; Rust uses `prost` via `cargo` (`Cargo.lock` pins versions compatible
with Rust 1.80).

## Results (one machine; ns/op, lower is better)

`packed` — 2000-value numeric array:

| implementation             | decode      | encode  |
|----------------------------|-------------|---------|
| **mojo-protobuf (ours)**   | **~1400**   | ~5000   |
| rust — prost (`--release`) | ~2500       | ~6000   |
| python — upb (C backend)   | ~4400       | ~1700   |
| go — protobuf-go           | ~12000      | ~13000  |

`person` — string-heavy record:

| implementation             | decode   | encode |
|----------------------------|----------|--------|
| rust — prost (`--release`) | ~180     | ~50    |
| **mojo-protobuf (ours)**   | **~620** | ~80    |
| python — upb (C backend)   | ~640     | ~240   |
| go — protobuf-go           | ~720     | ~470   |

`participant` — real LiveKit `ParticipantInfo`:

| implementation             | decode    | encode   |
|----------------------------|-----------|----------|
| rust — prost (`--release`) | ~1000     | ~340     |
| python — upb (C backend)   | ~1280     | ~620     |
| **mojo-protobuf (ours)**   | **~1750** | **~330** |
| go — protobuf-go           | ~4000     | ~2900    |

## Takeaway

The three messages tell complementary, honest stories:

- **Numeric decode is where Mojo wins.** Packed varints go through a SIMD fast
  path (`read_packed_signed`) and there's no FFI boundary, so mojo-protobuf
  decodes the numeric array ~2x faster than `prost` and ~3x faster than the
  C-backed `upb`.
- **String-heavy decode is where Mojo trails.** On the `person` record Mojo is
  now level with `upb` and `go` after an ASCII fast path that skips full UTF-8
  validation for the common case, but still behind `prost` (~4x). The remaining
  gap is per-field `String` allocation, which the mature libraries do more
  cheaply — the next thing to tune.
- **On the real LiveKit message, Mojo beats `protobuf-go` on both sides:**
  it **encodes ~6-8x faster** (a large, stable margin) and **decodes faster
  too** — typically ~2x in clean runs, though Mojo's decode is the noisiest of
  the four, so under machine load that margin narrows. On decode Mojo is still
  behind `prost` and the C-backed `upb` (the same per-field `String` allocation
  gap as `person`, now mixed with nested-message work); on encode it matches
  `prost`. Beating the Go reference — the library LiveKit's server actually
  uses — on a production message is the headline result for the project's goal.

Encode is workload-dependent: mid-pack on the numeric array (behind `upb`'s tuned
encoder), competitive-to-leading on the records.

## Caveats

- `python(upb)` decode includes materializing the Python message object — the
  interop cost a native codec avoids, and part of the point — so this is
  *protobuf-from-Python*, not upb's raw C parse in isolation.
- `protobuf-go` is the pure-Go reference (reflection-based): not Go's fastest
  option, but what most Go code uses.
- All harnesses **decode the same canonical bytes** (`participant.bin`, written
  by the reference). On encode, mojo-protobuf does not yet omit default-valued
  scalars, so its output is larger than canonical (315 B vs 235 B here); the
  encode timing is still "serialize this message", and forward-decode is
  unaffected. Default omission is a tracked follow-up.
- The `participant` schema is carved from `livekit/protocol`'s
  `livekit_models.proto` (ParticipantInfo + TrackInfo + their dependency
  closure), with custom `(logger.*)` and `deprecated` field options stripped —
  options never change the wire format, so the bytes are real LiveKit bytes.
- The harnesses time differently: Mojo uses `std.benchmark` (auto-calibrated
  batches, min of 10 repetitions), the others a hand-rolled warm loop (min of 5
  over 50k iters). The granularity differs, so treat small gaps as ties — the
  cross-impl ratios here are large enough to survive it, but don't read precision
  into them.
- Numbers are min-of-runs on one machine and vary run to run. Mojo's
  `participant` decode is the most variable (~1.6k ns clean, up to ~4k under
  load) while `protobuf-go` sits steadily near ~4k; reproduce with `run.sh` and
  read the ratios, not the absolute values.
