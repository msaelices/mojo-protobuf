## Adversarial Review: mojo-protobuf #2

PR: "Add fixed-width and length-delimited value codecs" (branch `value-codecs`, base `main`).
Scope: new functions in `src/protobuf/wire.mojo` — `encode_fixed32`/`decode_fixed32`,
`encode_fixed64`/`decode_fixed64`, `encode_bytes`/`decode_bytes` — plus tests, the
`__init__.mojo` docstring, and `docs/concepts/wire-format.md`.

### Methodology

For every claim and edge case I:
1. Read the protobuf encoding spec semantics (fixed32 = 4 bytes LE, fixed64 = 8 bytes LE,
   `WIRE_LEN` = varint length then payload; wire-type constants `WIRE_I32=5`, `WIRE_I64=1`,
   `WIRE_LEN=2`, all matching `wire.mojo` lines 14-19).
2. Read the actual Mojo stdlib source of truth (not pretrained knowledge):
   - `memory/span.mojo`: `__getitem__(slc: ContiguousSlice) -> Self` (line 339), construction
     from `List` (line 268), `__iter__` requiring `Copyable` (lines 356-382), `origin` plumbing.
   - `builtin/builtin_slice.mojo`: `ContiguousSlice.indices()` (lines 159-184) — confirms slice
     bounds are **clamped** to `[0, length]`.
   - `builtin/reversed.mojo` line 232: `(value: Span[T, _]) -> _SpanIter[T, value.origin, ...]`,
     confirming the `data.origin`-in-return-type pattern is an established, sound stdlib idiom.
3. Reasoned through every boundary/overflow case by hand with concrete values (0, 1, 0x12345678,
   UInt32.MAX, UInt64.MAX, `pos == len`, huge length prefix).
4. **Actually compiled and ran** the PR test suite (`mojo run -I src test/test_wire.mojo`):
   19/19 pass. Then wrote and ran four additional adversarial tests (sequential decode,
   200-byte multi-byte length prefix, fixed64 truncation, `pos == len` guard) — all pass.

### Issues Found (7 total)

#### Critical (0)

None. The highest-risk areas (decode_bytes length/overflow safety and Span-origin soundness)
are correct — see Verified Correct.

#### Factual Errors (0)

None. All encoding claims (byte order, framing, wire-type numbers) match the spec, and all
Mojo-syntax/lifetime claims in docstrings and PR body match stdlib semantics.

#### Completeness Gaps (5)

- **[test/test_wire.mojo, fixed64 codec]** — No `decode_fixed64` truncated-input test, even
  though the fixed32 equivalent (`test_fixed32_truncated_raises`, line 156) exists. The
  `pos + 8 > len(data)` guard (wire.mojo:209) is therefore unexercised. I verified by hand and
  by running an added test that a 3-byte buffer raises correctly, so this is a coverage gap,
  not a bug. Recommend adding the symmetric test.

- **[test/test_wire.mojo, decode_bytes sequential invariant]** — No test reads a SECOND field
  after a `decode_bytes` payload to confirm `pos` is left at exactly `start + length` so the
  trailing data is still decodable. This is the core "sequential decode" invariant for a wire
  parser. I added and ran a back-to-back two-field test — it passes — but the PR ships without
  guarding this regression.

- **[test/test_wire.mojo, multi-byte length prefix]** — Every `encode_bytes`/`decode_bytes`
  test uses a payload < 128 bytes, so the length varint is always a single byte. A payload
  >= 128 bytes (2-byte length varint) is never exercised, leaving the interaction between
  `encode_varint(UInt64(len(data)))` and the multi-byte decode path untested. I added a
  200-byte test (length encodes as `0xC8 0x01`); it passes. Recommend adding it.

- **[test/test_wire.mojo, fixed `pos == len` boundary]** — No test calls `decode_fixed32`/
  `decode_fixed64` with `pos` already equal to `len(data)` (the exact off-by-one boundary of
  the `pos + 4 > len` / `pos + 8 > len` guards). The guard is correct (`pos == len` ⇒
  `pos + 4 > len` ⇒ raises), and I verified by running it, but the boundary is untested.

- **[wire.mojo:149, 188 / tests]** — The docstrings advertise these codecs as backing
  `float`/`double` "via bit-cast", but no test exercises a `bitcast[DType.float32]`/`float64`
  round-trip through `encode_fixed32`/`encode_fixed64`. Acceptable to defer (the codecs operate
  on `UInt32`/`UInt64` and the bit-cast lives at a higher layer), but worth an explicit note
  that float coverage is deferred so it is not silently forgotten.

#### Inconsistencies (0)

None. `docs/concepts/wire-format.md` (the "Where this lives" table lines 89-95 and the status
table lines 99-105), the `__init__.mojo` docstring, and the actual function names/wire-type
numbers are mutually consistent and match the spec.

#### Questions (1)

- **[wire.mojo:233]** — `encode_bytes` copies the payload with an explicit
  `for b in data: out.append(b)` loop. Is there a reason not to use a bulk `out.extend(data)` /
  `extend`-style append for the hot path? This is a behavioral no-op (verified correct), so it
  is only a possible efficiency/idiom question, not a defect. Flagging in case a bulk copy is
  preferred for larger payloads.

#### Minor (1)

- **[wire.mojo:152-155]** — `encode_fixed32` open-codes four `out.append(Byte((value >> k) & 0xFF))`
  lines while `encode_fixed64` (lines 190-193) uses a `for _ in range(8)` loop with `v >>= 8`.
  Both are correct and produce identical little-endian output (verified by `test_fixed32_little_endian`
  and by running round-trips), but the two functions use stylistically different idioms for the
  same operation. Minor DRY/consistency nit; the masks `& 0xFF` in the fixed32 path are also
  redundant since `Byte(...)` already truncates to 8 bits (harmless, matches the `encode_varint`
  style above it).

### Verified Correct

- **decode_bytes overflow/over-read safety (highest-risk item) — CORRECT.**
  `remaining = len(data) - pos` is guaranteed non-negative: `decode_varint` only advances `pos`
  inside the `pos < len(data)` guard (wire.mojo:62), so `pos <= len(data)` on success. The check
  `length64 > UInt64(remaining)` runs in `UInt64` space **before** `Int(length64)`, so an
  oversized prefix (up to `UInt64.MAX`) raises instead of wrapping. When the guard passes,
  `length64 <= remaining <= len(data) <= Int.MAX`, so `Int(length64)` cannot become negative, and
  `pos += length` satisfies `pos + length <= len(data)` (no overflow). Confirmed the guard
  precedes every unsafe conversion/arithmetic. `test_bytes_length_exceeds_buffer_raises` exercises
  the basic path and passes.

- **Span origin soundness — CORRECT.** Return type `Span[Byte, data.origin]` (wire.mojo:239)
  ties the view's lifetime to the input, matching the stdlib pattern in `builtin/reversed.mojo:232`
  (`-> _SpanIter[T, value.origin, ...]`). The slice `data[start : start + length]` calls
  `Span.__getitem__(ContiguousSlice)` (span.mojo:339), which returns `Self` (same `T` and same
  `origin`) pointing into the original buffer — a true zero-copy, non-dangling sub-span. Compiles
  and runs; views read correct bytes.

- **Slice bounds — CORRECT and defensively clamped.** `ContiguousSlice.indices()`
  (builtin_slice.mojo:159-184) clamps `end >= length` to `length`, so even if `start + length`
  ever exceeded `len(data)` the slice would not over-read; the explicit guard already prevents
  that case anyway.

- **fixed32/fixed64 assembly — CORRECT for all boundary values.** Little-endian byte 0 = LSB.
  `test_fixed32_little_endian` confirms `buf[0]==0x78`, `buf[3]==0x12` for `0x12345678`.
  Round-trips for `0, 1, 0x12345678, UInt32.MAX` and `0, 1, 0x123456789ABCDEF0, UInt64.MAX` all
  pass. In `decode_fixed64`, the shift `UInt64(i) * 8` reaches 56 at `i == 7` (< 64, well-defined);
  in `encode_fixed64` the loop shifts `v >>= 8` exactly 8 times. `pos` advances by exactly 4 / 8.

- **Truncation guards — CORRECT.** `pos + 4 > len(data)` / `pos + 8 > len(data)` are the correct
  (non-off-by-one) conditions; `pos == len` raises, `pos == len - 4` (exactly 4 left) succeeds.
  Verified by running both a passing round-trip at the boundary and a raising `pos == len` case.

- **Span iteration in encode_bytes — CORRECT.** `for b in data` over `Span[Byte, _]` is valid
  because `Byte` (= `UInt8`) is `Copyable`, satisfying the `__iter__` constraint
  (span.mojo:363-365). `Span(buf)`/`Span(payload)` construction from a `List[Byte]` uses the
  `List` constructor (span.mojo:268).

- **Docs & wire-type numbers — CORRECT.** `WIRE_I32=5`, `WIRE_I64=1`, `WIRE_LEN=2` match the
  spec; the docs status/where-it-lives tables and the `__init__.mojo` summary accurately reflect
  the new functions.

- **Full suite compiles and passes:** 19/19 PR tests + 4 added adversarial tests, 0 failures.
