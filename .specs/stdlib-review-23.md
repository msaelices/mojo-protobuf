## Adversarial Review: mojo-protobuf #23 (read_string ASCII fast path)

### Methodology

Files read:
- Diff + commit log of `opt-string-decode` vs `origin/main` (`git diff origin/main...opt-string-decode`, `gh pr view 23`).
- Full `src/protobuf/fields.mojo` — new `_all_ascii` (lines 212-229) and rewritten `read_string` (lines 232-245).
- `src/protobuf/wire.mojo` — `decode_bytes` (252-276, returns `data[start:start+length]`, a borrowed sub-slice) and `encode_bytes` (239-249).
- Stdlib `String` constructors in `…/oss/modular/mojo/stdlib/std/collections/string/string.mojo` (the build's pinned stdlib, mojo 1.0.0b2.dev2026060406):
  - `String(unsafe_from_utf8=)` (369-393): validation is only a `debug_assert(_is_valid_utf8(...))` (383-386) → **skipped in a normal/release build**, runs only under `-D ASSERT=all`. Then `memcpy`. Confirms it does NOT validate in release.
  - `String(from_utf8=)` (428-440): `if not _is_valid_utf8(...): raise Error(...)` → raises on invalid. Confirmed.
  - `SIMD.reduce_or[size_out=1]` returns `SIMD[uint8, 1]`; `(… & 0x80) != 0` → `SIMD[bool,1]`/Bool. Confirmed.

Adversarial inputs run (scratch under /tmp, `pixi run mojo run -I src`, deleted after). SIMD width on this machine **W = 32**:
- pure ASCII short ("hi") and long (54-char) → fast path, correct value.
- valid multi-byte UTF-8 short ("héllo") and long ("…dög…") → `from_utf8` path, correct round-trip.
- empty string → no raise, equals "". Same as old.
- INVALID UTF-8 that must raise: lone `[0x80]`, truncated `[0xC3]`, `[0xFF]`, `b"abc\x80"` → **all raise**. Matches old behavior.
- long all-ASCII (len 101 = 3·W + 5) with a single `0x80` at pos 0, 16 (mid-chunk), 32 (chunk boundary), 65, 99, 100 (last byte, scalar tail) → **all raise**.
- **Exhaustive**: for every length n in 0..4W+2, placed `0x80` at *every* position and confirmed each raises → **0 misses**. Plus an all-ASCII length sweep 0..4W+2 → **0 false raises**.
- Full `test/test_fields.mojo` on the PR branch: **17/17 PASS** (incl. new `test_read_string_ascii_fast_path` and pre-existing `test_read_string_invalid_utf8_raises`).

### Issues Found (2 total)

#### Critical (0)

None. The validation-skip is sound: `unsafe_from_utf8` is only reached when `_all_ascii` is True, and `_all_ascii` provably returns True iff every byte < 0x80 (high bit accumulated by `acc |= chunk` then checked via `reduce_or() & 0x80`, with a correct scalar tail). Every non-ASCII / invalid-UTF-8 input still takes `from_utf8` and raises. No OOB.

#### Factual Errors (0)

None. The commit/PR claims that ASCII is valid UTF-8, that `unsafe_from_utf8` skips validation, and that non-ASCII still raises are all accurate against the source.

#### Completeness Gaps (1)

1. **test/test_fields.mojo:289-295 (new non-ASCII test)** — The new "non-ASCII byte in a long string" case uses *valid* UTF-8 ("dög"), so it only checks the `from_utf8` happy path. The high-bit byte here sits in the **SIMD region** (string > W only on machines with small W; with W=32 this 54-byte string spans one full chunk + tail, so the ö may land in either region depending on offset), but no test asserts that a **long, *invalid*** UTF-8 string (high bit in the SIMD-loop region) still *raises*. The only invalid-UTF-8 raise test (`test_read_string_invalid_utf8_raises`, line 123-127) is 2 bytes → exercises only the scalar tail, never the SIMD `acc` path. So no committed test would catch a hypothetical regression where the SIMD accumulator dropped a high bit. The code is correct (my exhaustive run proves it), but the suite under-covers the SIMD-region-invalid case. Suggest adding a long string with a `0x80` past byte W that asserts `assert_raises`. Severity: low (correctness already proven, gap is in regression protection only).

#### Inconsistencies (0)

None.

#### Questions (0)

None outstanding — all behavioral questions were resolved by running inputs.

#### Minor (2)

1. **src/protobuf/fields.mojo:212 `@always_inline` on `_all_ascii`** — Acceptable. It is a small leaf called from the single hot `read_string` site; inlining lets the SIMD width fold and the loop bound specialize. The internal `while` loop does not preclude inlining in Mojo. No action needed, just noting it is a deliberate-looking choice that is fine here.
2. **src/protobuf/fields.mojo:226 `ptr[i] >= 0x80`** — `ptr[i]` is `Byte` (UInt8), `0x80` is an unsigned `255`-range literal compared as UInt8; no signedness pitfall (UInt8 is unsigned), comparison is correct. Style nit only: the SIMD branch uses `& 0x80` (bit test) while the tail uses `>= 0x80` (range) — both are equivalent for the "high bit set" predicate on a single byte, but the inconsistency is mildly distracting. Optional: use `(ptr[i] & 0x80) != 0` for symmetry. No correctness impact.

### Verified Correct

- **`_all_ascii` completeness (no high bit lost):** `acc |= ptr.load[width=W](i)` ORs every byte of every full chunk into `acc`; a single 0x80 anywhere in the chunked region survives the OR, and `(acc.reduce_or() & 0x80) != 0` returns False. Proven by exhaustive 0x80-at-every-position test over lengths 0..4W+2 (0 misses), including chunk-boundary and mid-chunk positions.
- **OOB safety:** SIMD loop guard `while i + W <= n` ⇒ max byte read index `i+W-1 ≤ n-1`, in bounds (no `<` vs `<=` off-by-one). `ptr = s.unsafe_ptr()` on the `decode_bytes` sub-slice points at the slice's first payload byte, so `ptr[i]`/`load(i)` read the intended bytes. Strings shorter than W skip the SIMD loop and hit only the tail. Scalar tail `while i < n` covers exactly the residual `< W` bytes (i advanced by W per chunk), never reads `ptr[n]`, never skips the last byte (verified by the 0x80-at-last-position case and the exhaustive sweep).
- **Old-vs-new equivalence for every required input:** lone `[0x80]`, truncated `[0xC3]`, `[0xFF]`, `b"abc\x80"`, and long-ASCII-with-one-0x80 (start / mid-chunk / boundary / tail) **all still raise** exactly as the pre-PR `from_utf8`-only code did. Valid ASCII (short & long) and valid multi-byte UTF-8 (short & long) round-trip to the correct value.
- **Empty string:** `len==0` ⇒ `_all_ascii` returns True (loops skipped) ⇒ `unsafe_from_utf8` of an empty span ⇒ empty String, no raise. Identical to old `from_utf8` of empty. Verified.
- **Perf-claim plausibility (D):** The fast path *is* taken for typical ASCII fields (e.g. the `person` record's name/email), and `unsafe_from_utf8` does a bare `memcpy` while `from_utf8` additionally runs `_is_valid_utf8`; skipping the validator for ASCII is a genuine (not inverted) win. Exact ns numbers not reproduced, but the claim direction is sound.
- **Stdlib contract:** `unsafe_from_utf8`'s only check is a release-stripped `debug_assert`, so the ASCII precondition established by `_all_ascii` is what guarantees safety — correctly relied upon.
- **Docstring accuracy (read_string:233-240):** Matches the code — ASCII skips full validation after a SIMD high-bit scan; non-ASCII goes through full validation and still raises.
