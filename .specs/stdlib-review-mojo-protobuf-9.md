# Adversarial Review — mojo-protobuf PR #9 (Float32/Float64 field support)

Branch `reflection-floats`, base `main`. Pure-Mojo Protocol Buffers library.
Local mode: this review is written to `.specs/`, not posted to the PR.

## Methodology

- Read the full PR diff (`gh pr diff 9`): `src/protobuf/fields.mojo`,
  `src/protobuf/message.mojo`, `test/test_fields.mojo`, `test/test_message.mojo`,
  `docs/concepts/messages.md`.
- Read the sources of truth:
  - `src/protobuf/wire.mojo:145-215` (`encode_fixed32/64`, `decode_fixed32/64`)
    to confirm byte order.
  - `src/protobuf/size.mojo:55-62` (`fixed32_field_size`, `fixed64_field_size`).
  - Mojo stdlib `SIMD.to_bits` (`builtin/simd.mojo:2253-2275`) and
    `bitcast` (`memory/unsafe.mojo:33-60`) — confirmed reinterpret semantics,
    width constraints, and round-trip.
- Verified the protobuf encoding spec: `float` = `fixed32` (4 LE IEEE-754 bytes),
  `double` = `fixed64` (8 LE IEEE-754 bytes) — https://protobuf.dev/programming-guides/encoding/.
- Wrote and ran three Mojo probes via `pixi run mojo run -I src` (the pinned
  toolchain), then deleted them:
  1. Bit-pattern round-trip for +0.0, -0.0, positive, negative, large, subnormal,
     +Inf, -Inf, NaN — for both Float32 and Float64 — comparing via `.to_bits()`.
  2. Known-vector byte check: `write_float(1, 1.0f)`.
  3. Reflection name distinctness (`reflect[T].name()` for all 7 supported types)
     and `Vec3.encoded_size() == len(encode(Vec3(...)))`.
- Ran the full test suite (`pixi run test`): 60 tests, all pass.

## Issues Found (2 total)

### Critical (0)
None. Bit round-trip and wire bytes are provably correct (see Verified Correct).

### Factual error (0)
None.

### Completeness gap (1)

- **[test/test_fields.mojo:172-189, test/test_message.mojo:240]** — The added
  tests only cover ordinary finite values (`3.14`, `-2.5`). They do NOT cover the
  bit-pattern-preserving special values that are the entire point of a
  bit-for-bit float codec: **-0.0** (distinct sign bit from +0.0), **±Inf**, and
  **NaN** (which won't satisfy `assert_equal` via `==`, so a test must compare
  `.to_bits()`), plus subnormals. I probed all of these and they round-trip with
  exact bit preservation (table below), so this is a missing-test gap, not a bug.
  Recommend adding at least one test that round-trips `-0.0`, `+Inf`, `-Inf`, and
  a NaN, asserting equality of `x.to_bits[DType.uint32/uint64]()` before/after
  (NaN must use the bit comparison, since `NaN == NaN` is false).
  Source: IEEE-754 sign-bit / NaN semantics; protobuf treats float as raw bits
  (https://protobuf.dev/programming-guides/encoding/).

  Secondary, lower value: neither the field-layer test nor the Vec3 reflection
  test asserts that the encoded length equals `encoded_size()`
  (`fixed32_field_size`/`fixed64_field_size`). I verified `Vec3(3.14,-2.5)`
  encodes to exactly 14 bytes and `encoded_size()` returns 14, so the arms agree;
  a `len(encode(v)) == v.encoded_size()` assertion would lock this in cheaply.

### Inconsistency (1)

- **[src/protobuf/fields.mojo:80, :86]** — Minor: the `write_fixed32`/
  `write_fixed64` docstrings still advertise `float`/`double`
  ("`fixed32`/`sfixed32`/`float` field", "`fixed64`/`sfixed64`/`double` field")
  now that dedicated `write_float`/`write_double` helpers exist. This is not
  wrong (a caller can still hand those helpers `x.to_bits()`), but it's slightly
  confusing now that the canonical float path is elsewhere. Optional: drop the
  `float`/`double` mention or add "see `write_float`/`write_double`". Pure
  documentation nit; no code impact.

### Question (0)
None outstanding — all candidate concerns were resolved by probing.

### Minor (0)
(The docstring nit is filed under Inconsistency above.)

## Verified Correct

| Check | Result |
|---|---|
| `write_float` = `to_bits[uint32]` → `encode_fixed32` | Correct. `to_bits` (simd.mojo:2253) bitcasts to same-width uint then widening-casts; for f32→u32 it is a pure reinterpret (exact IEEE bits). Constraint `target unsigned & width ≥ source` satisfied. |
| `read_float` = `bitcast[float32](decode_fixed32)` | Correct. `bitcast` (unsafe.mojo:33) reinterprets; same-width constraint (u32↔f32) satisfied. |
| `write_double`/`read_double` (f64↔u64) | Correct, same reasoning at 64-bit width. |
| Endianness | `encode_fixed32/64` emit byte 0 = LSB (wire.mojo:152-155, 190-193); `decode_*` mirror it. Matches protobuf LE float/double layout. |
| **Known vector `1.0f`** | `write_float(1, 1.0f)` emits `0d 00 00 80 3f`: tag `0x0d` = (field 1 << 3) \| 5 (WIRE_I32); payload `00 00 80 3f` = exactly protobuf's expected bytes for `1.0f`. ✔ |
| **-0.0 (f32 & f64)** | Round-trips; sign bit preserved (`0x80000000` / `0x8000…00`). ✔ |
| **+Inf / -Inf (f32 & f64)** | Round-trips, exact bits. ✔ |
| **NaN (f32 & f64)** | Bit pattern (`0x7fc00000` / `0x7ff8…`) preserved exactly. ✔ |
| **Subnormal (f32 & f64)** | `0x1` preserved. ✔ |
| Positive / negative / large magnitude | All bit-exact. ✔ |
| Reflection name sentinels distinct | `reflect[Float32].name()` = `SIMD[DType.float32, 1]`, Float64 = `SIMD[DType.float64, 1]`, distinct from Int64/`SIMD[DType.int64,1]`, UInt64, Int, Bool, String. No collision. ✔ |
| `encoded_size` arm | `fixed32_field_size = tag_size+4`, `fixed64_field_size = tag_size+8` (size.mojo:55-62) == `len(write_float/double(...))` (tag + 4/8). Verified Vec3 → 14 == encoded_size 14. ✔ |
| decode arm mutation | `rebind[Float32](field_ref) = read_float(...)` writes back through `reflect[Self].field_ref[idx](self)`; Vec3 decode recovers both fields. ✔ |
| `from std.memory import bitcast` import | Correct module path (unsafe.mojo re-exported via `std.memory`). ✔ |
| Float32/Float64 default `0.0` | Valid literal defaults in Vec3 `__init__`. ✔ |
| Docs (`docs/concepts/messages.md`, trait docstring) | Updated to list `Float32`/`Float64` in supported types; accurate. ✔ |
| Full suite | 60 tests pass under `pixi run test`. ✔ |
