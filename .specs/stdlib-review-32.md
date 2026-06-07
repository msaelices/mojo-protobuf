## Adversarial Review: mojo-protobuf #32 (RTPStats benchmark)

### Methodology

- Read the full diff (`git diff origin/main...bench-rtpstats`): bench.proto carve, all 4 harness deltas, run.sh, README, Cargo/build.rs, rtpstats.bin (new 207 B binary).
- Carve fidelity: fetched the real `livekit_models.proto` from `livekit/protocol` via `gh api`, extracted both `RTPStats` (minus the 4 `RTPDrift` fields) and the carved `RtpStats`, and diffed field-by-field by number/name/type with a Python script. Result: 41/41 fields identical, 0 diffs.
- Fixture validity: regenerated `bench_pb2` from the PR's bench.proto with protoc (in the pixi env) and decoded `rtpstats.bin` with the reference; checked populated fields and re-encoded for canonicality.
- Cross-language Timestamp-decode check: wrote throwaway decoders for Go (`timestamppb`), Rust (`prost_types`), and Mojo (`well_known`) that print start_time/end_time/last_pli/last_key_frame seconds+nanos, the gap_histogram map, and re-encode length. Restored each harness's source after.
- Ran `pixi run bash run.sh` 3 times; captured the rtpstats row for all four impls each time; checked stderr for panics.

### Issues Found (3 total)

#### Critical (0)
None. The benchmark is fair and every language genuinely decodes the message including the Timestamps.

#### Factual Errors (0)
None material. (See Inconsistency #1 for an over-precise wording.)

#### Completeness Gaps (0)
None.

#### Inconsistencies (1)

1. **"all four encode … byte-identical canonical output" is not literally true for prost** (`README.md:113-116`, PR body). Mojo, Go, and the Python reference all re-encode `rtpstats.bin` to byte-identical 207 B. **prost does not**: its re-encode is 207 B and struct-equal on round-trip, but the bytes differ starting at offset 128 (the `gap_histogram` map region) because prost stores maps in a `HashMap<i32,u32>` and emits entries in nondeterministic iteration order. The README sentence is hedged by the trailing "so all four encode the same number of bytes" (which IS true — 207 B for all four), and the encode bench still does the full real work, so timing fairness is unaffected. But the "byte-identical canonical output" phrase is overstated for the rtpstats/prost case. Minor wording; classify as Inconsistency, not a fairness bug. (Pre-existing `participant` has a string map too, so this caveat already applied; rtpstats just makes it more visible.)

#### Questions (0)

#### Minor (2)

1. **Stale "three messages" docstrings.** `run.sh:2-4` header comment and `py_bench.py:3-7` module docstring still say the suite covers "three messages" (packed/person/participant) and don't mention rtpstats. Output is unaffected; cosmetic. (`py_bench.py:1` docstring and `run.sh:2`.)

2. **README header comment in run.sh not updated** — same as above; the comment block lists only the three original messages while the awk now iterates four.

### Verified Correct

- **Same-bytes fairness**: all four harnesses read the identical `rtpstats.bin` (mojo `_read("rtpstats.bin")` from compare/, py HERE-relative, go `../rtpstats.bin` from go/, rust `../rtpstats.bin` from rust/). All paths resolve to the one committed 207 B file. Confirmed by decoding the same bytes in all four and getting identical values.
- **Fresh-message decode + touch, DCE-guarded encode**: rtpstats follows the exact pattern of the existing 3 messages. Decode: fresh message each iter, result touched (mojo `keep(Int(...packets))`, py `touch=lambda m: m.packets`, go fresh `&pb.RtpStats{}` + err check, rust `T::decode` + `black_box`). Encode: pre-decoded message re-encoded, guarded (mojo `keep(Bool(encode(...)))`, py `if not Serialize…: raise`, go `len(b)==0` panic, rust `assert!(!b.is_empty())`). None elided.
- **Carve verbatim vs real RTPStats minus RTPDrift**: 41/41 retained fields match the upstream `RTPStats` by number, name, and type exactly (verified programmatically against the live `livekit_models.proto`). Only the four `RTPDrift` fields (packet_drift=44, ntp_report_drift=45, rebased_report_drift=46, received_report_drift=47) are dropped. No renames/retypes/renumbers. Only cross-file dependency is `google.protobuf.Timestamp` — self-contained.
- **Fixture canonical**: reference decodes `rtpstats.bin` to a sane RtpStats (packets=540000, bytes=486000000, start_time=1700000000, end_time=1700000300/nanos=500000000, last_pli=1700000280, last_key_frame=1700000299/nanos=250000000, gap_histogram={1:300,2:15,4:4,8:1}, nacks=45, plis=12, key_frames=300, jitter_max=11.7) and re-encodes to byte-identical 207 B. last_fir and last_layer_lock_pli are absent (4 of the 6 Timestamps populated; all 6 exist in schema — description says "six Timestamp fields" referring to schema shape, accurate).
- **All four actually DECODE the Timestamps** (the key adversarial concern): no language skips/fails the WKT.
  - Go: generated `bench.pb.go` uses `*timestamppb.Timestamp` for all 6 fields and `map[int32]uint32` for the map; decode yields start_time=1700000000, end_time=1700000300/500000000ns, last_key_frame=1700000299/250000000ns; canonical re-encode True.
  - Rust: generated `cmp.rs` uses `::prost_types::Timestamp` for all 6 fields (extern_path applied) and `HashMap<i32,u32>`; decode yields identical Timestamp values; gap_histogram identical.
  - Mojo: `from protobuf.well_known import Timestamp`, `Dict[Int32, UInt32]`; decode yields identical Timestamp values; canonical re-encode True.
- **All four build + run**: `run.sh` exits 0 on all 3 runs, prints an rtpstats row for each impl, no panics/errors (only the pre-existing pixi `[project]`→`[workspace]` manifest deprecation warning on stderr). Go regenerates `bench.pb.go` with the timestamp import and compiles; Rust prost build compiles with extern_path + prost-types dep; Mojo gen compiles.
- **prost-types dep + Cargo.lock consistent**: prost-types "0.12" resolves and compiles under the repo's pinned Rust 1.80.1 (cargo 1.80.1) — README's 1.80 claim holds. No transitive edition bump observed.
- **Type names match**: proto `RtpStats` → Go `RtpStats`, Rust `RtpStats`, Mojo `RtpStats`. All compile and run.
- **Only intended files committed**: diff adds rtpstats.bin (only new binary) + touches README/proto/4 harnesses/run.sh/Cargo. `gen/`, `go/pb/`, `rust/target/` are gitignored and untracked.
- **Claims hold across re-runs** (see numbers below): mojo decode < go decode AND < upb decode (edges upb every run); mojo encode < go encode and ≈ prost (mojo even edged prost on encode all 3 runs); prost decode < mojo decode every run. The fragile "edges out upb on decode" claim held all 3 runs with a consistent ~120-180 ns gap (mojo ~720-790 vs upb ~905-955), direction never flipped — robust, not noise.

### Observed rtpstats numbers (your runs)

decode / encode ns/op, `pixi run bash run.sh`, 3 runs:

| impl            | run1 dec/enc | run2 dec/enc | run3 dec/enc |
|-----------------|--------------|--------------|--------------|
| mojo (ours)     | 768 / 264    | 724 / 249    | 786 / 289    |
| python — upb    | 954 / 680    | 905 / 677    | 905 / 692    |
| go — protobuf-go| 2454 / 2850  | 2523 / 2781  | 2551 / 2145  |
| rust — prost    | 383 / 299    | 427 / 277    | 429 / 387    |

README table (prost ~450/~290, mojo ~800/~280, upb ~1000/~650, go ~2750/~2300) matches observed runs within noise; not cherry-picked. Ordering identical to the claimed table every run.
