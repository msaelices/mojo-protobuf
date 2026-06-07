# Cross-implementation benchmark

Decode/encode of a packed `repeated int64` message (2000 small, 1-byte values)
across mojo-protobuf and the popular protobuf libraries, on the **same wire
bytes** (`packed.bin`, byte-identical across all four). Each harness times one
decode / one encode per op, warm, and reports the best of several runs.

## Running

```bash
pixi run bash benchmarks/compare/run.sh   # needs Go + Rust toolchains on PATH
```

Generated bindings (`gen/`, `go/pb/`, `rust/target/`) are not committed; the
script regenerates them. `protoc-gen-go` (`go install
google.golang.org/protobuf/cmd/protoc-gen-go@latest`) is required for the Go
harness; Rust uses `prost` via `cargo` (`Cargo.lock` pins versions compatible
with Rust 1.80).

## Results (one machine; lower is better)

| implementation            | decode    | encode    |
|---------------------------|-----------|-----------|
| **mojo-protobuf (ours)**  | **~1.2 us** | ~4.3 us |
| rust — prost (`--release`)| ~2.7 us   | ~6.0 us   |
| python — upb (C backend)  | ~4.1 us   | ~1.7 us   |
| go — protobuf-go          | ~12 us    | ~12 us    |

On this workload mojo-protobuf **decodes fastest** — roughly 2x faster than
`prost` and 3x faster than the C-backed `upb` — because the packed-varint decode
runs through a SIMD fast path (`read_packed_signed`) and there is no FFI boundary
to cross. Encode is mid-pack (faster than prost/go, behind upb's tuned encoder).

## Honest caveats

- **This is the bulk-numeric case, where Mojo's SIMD decode shines.** A
  string-heavy or mixed-scalar message would narrow or reverse the decode gap —
  the mature libraries are highly tuned across all field types, and `upb` is C.
- `python(upb)` decode includes materializing the Python message object (the
  interop cost a native codec avoids); that overhead is part of the point, but
  it means this is *protobuf-from-Python*, not upb's raw C parse in isolation.
- `protobuf-go` is the pure-Go reference implementation (reflection-based); it is
  not Go's fastest option but is what most Go code uses.
- Numbers are min-of-runs on one machine and will vary; reproduce with `run.sh`.
