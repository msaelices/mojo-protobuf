## Adversarial Review: mojo-protobuf #18 (fast-path varint decode)

### Methodology
Files read / commands run:
- `git diff origin/main...opt-decode-varint` and `git log origin/main..opt-decode-varint` (3 commits).
- Current `src/protobuf/wire.mojo` `decode_varint` (lines 42-89), both paths.
- Original via `git show origin/main:src/protobuf/wire.mojo` (slow-path-only loop, lines 61-73 of original).
- Callers: `src/protobuf/fields.mojo` (`read_uint64/int64/sint64/bool` -> `decode_varint`; `read_bytes` -> `decode_bytes`; `skip_field`), `src/protobuf/wire.mojo:decode_bytes` (lines 252-276), `src/protobuf/message.mojo:439-463` (decode loop `while pos < len(data)`).
- stdlib `Span` source `/home/msaelices/src/my-repos/modular/mojo/stdlib/std/memory/span.mojo`: `__getitem__(slice)` (line 354 -> `ptr=self._data + start`), `unsafe_ptr()` (line 569 -> returns `self._data`).
- Ran existing suite: `pixi run mojo run -I src test/test_wire.mojo` -> 27/27 pass.
- Wrote & ran an adversarial scratch under `/tmp` (now deleted) decoding 10 values via fast path (>=10-byte padded) vs slow path (exact length), plus boundary/raise cases; all fast/slow results agreed.

### Issues Found (1 total)

#### Critical (0)
None.

#### Factual Errors (0)
None. The commit-message behavior claims (early return, lenient non-canonical 10th byte, overlong raise, truncation raise unchanged) were each verified by running both paths on the same logical values.

#### Completeness Gaps (0)
None blocking. (See Minor for an optional test-coverage note.)

#### Inconsistencies (0)
None.

#### Questions (0)
None.

#### Minor (1)
1. **test/test_wire.mojo:122-133** — The new `test_varint_fast_path_early_return` only exercises the fast-path *early return* (1- and 2-byte values). The fast-path *full-10-byte consume*, *non-canonical 10th byte*, and *overlong raise* branches are covered by the pre-existing `test_varint_max_is_10_bytes`, `test_varint_noncanonical_10th_byte`, and `test_varint_overlong_raises` only because those buffers happen to be exactly 10 bytes (n - pos == 10, so the fast path engages). That coupling is implicit and fragile: if anyone shortens those fixtures or adds a leading field, they would silently fall to the slow path and stop testing the fast path. Optional: add an explicit fast-path overlong/10-byte test with >10 bytes of buffer, mirroring the early-return test, so fast-path coverage does not depend on incidental buffer sizing. Not a correctness defect.

### Verified Correct

A. Memory safety
- Guard `n - pos >= 10`, max index read is `ptr[pos + 9]`. When `n - pos == 10`, `pos+9 = n-1` (in bounds). No path reads `ptr[pos + 10]`: the loop is `for i in range(10)` (i in 0..9) and either returns inside or falls through to `raise` after the loop — it never indexes with `i == 10`. Verified with the n==11 overlong case (`10x0xFF + 0x00`): fast path raised "exceeds 64 bits" without observing the 11th byte.
- `pos` range: all callers advance `pos` only past consumed/validated bytes and bounds-check LEN/I32/I64 skips, so `pos in [0, n]` on entry. `pos == n` -> `n - pos == 0 < 10` -> slow path -> "truncated". `Int` (signed) arithmetic confirmed (`pos: Int`, `n = len(data): Int`); a hypothetical `pos > n` yields a negative `n - pos`, `>= 10` false -> slow path. No unsigned wraparound.
- Sub-span offset: `decode_bytes` returns `data[start : start + length]`; stdlib `Span.__getitem__(slice)` sets `ptr = self._data + start` and `unsafe_ptr()` returns that `_data`. So a sub-span's `unsafe_ptr()[pos + i]` addresses the sub-span's element `pos+i`, identical to the slow path's `data[pos+i]`. Nested-message decode (which passes sub-spans) is correctly offset.

B. Behavioral equivalence with origin/main (proven by running both paths on identical values)
- 1-byte (high bit clear): returns immediately, `pos += 1`. Matches (`v=0,1,127` -> pos 1).
- multi-byte accumulation: `result |= UInt64(b & 0x7F) << shift`, `shift += 7`, shift sequence 0,7,...,63 — byte-for-byte the same expression and order as the original loop. Matches for `128, 300, 16383, 16384, 0xFFFFFFFF, 0x7FFF...FF` (9 bytes), `0xFFFF...FF` (10 bytes).
- exactly-10-byte terminating varint (`0xFFFFFFFFFFFFFFFF`): fast path reads i=0..9, 10th byte terminates, `pos += 10`. Slow path (exact-len-10 buffer) gives identical value and pos.
- non-canonical 10th byte (`9x0x80, 0x7F`): fast path applies `<< 63` (shift=63) and returns `0x8000000000000000`, does NOT raise — matches `test_varint_noncanonical_10th_byte`.
- overlong (`10x0xFF`): fast path completes `range(10)` with no terminating byte, falls through to `raise "exceeds 64 bits"`. Original `while shift < 64` runs exactly 10 iterations (shift 0..63), reads 10 bytes, then raises the same error. Neither reads an 11th byte. Matches.
- truncated (`0x80`, n=1; `9x0xFF`, n=9): slow path raises "truncated input" — matches original.

C. pos correctness: early return `pos += i + 1` gives pos 1 for i=0 and pos 10 for i=9; verified (`early-return` case -> pos 1; 10-byte -> pos 10). On overlong the function raises and leaves `pos` unmodified; original likewise raises (it advances `pos` internally per byte but the raise aborts the caller, so the difference is unobservable — caller discards state on error).

D. Measurement/methodology sanity: `decode_many_ints` decodes an 8-field int64 message (`ManyInts`), no LEN/string/bytes fields, so message decode is allocation-free and varint-bound — a legitimate target for the fast path; early fields have >=10 bytes remaining and hit it. Wire micro-benches batch via `BATCH`/`b.iter`. "Neutral on small" is plausible: small/alloc-bound fixtures' tail fields hit the slow path and allocation dominates. Exact percentages not reproduced (not required).

E. Adversarial inputs: 10 values run fast-vs-slow with identical (value, pos) results; 5 boundary/raise cases (overlong n=10, overlong+trailing n=11, truncated n=1, truncated n=9, non-canonical n=10) all matched expected behavior.

F. Style: `var shift` is declared in the fast-path block (line 69) and again in the slow path (line 79); compiles cleanly (suite builds/runs) because the fast-path block always returns or raises, so the second declaration is only reached when the fast path was not entered — no shadowing bug. `n = len(data)` computed once (line 63) and reused in both paths (lines 67, 81). Docstring (lines 43-61, including the lenient-10th-byte note and Raises) is retained unchanged by the diff.
