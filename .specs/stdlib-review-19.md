## Adversarial Review: mojo-protobuf #19 (packed repeated scalar fields)

### Methodology

Files read in full / in part:
- `codegen/protoc_gen_mojo.py` (whole file; PACKED table @157-210, repeated branch
  in `gen_message` @295-354, `_check_field` @263-276, imports block @508-516).
- Runtime helpers: `src/protobuf/wire.mojo` (encode_varint/decode_varint @25-89,
  zigzag_encode @92, encode_fixed/decode_fixed @164-211), `src/protobuf/fields.mojo`
  (read_uint64/int64/sint64/bool @126-159, read_float/double @180-195, read_bytes
  @198-206), `src/protobuf/size.mojo` (varint_size @18, tag_size @28),
  `src/protobuf/message.mojo` (encode @422, decode @439).
- `test/proto/telem.proto`, `test/test_interop.py`, `benchmarks/bench_message.mojo`.

Generator runs:
- `pixi run test-codegen-unit` -> 10 pass.
- Generated `telem.mojo` and inspected.
- Adversarial proto `/tmp/adv19/proto/adv.proto` with EVERY packed type plus a
  trailing singular int32; generated `/tmp/adv19/adv.mojo` (compiled + ran).
- Negative proto `bad.proto` (repeated string) and `badmap.proto` (map) -> both error.
- Varint-only proto -> confirmed `encode_fixed` NOT imported (minimal imports).

Compile + run:
- Mojo round-trip of the all-types message with negatives / zeros / INT_MIN /
  UINT_MAX / large values: `encoded_size() == len(encode())` (142 == 142), all
  fields round-tripped (`ROUNDTRIP OK`). Empty message: empty repeated fields
  contribute 0.
- Safety: non-packed wire form (`0x08 0x05 0x08 0x07`) decodes to two int32 elems
  (forward-compat); malformed packed double (LEN=7, not a multiple of 8) RAISES
  rather than reading OOB.

Byte-exactness vs reference protobuf (`adv_pb2` via the pixi env):
- python `SerializeToString()` of the identical all-types message produced a hex
  string **byte-identical** to the Mojo `encode()` output (MATCH: True). This
  covers negative int32 (10-byte varint), zigzag sint32 incl. INT_MIN, bool,
  float (LE 4B), double (LE 8B), uint32/uint64 max.
- Full suite `pixi run test`: wire/fields/message/size + codegen-unit 10 +
  codegen-e2e 5 + interop 4 all pass.

### Issues Found (3 total)

#### Critical (0)
None. Per-type conversions, size==bytes, and byte-exactness all verified correct.

#### Factual Errors (0)
None.

#### Completeness Gaps (2)

1. **`test/test_interop.py:167-179` + `test/test_codegen.mojo`** — Committed
   round-trip/interop coverage exercises only `int64` (packed varint) and `double`
   (packed fixed64), via `telem.proto`. The other six packed types — `int32`
   (negative -> 10-byte varint), `uint32/uint64`, `sint32/sint64` (zigzag),
   `bool`, and `float` (fixed32) — have NO committed round-trip or byte-interop
   test. My adversarial run proves they are correct and byte-identical to the
   reference, but CI would not catch a future regression in those arms (e.g. a
   wrong width on float, or dropping the `Int64()` sign-extension on int32). Add
   at least one packed `sint32`, `bool`, `float`, and negative-`int32` case to
   `telem.proto`/the interop test.

2. **`codegen/protoc_gen_mojo.py:263-270` (`_check_field`)** — A `map<K,V>` field
   is rejected, but with the message "repeated of this type is not supported in
   v1 (only packed numeric scalars)" because protoc lowers a map to a synthetic
   repeated message entry, which hits the repeated-non-packable branch first. The
   PR/docstring claim "maps still raise a clear `GenError`"; it does raise, but
   the message is misleading (says "repeated", never "map"). Consider detecting
   `field.type == TYPE_MESSAGE and <map_entry>` to emit a map-specific message.
   (Behavior is safe — it errors — so this is a clarity gap, not a correctness bug.)

#### Inconsistencies (0)
None. Same `<value-expr>` (incl. each sign/zigzag/width conversion) is used in
both the `vsize` sum and the `vwrite` call for every type — verified per arm in
the generated `adv.mojo` (e.g. sint64 uses `varint_size(zigzag_encode(_v))` in
size and `encode_varint(zigzag_encode(_v))` in encode; int32 uses
`UInt64(Int64(_v))` in both).

#### Questions (0)
None outstanding.

#### Minor (1)

1. **PR body / `README` / generated headers** — The generated import lines exceed
   the 80-col convention when many packed types are present (e.g. the all-types
   `fields` import line). The PR already acknowledges this as pre-existing and a
   follow-up; noting it only for completeness. Not introduced by the packed logic
   beyond adding more symbols.

### Verified Correct

- **size == bytes (Critical check)**: For all 9 packed types, `encoded_size()`
  counts exactly what `encode_to()` appends. Empirically `encoded_size() == 142
  == len(encode())` on the all-types adversarial message; `List(capacity=...)`
  therefore reserves exactly. Empty repeated fields contribute 0 to both.
- **Per-type conversions** (each checked against the singular SCALAR arm, the
  wire spec, and byte-exact reference output):
  - int32: `encode_varint(UInt64(Int64(v)))` -> negative sign-extends to a 10-byte
    varint; read `Int32(read_int64(...))`. Byte-identical to reference for -1 /
    INT_MIN.
  - int64: `UInt64(v)`. uint32/uint64: direct varint. uint64 max round-trips.
  - sint32/sint64: `zigzag_encode(...)` / `zigzag_encode(Int64(v))`, read
    `read_sint64`. INT_MIN zigzag byte-identical to reference.
  - bool: `UInt64(1) if v else UInt64(0)`, size constant `1` (always exactly 1
    byte — correct), read `read_bool`. Compiles and round-trips.
  - float/double: `encode_fixed[DType.float32/64]` (value-only, LE), widths 4/8,
    read `read_float`/`read_double`. Byte-identical to reference; `encode_fixed`
    confirmed tag-less.
- **Decode safety/termination (Critical check)**: packed loop is
  `while p < len(blob): append(read_*(blob, p))`; every `read_*` advances `p` by
  >= 1 (varint) or by the fixed width, so the loop terminates. No varint is 0
  bytes. The `decode_varint` fast path uses `len(blob)` of the sub-span for its
  `>=10` guard, so no OOB past the blob; fixed reads (`decode_fixed`) bounds-check
  and raise on truncation — verified a non-multiple-of-width blob RAISES.
- **Non-packed forward-compat decode**: the `else` branch is correctly guarded by
  `if wire_type == WIRE_LEN` (packed) vs the scalar wire type (non-packed); a
  stream of `(tag,value)` pairs for a packed field appends each element. Verified.
- **Field ordering**: the repeated branch participates in `encode_items`/
  `size_items` keyed by field NUMBER and the final emit is sorted ascending; the
  packed tag uses `f.number`. Verified in generated output (fields 1..10 in order).
- **Imports**: minimal and exact — `encode_fixed` only when a fixed type is
  present (absent in a varint-only proto), `zigzag_encode` only for sint, plus
  `encode_tag/encode_varint/WIRE_LEN/tag_size/varint_size/read_bytes` for the
  packed framing. Generated files compile (no missing/unused-by-error symbols).
- **Robustness**: `repeated string` and `map` both raise `GenError` (no silent
  wrong code). `_check_field` order is sound; repeated+proto3_optional cannot
  co-occur in valid proto3 and the repeated branch is taken first regardless.
- **Runtime signatures**: every emitted call matches a real signature in
  `wire.mojo`/`fields.mojo`/`size.mojo`.
