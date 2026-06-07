## Adversarial Review: mojo-protobuf #28 (LiveKit ParticipantInfo benchmark)

### Methodology
- Read full diff (`git diff origin/main...bench-livekit`): `bench.proto`, `mojo_bench.mojo`,
  `py_bench.py`, `go/main.go`, `rust/src/main.rs`, `run.sh`, `README.md`, plus the
  `participant.bin` fixture (235 B).
- Fetched the real `livekit/protocol` `protobufs/livekit_models.proto` (853 lines) via
  `gh api` and diffed the carved `ParticipantInfo` / `TrackInfo` / `VideoLayer` /
  `SimulcastCodecInfo` / `ParticipantPermission` / `DataTrackInfo` / `TimedVersion` /
  `Encryption` / enums field-by-field against it.
- Decoded `participant.bin` with the reference protobuf (regenerated `bench_pb2` from the
  PR's `bench.proto`): 2 tracks, attributes map `{device, region}`, permission with
  `can_publish_sources=[1,2]`. Confirmed `SerializeToString(deterministic=True)` is
  byte-identical to the fixture (canonical). Default non-deterministic re-encode differs
  only by map-entry order, same 235 B.
- Decoded the same fixture in Mojo via a harness-style reader: 2 tracks, `sid=PA_abc123`,
  2 attributes; Mojo re-encodes to 315 B (emits default scalars).
- Ran `pixi run bash benchmarks/compare/run.sh` 3 times (full toolchain: pixi protoc,
  go, cargo --release). Observed numbers below.
- Verified all four harnesses resolve to the identical `participant.bin` (md5
  `8b61565e...`) given their cwds, and each decodes into a FRESH message (no buffer reuse).
- Confirmed protoc/go/rust/mojo all compile the carved schema (no enum-value collision in
  `package cmp`; no top-level enum value name duplicates; no cross-file refs).

### Issues Found (5 total)

#### Critical (0)
None. Same-bytes fairness, fresh-decode, fixture validity, and cross-language correctness
all hold.

#### Factual Errors (1)
1. **Carved `ParticipantPermission` DROPS two real fields, not just options**
   (`benchmarks/compare/bench.proto:108-117`, the `ParticipantPermission` message).
   The real schema (`livekit_models.proto:108-133`) has `recorder = 8 [deprecated=true]`
   and `agent = 11 [deprecated=true]`. The carved version omits BOTH fields entirely
   (its numbers go 1,2,3,9,7,10,12,13). The PR body and the `bench.proto` header comment
   claim the carve is "verbatim" and that only `(logger.*)` and `deprecated` *options*
   were stripped. Two whole fields were removed, so that statement is inaccurate.
   Impact on the benchmark wire bytes: none (both are unset deprecated bools, default
   false, not present on the wire), so the timing is unaffected. But it (a) contradicts
   the "verbatim" claim, and (b) is inconsistent with how the same author treated
   `TrackInfo`, which KEPT its deprecated fields `simulcast=7`, `disable_dtx=8`,
   `layers=10`, `stereo=14` (stripping only their options). Fix: either re-add
   `bool recorder = 8;` and `bool agent = 11;` to `ParticipantPermission`, or soften the
   "verbatim" wording to note these two deprecated fields were dropped.

#### Completeness Gaps (0)
None beyond the field drop above. All other carved field numbers/types are verbatim:
`TrackInfo` 1-21 all match; `ParticipantInfo` top-level (1,2,3,4,5,6,17,9,10,11,12,13,14,
15,16,18,19,20) all match; `VideoLayer`, `SimulcastCodecInfo`, `DataTrackInfo`,
`TimedVersion`, `Encryption.Type`, and all enums (`TrackType`, `TrackSource`,
`VideoQuality`, `AudioTrackFeature`, `BackupCodecPolicy`, `PacketTrailerFeature`,
`DisconnectReason`, nested `State`/`Kind`/`KindDetail`/`Mode`) match the real schema
value-for-value. The closure is closed (no `google.protobuf.Timestamp` / metrics leak).

#### Inconsistencies (2)
1. **"Lands between prost and upb on decode" contradicts the data — including the PR's
   own table** (`README.md` Takeaway bullet vs the `participant` table; PR body table).
   The prose says mojo decode lands between `prost` and `upb`. But the README's own table
   lists prost ~1160 < upb ~1330 < **mojo ~1700** < go ~4340 — i.e. the table already
   puts mojo ABOVE (slower than) upb, not between. My 3 runs confirm mojo decode is
   slower than upb every time (mojo 1582/1944/1954 vs upb 1224/1295/1307). So mojo is the
   second-slowest decoder, behind upb, not "between prost and upb." The "between prost and
   upb on decode" wording should be corrected to something like "slower than prost and
   upb, ahead of protobuf-go."
2. **Mojo timing granularity favors mojo vs the other harnesses**
   (`mojo_bench.mojo:99` `num_repetitions=10` + `std.benchmark`'s auto-calibrated ~100
   iters/batch, vs `py_bench.py:50`/`go/main.go:32`/`rust/src/main.rs:23` fixed 50_000
   iters, best-of-5). `run.sh` takes min-of-10 of mojo's per-batch means (each a mean over
   only ~100 iters) but min-of-5 of the others' means over 50_000 iters. Min over finer
   batches selects a luckier minimum, mildly favoring mojo. This is pre-existing
   (packed/person) but it does affect the participant numbers; worth a one-line caveat.

#### Questions (1)
1. **Mojo participant numbers are noisy run-to-run (~1.7x spread)**. Across my runs the
   min-of-10 mojo decode mean ranged 1582-1954 ns in run.sh, but a standalone mojo run
   gave min ~2760 ns. Decode advantage over protobuf-go therefore ranges from ~1.3x
   (worst mojo run) to ~2.7x. The "~2.5x" headline is inside the observed range but not a
   floor; in an unlucky mojo run it drops toward ~1.8x or below. The README does say
   numbers are min-of-runs and approximate, which mitigates this, but the specific "~2.5x"
   is closer to a median-to-good run than a conservative one.

#### Minor (1)
1. **Stale docstring in `py_bench.py:4`**: still says "Times two messages — a packed
   numeric array (`packed.bin`) and a string-heavy record" though it now benches three
   (participant added at lines 60, 63-64). `mojo_bench.mojo`'s docstring WAS updated; this
   one was missed.

### Verified Correct
- **Same-bytes fairness across all 4**: mojo (`participant.bin`), py (`HERE/participant.bin`),
  go (`../participant.bin` from `go/`), rust (`../participant.bin` from `rust/`) all resolve
  to the identical file, md5 `8b61565e6556ebc0dbccab174fa8e33f`, 235 B.
- **Fixture is valid + canonical**: reference protobuf decodes it to a sane ParticipantInfo
  (2 tracks, attributes map, permission, kind/state); `SerializeToString(deterministic=True)`
  reproduces the exact 235 bytes. The only non-determinism is Python's default map-order
  randomization (semantically identical, same length).
- **Fresh-decode / no buffer reuse**: go `&pb.ParticipantInfo{}`, rust `T::decode(data)`,
  mojo `decode[ParticipantInfo](Span(part_data))`, py `cls.FromString(data)` — all
  construct a fresh message each iteration; none amortize allocation.
- **Decode/encode not dead-code-eliminated**: mojo `keep(len(...tracks))` / `keep(Bool(encode(...)))`,
  py `len(m.tracks)` touch + `if not msg.SerializeToString(): raise`, go `proto.Unmarshal`
  err-checked + `len(b)==0` panic, rust `black_box(&m)` + `assert!(!b.is_empty())`.
- **Encode work parity / conservative claim**: mojo encodes the message DECODED from the
  fixture (315 B output, emits defaults) vs go/rust/py encoding canonical 235 B. Mojo does
  MORE work and is still faster, so the "~8x faster encode" is conservative. Verified mojo
  re-encode = 315 B; README caveat documents the 315-vs-235 gap.
- **Carved field numbers/types match real LiveKit verbatim** for every type EXCEPT the two
  dropped deprecated bools in `ParticipantPermission` (Factual Error #1).
- **All 4 langs decode + run cleanly**: run.sh produced a participant row for each, no
  panics/errors; mojo decoded to 2 tracks / correct sid / 2 attributes (equivalent content
  to the reference). Mojo `TrackInfo.type` reserved-word handled by the generator (struct
  compiles).
- **No generated files committed**: `gen/`, `go/pb/`, `rust/target/`, `bench_pb2` are
  gitignored and untracked; only `participant.bin` added as a binary fixture.
- **No enum-value collision** in `package cmp`; protoc accepts the schema (no top-level
  enum value name duplicates).
- **Qualitative claims hold across all 3 re-runs**: mojo decode < go decode (beats
  protobuf-go) every run; mojo encode << go encode every run; mojo encode ~ prost every run.

### Observed numbers (your re-runs)
participant rows, ns/op (decode / encode):

```
            RUN1            RUN2            RUN3
mojo        1944 / 366      1954 / 367      1582 / 288
python(upb) 1307 / 613      1224 / 628      1295 / 817
go(prot-go) 3586 / 2601     4116 / 2625     4243 / 3586
rust(prost)  718 / 365      1001 / 335      1037 / 330
```

Ratios (mojo vs go): decode 1.84x / 2.11x / 2.68x; encode 7.1x / 7.2x / 12.4x.
Decode ordering every run: prost < upb < mojo < go (mojo is NOT between prost and upb).
Standalone mojo run min decode ~2760 ns (variance note, Question #1).
