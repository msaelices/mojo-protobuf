## Adversarial Review: mojo-protobuf #20 (SIMD packed varint decode)

### Methodology

Files read (full or relevant ranges):
- `git diff origin/main...simd-packed-varint` (full) + commit log + `gh pr view 20`.
- `src/protobuf/fields.mojo:29-31` (imports), `:222-280` (new `_packed_simd_prefix`,
  `read_packed_signed`, `read_packed_unsigned`), `:130-211` (`read_uint64`,
  `read_int64`, `read_bytes`).
- `src/protobuf/wire.mojo` (full): `decode_varint` 10-byte fast path + slow path,
  `decode_bytes` sub-span return.
- `codegen/protoc_gen_mojo.py` diff (the `_Packed.helper` field + decode emission).
- `benchmarks/bench_message.mojo:268-325`, `test/test_fields.mojo` new tests.
- Generated `telem.mojo` (via the plugin) decode section.

Adversarial inputs run (throwaway Mojo programs under /tmp, deleted), each comparing
the SIMD helper output to a pure-scalar `read_int64`/`read_uint64` loop, on W=32
(`simd_width_of[DType.uint8]()` on this host):
- pure-SIMD multi-chunk 1-byte run (n=101), run not a multiple of W (n=35),
  multi-byte value exactly at the first chunk boundary, `0x7F`/`0x00`, leading
  multi-byte (bail at i=0), negatives (10-byte) + trailing small, empty blob,
  blob shorter than W (skips SIMD loop), exactly-W (i ends at n, no tail),
  all-127 across 4 chunks, int32 truncation of -7, uint32 of 4_000_000_000.
  ALL byte-for-byte identical to scalar.
- A second program embedding the packed blob at a NONZERO offset inside a larger
  parent buffer (junk prefix + tag + length), parsed via the real `read_bytes`
  sub-span path, then `read_packed_signed`. Correct (n=40), proving the sub-span
  `unsafe_ptr()` base used by SIMD agrees with the scalar tail's `blob[pos]` base.

Suite result: `pixi run test` GREEN — wire 28, fields 16, message 39, size 9,
codegen-unit 11, codegen-e2e 6, interop 6 (byte-exact wire interop vs reference
protobuf passes unchanged).

### Issues Found (3 total)

#### Critical (0)
None. No OOB, no value divergence, no pos desync, no dtype bug found.

#### Factual Errors (0)
None.

#### Completeness Gaps (0)
None blocking. (See Minor for an untested-but-correct edge.)

#### Inconsistencies (1)

1. **benchmarks/bench_message.mojo:278** — Comment says "Mixed/large packed values
   (incl. negatives)", but every element is `i*1000 - 32000` for i in 0..63, i.e.
   uniformly large and the FIRST element (-32000) is negative, so the SIMD prefix
   bails on the very first chunk and the whole blob runs scalar. This is a fine
   *worst-case-bail* neutrality test, but it is not "mixed" (no small-value run
   precedes the bail). The methodology/claim ("neutral on large") is sound; only
   the word "mixed" in the comment overstates. Cosmetic.

#### Questions (0)
None — all behaviors confirmed by reading + running.

#### Minor (2)

1. **src/protobuf/fields.mojo:29** — `from std.bit import count_trailing_zeros` is
   a DEAD IMPORT. `pack_bits` (line 247) and `simd_width_of` (line 240) are used;
   `count_trailing_zeros` is never referenced anywhere in the file. Remove it.
   (It appears the helper originally planned to find the first continuation byte
   within the bailing chunk via `count_trailing_zeros(mask)`, then switched to a
   plain `break` — the import was left behind.)

2. **src/protobuf/fields.mojo:248-249** — the bulk-extract is a scalar
   `for k in range(W): out.append(Scalar[dtype](chunk[k]))` with no
   `out.reserve(...)` ahead of the run. Correct, but each `append` may re-check
   capacity; reserving (e.g. `out.reserve(len(out) + (n - i))` once up front, or
   growing per chunk) would tighten the hot path the PR is optimizing. Not a
   correctness issue.

### Verified Correct

- **OOB safety**: loop guard `while i + W <= n` ⇒ max byte read is `i+W-1 <= n-1`,
  in bounds; no off-by-one. When `n < W` the loop body never runs. Confirmed by
  the `shorter-than-W`, `exactly-W`, and `empty` cases and by construction.
- **Sub-span base agreement**: `read_bytes` → `decode_bytes` returns
  `data[start:start+length]`; its `unsafe_ptr()` points at the payload's first
  byte, the same base the scalar tail indexes via `read_int64(blob, pos)`. Proven
  with the nonzero-parent-offset program.
- **pos / boundary safety**: the prefix advances `i` only by whole W-chunks whose
  high bits are ALL clear (`pack_bits(hi) != 0` → `break` BEFORE any append or
  `i += W`). So the returned `pos` is always either 0 or a clean varint boundary
  (it never partially consumes a multi-byte varint), and the scalar tail always
  starts at a value start. No partial-extraction path exists.
- **Value equivalence**: in the `pack_bits(hi) == 0` branch every byte has the high
  bit clear (value 0-127), so `Scalar[dtype](chunk[k])` == `chunk[k] & 0x7F` ==
  the 1-byte varint value. No byte with the high bit set is ever appended. Matched
  scalar on all 12+ input shapes above.
- **Continuation-bit detection**: `(chunk & SIMD[uint8,W](0x80)).cast[DType.bool]()`
  yields per-lane True iff the byte's high bit is set (0x80→nonzero→True, else
  False); `pack_bits` is nonzero iff any lane True. Behavior confirmed (the
  `multibyte-at-boundary`, `leading-multibyte`, `all-127` cases hinge on this and
  all pass — note 0x7F has the high bit CLEAR, correctly treated as single-byte).
- **dtype conversions**: tail `Scalar[DType.int32](read_int64(...))` truncates
  Int64→Int32 in two's complement (=-7 verified), matching the generator's
  singular `Int32(read_int64(...))`. `Scalar[DType.uint32](read_uint64(...))`
  truncates UInt64→UInt32 (4_000_000_000 verified), matching singular
  `UInt32(read_uint64(...))`. No sign surprise: `chunk[k]` is UInt8 0-127 →
  non-negative in every signed dtype.
- **signed/unsigned routing**: generated `telem.mojo` shows int32/int64 →
  `read_packed_signed` (two's-complement `read_int64`), uint32/uint64 →
  `read_packed_unsigned` (`read_uint64`); sint32/sint64/bool/float keep the inline
  scalar loop. Imports added only for the used helpers. Generated code compiles
  and the codegen-e2e + interop tests pass.
- **Truncated-input behavior preserved**: SIMD prefix never reads past `n`; a blob
  ending mid-varint is left to the scalar tail's `read_int64`/`read_uint64`, which
  raise exactly as the old inline loop did.
