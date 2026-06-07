## Adversarial Review: mojo-protobuf #30 (default-value omission)

### Methodology

Files read:
- `codegen/protoc_gen_mojo.py` — `_default_guard` (lines 352-360), the three plain-singular
  arms: scalar `else` (848-863), bytes `else` (807-823), message `else` (758-781), plus the
  optional/oneof scalar arm (831-847) and `optional`/`oneof` message arm (735-757), and the
  `SCALAR` codec table incl. `TYPE_DOUBLE`/`TYPE_FLOAT` (70-140).
- `README.md`, `benchmarks/compare/README.md`, `docs/concepts/codegen.md`,
  `docs/concepts/messages.md` (155-165), `test/test_codegen.mojo`, `test/test_interop.py`.

Adversarial verification (all against the generator's real output, byte-compared to the
reference `protobuf` 7.34.1, `upb`/C backend):
- Generated `adv.proto` covering every scalar at default + non-default mixed in one message,
  negative/MIN/large-uint, sint zigzag, enum 0/non-zero/open-unknown, multi-byte UTF-8 string,
  empty/non-empty bytes, plain/deeply-nested all-default messages, all-default → zero-byte
  message, `optional` scalar set to default, `oneof` member set to default.
- Ran the Mojo encoder (`mojo run`) and the reference `SerializeToString()` from the same
  `.proto`, regenerated both `*_pb2` and `*.mojo`, and `diff`ed the octet lists.
- Asserted `len(encode(m)) == m.encoded_size()` for every message via the driver (no mismatch).
- `-0.0` round-trip in Mojo: encode then decode, inspected `to_bits()`.
- Re-encoded the LiveKit `participant.bin` (decode→encode) and length/byte-compared to 235 B.
- Confirmed the diff touches only the three plain-singular arms + `_default_guard`
  (no optional/oneof/repeated/map line changed) via `git diff | grep`.
- Confirmed `src/protobuf/` (reflection path) is untouched (`--stat`).
- Ran the full suite: wire 28, fields 18, message 39, size 9, codegen-unit 21, codegen-e2e 14,
  interop 17 — all green.

### Issues Found (3 total)

#### Critical (1)

1. **`-0.0` (and `-0.0f`) diverge from the reference on the wire and lose data on round-trip.**
   `codegen/protoc_gen_mojo.py:359` — `_default_guard` returns `"{acc} != 0"` for floats, so the
   generated guard is `if self.d != 0:`. In Mojo (as in IEEE-754) `Float64(-0.0) != 0` is
   **False**, so Mojo **omits** a `-0.0` field. The reference protobuf detects the float default
   by **bit pattern**, not numeric equality: `-0.0` has bits `0x8000000000000000` ≠ the `+0.0`
   default, so the reference **keeps** it. Byte evidence (`double d = 1`, `-0.0`):
   - Mojo:      `(empty — field omitted)`
   - reference: `9 0 0 0 0 0 0 0 128`  (tag 0x09 + 8 bytes of `-0.0`)
   - `float f = 2`, `-0.0f`: Mojo `(empty)` vs reference `21 0 0 0 128`.

   This is data loss, not just a size difference: a Mojo-encoded `-0.0` decodes back to `+0.0`
   (`encoded len: 0`, `decoded d bits: 0x0`). It directly contradicts the PR's headline claim
   ("byte-identical to the reference protobuf") and the README/codegen.md "byte-identical
   canonical output" wording. The correct proto3 rule for floats is bit-pattern equality to the
   default, e.g. `self.d.to_bits() != 0` (double) / `self.f.to_bits() != 0` (float), which keeps
   `-0.0`, `NaN`, and `+Inf` and omits only `+0.0`. (NaN and +Inf are already correct because
   `NaN != 0` and `Inf != 0` are True — verified below.) `cite codegen/protoc_gen_mojo.py:359`.

#### Factual Errors (1)

2. **Docs/PR claim "byte-identical to the reference protobuf" is false for negative zero.**
   `README.md` ("byte-identical to the reference protobuf on the wire"),
   `docs/concepts/codegen.md` Default-value omission section ("The output is byte-identical to
   the reference protobuf"), and `benchmarks/compare/README.md` ("all four encode the same number
   of bytes") are each falsified by issue 1 for any message containing a `-0.0`/`-0.0f` field.
   The claim is true for every *other* case tested (incl. NaN/Inf/MIN/enum/nested), but the
   unqualified "byte-identical" is incorrect. `cite README.md:84-86`,
   `cite docs/concepts/codegen.md:170-173`.

#### Completeness Gaps (1)

3. **No test covers the float-default edge cases (`-0.0`, NaN, Inf).** `test_codegen.mojo` and
   `test_interop.py` only exercise integer/string/bool/bytes/message defaults; the new
   `test_codegen_default_omission` (line 311) and `test_default_omission_byte_identical_to_
   reference` use `Person(id=42)` (no floats). A test asserting `-0.0` round-trips and/or that an
   `AllTypes` with `d = -0.0` is byte-identical to the reference would have caught issue 1.
   `cite test/test_interop.py:497-502`.

#### Inconsistencies (0)

#### Questions (0)

#### Minor (0)

### Verified Correct

- **Every non-float case is byte-identical to the reference** at default (omitted) and
  non-default (present): int32/64, uint32/64 (incl. `u32`/`u64` max), sint32/64 zigzag at 0 and
  -1, `Int32.MIN`/`Int64.MIN`, bool true/false, string (multi-byte UTF-8 `héllo` and empty),
  bytes (set and empty), enum (0 omitted, BLUE kept, open/unknown `99` kept), and a message
  mixing defaults + non-defaults. All octet-for-octet equal.
- **NaN and +Inf are kept and byte-identical** to the reference (`d_nan: 9 0 0 0 0 0 0 248 127`,
  `d_inf: 9 0 0 0 0 0 0 240 127`, `f_nan: 21 0 0 192 127` — same on both sides). Only `-0.0`
  diverges.
- **`+0.0` is correctly omitted** by both Mojo and the reference.
- **All-default message → 0 bytes** on both sides; **plain nested all-default omitted**;
  **deeply nested all-default chain** (`Deep`→`Mid`→`Inner`) omits everything, byte-identical;
  a single set leaf re-introduces the whole chain identically (`deep_inner_set: 10 4 10 2 8 1`).
- **`optional`/`oneof` unaffected**: `optional int32 = 0` still written (`opt_oi_zero: 8 0`),
  `optional double = 0.0` written (`opt_od_zero: 17 0 0 0 0 0 0 0 0`), `optional bool = false`
  written (`opt_ob_false: 24 0`), `oneof int32 = 0` written (`oneof_ci_zero: 8 0`), `oneof
  string = ""` written (`oneof_cs_empty: 18 0`) — all byte-identical to the reference. The diff
  changes **no** optional/oneof/repeated/map line (grep confirmed); oneof members route through
  `optional=True` (line 572) → `if self.x:` arm, never `_default_guard`.
- **`encoded_size()` matches `encode()` bytes for every message** (driver asserts equality; no
  SIZE_MISMATCH). The nested-message arm computes `_sz_x` once and uses the identical `> 0`
  guard in both `encode_to` and `encoded_size` (lines 763-775); the scalar/bytes arms use the
  identical guard in both blocks.
- **Decode unchanged** (diff only guards encode/size); omitted fields decode to default, every
  round-trip preserved — **except** the `-0.0` case (issue 1), where round-trip is lossy.
- **Generated guards compile for every scalar type** incl. `Float64`/`Float32` (`if self.f != 0`
  compiles and means value 0.0); lines are short/well-formed.
- **participant re-encodes to the canonical 235 B, byte-identical** (no `-0.0` floats in it), so
  the benchmark README's "235 B / same number of bytes" claim holds for that message.
- **Reflection path untouched** (`src/protobuf/message.mojo` not in the diff); `messages.md`
  note that the reflection default does NOT do canonical omission remains accurate.
- Full suite green: wire 28, fields 18, message 39, size 9, codegen-unit 21, codegen-e2e 14,
  interop 17.

### Numeric edge-case bytes (Mojo vs reference)

```
case          Mojo                          reference (protobuf 7.34.1, upb)
-----------   ---------------------------   -------------------------------------
d  +0.0       (omitted)                     (omitted)                        MATCH
d  -0.0       (omitted)                     9 0 0 0 0 0 0 0 128              MISMATCH
d  NaN        9 0 0 0 0 0 0 248 127         9 0 0 0 0 0 0 248 127            MATCH
d  +Inf       9 0 0 0 0 0 0 240 127         9 0 0 0 0 0 0 240 127            MATCH
f  -0.0       (omitted)                     21 0 0 0 128                     MISMATCH
f  NaN        21 0 0 192 127                21 0 0 192 127                   MATCH
i32 MIN       24 128 128 128 128 248 ... 1  24 128 128 128 128 248 ... 1     MATCH
i64 MIN       32 128 128 128 128 128 ... 1  32 128 128 128 128 128 ... 1     MATCH
```

Mojo `-0.0` round-trip: `encode(...)` → `len 0` → `decode` → `d bits 0x0` (sign bit lost).
Reference `-0.0` round-trip preserves `0x8000000000000000`.
```
