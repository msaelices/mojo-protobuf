# Adversarial Review: PR #6 — Add serialized-size computation (`protobuf.size`)

Repo: msaelices/mojo-protobuf · Branch: `size-layer` (base `main`)

## Methodology

Read the full diff (`src/protobuf/size.mojo`, `test/test_size.mojo`, `pixi.toml`) and the
two authoritative encoders it must mirror: `src/protobuf/wire.mojo` and
`src/protobuf/fields.mojo`. Cross-referenced varint byte counts and tag layout against the
protobuf encoding spec (<https://protobuf.dev/programming-guides/encoding/>): a varint needs
`ceil(bitlength/7)` bytes (min 1, max 10 for 64-bit); `tag = (field_number << 3) | wire_type`;
fixed32 = 4 bytes, fixed64 = 8 bytes; length-delimited = `varint(len) + len`.

Verification was not by inspection alone. Two probes were compiled and run:

1. A Python model exhaustively checking varint boundaries and the `tag_size`
   wire-type-independence claim over field numbers `1..2^20` and the 1000 values below
   `2^29-1`, for all wire types `0..7`.
2. A Mojo probe (`mojo run -I src`) cross-checking **every** `<type>_field_size` helper
   against the real `protobuf.fields` `write_*` encoder output `len()`, including the helpers
   the PR's own tests do NOT cross-check, plus negative/`MIN` int64, `UInt64.MAX`, the max
   legal field number `2^29-1`, and empty string/bytes.

Both probes passed with zero mismatches. The size math is numerically correct.

## Issues Found (4 total)

### Critical (0)

None. Every size helper was proven (by compiled cross-check against the real encoders) to
equal `len(encoded)`, so there is no buffer-under-reservation risk.

### Factual Errors (0)

None. The module docstring's central claim — `<type>_field_size(...)` always equals
`len(encoded)` — holds for every helper and every probed boundary.

### Completeness Gaps (2)

1. **[test/test_size.mojo]** — Five of the eight field-size helpers are NOT cross-checked
   against their real encoders; they are only asserted against hand-computed constants.
   Cross-checked against `write_*`: `int64_field_size`, `sint64_field_size`,
   `string_field_size` only (tests `test_int64_field_size_matches_encoding`,
   `test_sint64_field_size_matches_encoding`, `test_string_field_size_matches_encoding`).
   Asserted only against literals (`test_constant_field_sizes`, `test_bytes_field_size`):
   `uint64_field_size`, `bool_field_size`, `fixed32_field_size`, `fixed64_field_size`,
   `bytes_field_size`. The PR body explicitly sells the tests as the guarantee that "the size
   math can't silently drift from the writers," but for these five helpers the test asserts a
   hand-written constant, not `len(write_*(...))` — so the anti-drift guarantee does not
   actually cover them. A probe confirms they currently match
   (`uint64_field_size(3, UInt64.MAX) == len(write_uint64(3, UInt64.MAX, buf)) == 11`,
   `fixed32 == 5`, `fixed64 == 9`, `bool == 2` for both `True`/`False`,
   `bytes_field_size(4, span3) == 5`), but the suite does not lock that. Recommend adding
   `*_field_size(...) == len(write_*(...))` assertions for all five, mirroring the existing
   three matches-encoding tests.

2. **[test/test_size.mojo]** — Missing the `varint_size` 3→4 byte boundary and large-but-not-
   max coverage. The varint test stops at `16384` (3 bytes) and jumps straight to
   `UInt64.MAX` (10 bytes). The 9→10 transition and intermediate boundaries (`2^21-1`/`2^21`,
   etc.) are untested. Low risk given the loop is generic, but the 10-byte max is the one a
   buggy `>=` vs `>` would most plausibly get wrong, so one value just below it
   (e.g. `2^63`, 10 bytes; `2^56-1`, 8 bytes) would harden the test.

### Inconsistencies (1)

1. **[src/protobuf/size.mojo:30 `tag_size`]** — No field-number validation, unlike the
   encoder it mirrors. `encode_tag` (`src/protobuf/wire.mojo:107-108`) asserts
   `field_number >= 1` and `field_number <= 0x1FFFFFFF`. `tag_size` (and therefore every
   `*_field_size` helper) performs no such check, so for an out-of-range field number the two
   diverge: `tag_size(-1)` returns `10` (because `UInt64(-1) << 3` is a huge value) and
   `tag_size(0)` returns `1`, whereas `write_*(-1, ...)` / `write_*(0, ...)` would abort on
   the assert rather than produce any length. The module docstring's "always equals
   `len(encoded)`" is therefore only true on the encoder's *valid* domain. For valid field
   numbers `1..2^29-1` the two match exactly (probe-confirmed at `2^29-1`). Recommend either
   adding the same two asserts to `tag_size`, or narrowing the docstring to state the valid
   domain. Note the int-shift vs uint64-shift difference is benign here: `encode_tag` does
   `(field_number << 3) | wire_type` as a 64-bit `Int` shift before casting, `tag_size` does
   `UInt64(field_number) << 3`; for `field_number <= 2^29-1` both stay well within 64 bits and
   produce identical lengths (verified).

### Questions (1)

1. **[src/protobuf/size.mojo:30 `tag_size`]** — Dropping `wire_type` from the size
   computation: confirmed **always size-exact** on the valid field-number domain, so this is
   not a defect — raised only to record the proof. Because `field_number << 3` has its low 3
   bits zero, OR-ing any `wire_type` in `0..7` only sets those low 3 bits, keeping the value
   within `[field_number<<3, field_number<<3 + 7]`. Every varint length boundary is at
   `2^(7k)` (`128, 16384, ...`), each a multiple of 8; so `field_number<<3` (also a multiple
   of 8) is either already `>=` the boundary or `<= boundary - 8`, and `+7` cannot cross it.
   Exhaustively verified for all field numbers `1..2^20` and the 1000 below `2^29-1`, across
   all 8 wire types: zero mismatches. No action needed.

### Minor (0)

None. The functions are correctly non-raising `def`s (no `raises` needed since they only do
arithmetic), `bytes_field_size` correctly takes `Span[Byte, _]`, `string_field_size`
delegates via `value.as_bytes()` exactly as `write_string` does (`fields.mojo:98`), and the
docstrings are concise one-liners. `pixi.toml` correctly wires `test-size` into the aggregate
`test` task.

## Verified Correct

- `varint_size`: `0→1, 127→1, 128→2, 16383→2, 16384→3, UInt64.MAX→10` — all confirmed by
  compiled Mojo run. Loop `n=1; v=value>>7; while v>0: n+=1; v>>=7` is off-by-one-free at the
  7-bit boundaries and produces exactly `ceil(64/7)=10` at the max. Consistent with
  `decode_varint`'s 64-bit (10-byte) acceptance limit (`wire.mojo:61`).
- `tag_size`: matches `len(encode_tag(...))` for valid field numbers including `2^29-1`
  (probe: `tag_size(2^29-1)==5`).
- `uint64_field_size`/`int64_field_size`/`sint64_field_size`/`bool_field_size`/
  `fixed32_field_size`/`fixed64_field_size`/`bytes_field_size`/`string_field_size`: each equals
  `len(write_*(...))` — probe-confirmed, including `int64` two's-complement `-1→10` and
  `Int64.MIN→10`, `sint64` ZigZag, empty string/bytes (`tag + varint(0) = 2`), and multi-byte
  UTF-8 `"héllo"` (6 UTF-8 bytes → `tag + 1 + 6 = 8`).
- `int64_field_size` uses `varint_size(UInt64(value))` (two's complement) and
  `sint64_field_size` uses `varint_size(zigzag_encode(value))`, matching `write_int64`
  (`fields.mojo:62`) and `write_sint64` (`fields.mojo:68`) respectively.
- `fixed32 = tag + 4`, `fixed64 = tag + 8`, `bool = tag + 1`: match
  `encode_fixed32`/`encode_fixed64`/`write_bool` byte counts.
- `bytes_field_size = tag + varint_size(len) + len`: matches `encode_bytes`
  (`wire.mojo:232-233`, varint length prefix then payload).
