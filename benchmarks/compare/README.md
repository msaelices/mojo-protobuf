# Cross-implementation benchmark

Decode/encode across mojo-protobuf and the popular protobuf libraries, on the
**same wire bytes**, for two messages:

- **`packed`** — a packed `repeated int64` of 2000 small values (`packed.bin`):
  the bulk-numeric path, where Mojo's SIMD decode applies.
- **`person`** — a string-heavy record: id, name, email, bool, double, int32,
  and a nested `Address` (`person.bin`): no SIMD path, dominated by `String`
  allocation and UTF-8 validation.

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

| implementation             | decode    | encode |
|----------------------------|-----------|--------|
| rust — prost (`--release`) | ~180      | ~50    |
| python — upb (C backend)   | ~550      | ~250   |
| go — protobuf-go           | ~700      | ~440   |
| **mojo-protobuf (ours)**   | **~1000** | ~100   |

## Takeaway

The two messages tell opposite stories, and both are honest:

- **Numeric decode is where Mojo wins.** Packed varints go through a SIMD fast
  path (`read_packed_signed`) and there's no FFI boundary, so mojo-protobuf
  decodes the numeric array ~2x faster than `prost` and ~3x faster than the
  C-backed `upb`.
- **String-heavy decode is where Mojo loses.** Decoding the `person` record is
  the *slowest* of the four — each `String` field allocates and UTF-8-validates,
  and the decode path isn't tuned the way the mature libraries are (`prost` is
  ~5x faster here). This is the clearest "not yet" in the library.

Encode is workload-dependent: mid-pack on the numeric array (behind `upb`'s tuned
encoder), competitive on the small record.

## Caveats

- `python(upb)` decode includes materializing the Python message object — the
  interop cost a native codec avoids, and part of the point — so this is
  *protobuf-from-Python*, not upb's raw C parse in isolation.
- `protobuf-go` is the pure-Go reference (reflection-based): not Go's fastest
  option, but what most Go code uses.
- Numbers are min-of-runs on one machine and vary run to run; reproduce with
  `run.sh`.
