## Adversarial Review: mojo-protobuf #31 (Timestamp/Duration well-known types)

### Methodology

Files read in full: `src/protobuf/well_known.mojo`, the `codegen/protoc_gen_mojo.py`
diff (`_WELL_KNOWN`, `_Resolver.message_type` reorder, `main()` registry build),
`codegen/test_protoc_gen_mojo.py` diff, `test/test_codegen.mojo` diff,
`test/test_interop.py` diff, `test/proto/wktime.proto`, `docs/concepts/codegen.md`,
`README.md`, `pixi.toml`, `src/protobuf/__init__.mojo`. Cross-checked the
hand-written runtime against the generator's int64/int32 emission
(`protoc_gen_mojo.py:84-101`) and the singular-default-omission guard
(`_default_guard`, `protoc_gen_mojo.py:360-372`) and the singular-message
`_sz > 0` guard from PR #30.

Byte-compares vs the reference protobuf (libprotoc 34.1, python protobuf 7.34.1
via `pixi run protoc`/`pixi run python`/`pixi run mojo`), all generated from an
`edge.proto` with `Timestamp at = 2; Duration d = 3;` and the PR's own generator:

| case | mojo bytes | ref bytes | match |
|---|---|---|---|
| typical (1700000000,500) | 18 9 8 128 226 207 170 6 16 244 3 | identical | OK |
| seconds-only | 18 6 8 128 226 207 170 6 | identical | OK |
| nanos-only | 18 3 16 244 3 | identical | OK |
| neg seconds (-5) | 18 11 8 251 255…255 1 | identical | OK |
| large nanos (999999999) | 18 6 16 255 147 235 220 3 | identical | OK |
| **neg nanos (-1)** | 18 11 16 255 255…255 1 (10-byte varint) | identical | OK |
| Duration neg both (-3,-250) | 26 22 8 253…1 16 134 254…1 | identical | OK |
| nanos INT32_MAX | 18 6 16 255 255 255 255 7 | identical | OK |
| nanos INT32_MIN | 18 11 16 128 128 128 128 248 255…1 | identical | OK |
| all-default Timestamp() | (empty — field omitted) | unset = (empty) | OK |
| nanos=1 only | 18 2 16 1 | identical | OK |

Round-trips verified for neg nanos, neg seconds, INT32 min/max nanos (all True).

Adversarial proto (nested message + oneof[Timestamp|Duration] + optional Timestamp
+ neg seconds) byte-matched the reference exactly
(`10 6 10 4 8 10 16 20 18 5 8 100 16 200 1 34 11 8 249 255…1`), all round-trips True.

User-Timestamp non-hijack: generated `package mypkg; message Timestamp{...}; message M{Timestamp t=1;}`
→ local `struct Timestamp` with NO `from protobuf.well_known` import; `var t: Timestamp`
references the local struct (`protoc_gen_mojo.py:330-336` exact dict `.get`, not suffix).

NFC: regenerated example/telem/enums/rep/maps/oneof/common/place with both the PR
generator and origin/main's generator → `diff -rq` IDENTICAL.

Suite (`pixi run test`): wire 28, fields 18, message 39, size 9, codegen-unit 22,
codegen-e2e 16, interop 20 — all green, matching the PR claim.

`well_known.mojo` compiles and imports as `from protobuf.well_known import Timestamp, Duration`;
no-arg init zeros both; `@fieldwise_init` gives `Timestamp(seconds, nanos)`; both
`Copyable` (verified in `List[Duration]` and `Dict[String, Timestamp]`).

### Issues Found (5 total)

#### Critical (0)
None. Wire encoding is byte-identical to the reference across every edge case
tested, including negative seconds/nanos, INT32 boundary nanos, and the
all-default-omission interaction with PR #30.

#### Factual Errors (0)
The PR/docs claim "byte-identical to the reference" is true (verified above).

#### Completeness Gaps (3)

1. **No regression test for negative seconds/nanos.** `test/test_codegen.mojo:340`
   (`test_codegen_well_known_types`) and the interop drivers
   (`test/test_interop.py:320,355`) use only non-negative values
   (1700000000/500/3/250/100/1699999999). The 10-byte sign-extended varint path
   (`well_known.mojo:38` `write_int64(2, Int64(self.nanos))`) is the part most
   likely to regress and is unguarded. I verified it is correct today, but a
   future change could break it silently. Mirrors the #30 review lesson (-0.0
   missed for lack of an edge test). Add a neg-seconds/neg-nanos round-trip +
   byte-compare case.

2. **No all-default-omission test.** No committed test sets `e.at = Timestamp()`
   and asserts field 2 is omitted (the PR-#30 interaction the description flags
   as a headline risk). I verified the singular `_sz_at > 0` guard
   (`gen wktime`/`gen_edge.mojo` encode path) omits it and it byte-matches the
   reference's unset case, but there is no regression guard. Add a case asserting
   an all-default Timestamp field encodes to 0 bytes (and a `Timestamp(0,1)` case
   asserting it IS emitted).

3. **No user-`Timestamp` non-hijack test.** The headline regression risk in
   Section B (a non-google `mypkg.Timestamp` must resolve to the local struct,
   not the builtin) has no committed unit test.
   `test_well_known_timestamp_resolves_to_builtin`
   (`codegen/test_protoc_gen_mojo.py:322`) only checks the positive case. I
   verified the negative case generates a local struct with no well_known import,
   but a one-line unit test (`package mypkg; message Timestamp` →
   assert "well_known" not in out) would lock it in.

#### Inconsistencies (0)

#### Questions (1)

4. **Targeting `timestamp.proto`/`duration.proto` produces an orphan module.**
   (`protoc_gen_mojo.py:328-336`, `main()` 1093-1112.) If a user *does* pass
   `google/protobuf/timestamp.proto` as a generation target, the WKT-first check
   means every field still imports from `protobuf.well_known`, but the targeted
   proto is ALSO generated as `google/protobuf/timestamp.mojo` defining its own
   `Timestamp` struct (verified). Result: a harmless unused/orphan module — no
   wire error and no in-file name clash, since no single generated file imports
   both. Not a realistic case (the point is you don't target the WKT proto).
   Acceptable, but consider skipping generation of `.proto` files whose package
   is `google.protobuf` and whose types are all in `_WELL_KNOWN`, or noting it in
   docs. Classified Question, not a defect.

#### Minor (1)

5. **`well_known.mojo` is a hand-maintained copy with no drift guard.**
   (`src/protobuf/well_known.mojo:1-8` docstring acknowledges this.) The structs
   exactly match the generator's emitted pattern today (int64 field 1 / int32
   field 2 via `write_int64(2, Int64(nanos))`, `Int32(read_int64(...))`,
   `!= 0` default guards — all confirmed against `protoc_gen_mojo.py:84-101` and
   `_default_guard:372`). The interop tests guard *wire correctness vs the
   reference*, so the module can't silently go wire-wrong. But nothing guards
   *internal consistency* with the generator: if a future codegen change altered
   the emitted pattern, this hand-copy would not follow. A small test that
   byte-compares a `well_known.Timestamp` against a freshly generated
   `{int64 seconds=1; int32 nanos=2;}` struct would catch drift. Maintenance
   note, not a current defect.

   Also (pre-existing, out of scope): `src/protobuf/__init__.mojo` docstring is
   stale ("Code generation … is still to come", lists only three layers, omits
   `protobuf.size` and now `protobuf.well_known`). The PR adds a new public
   module the package docstring doesn't mention; reasonable to leave for a
   docs-cleanup PR.

### Verified Correct

- Timestamp/Duration encode/decode byte-identical to the reference for typical,
  seconds-only, nanos-only, negative seconds, large nanos, **negative nanos**
  (10-byte sign-extended varint), INT32_MIN/MAX nanos, and Duration-negative-both.
- All-default `Timestamp()` singular field is omitted entirely (0 bytes),
  byte-identical to the reference's unset Timestamp (correct proto3 no-presence
  semantics; the reference's presence-set all-default `18 0` is unreachable in
  this no-presence model and correctly not produced). `Timestamp(0,1)` IS emitted.
- Singular / repeated (`List[Duration]`) / map-value (`Dict[String, Timestamp]`) /
  oneof (`Optional[Timestamp|Duration]`) / optional / nested-message WKT fields
  all resolve, compile, round-trip, and byte-match the reference.
- A user-defined non-google `Timestamp` (`mypkg.Timestamp`) is NOT hijacked —
  resolves to the local generated struct with no `well_known` import (exact
  full-name dict match).
- Existing protos (example/telem/enums/rep/maps/oneof/common/place) generate
  IDENTICALLY with the PR generator vs origin/main (pure NFC; the resolver
  reorder is an additive `_WELL_KNOWN.get` miss for non-google types).
- `well_known.mojo` compiles, importable, `@fieldwise_init` + zeroing no-arg
  init, conforms to `Message` + `Copyable` (usable in List/Dict).
- Generated import line is a single sorted `from protobuf.well_known import Duration, Timestamp`
  (no dangle, no duplicate, no collision).
- Both new unit tests pass (`test_well_known_timestamp_resolves_to_builtin`,
  `test_unsupported_well_known_type_errors`); `Any` still errors with "well-known
  type … not supported".
- Full suite green: wire 28, fields 18, message 39, size 9, codegen-unit 22,
  codegen-e2e 16, interop 20.
