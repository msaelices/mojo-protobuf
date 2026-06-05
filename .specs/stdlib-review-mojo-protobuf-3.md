# Adversarial review — PR #3 "Add typed field layer (write/read/skip)"

Repo: msaelices/mojo-protobuf · Branch `message-api` → `main`
Primary file under review: `src/protobuf/fields.mojo` (+ `test/test_fields.mojo`, docs).

## Methodology

Every claim and edge case was checked against authoritative sources and, where
feasible, *executed* on the local Mojo nightly toolchain (`mojo run -I src`)
rather than reasoned about in the abstract.

Sources used:

- **Protobuf encoding spec** (<https://protobuf.dev/programming-guides/encoding/>):
  the (tag, value) model; varint/LEB128; int32/int64 encoded as the plain
  two's-complement bits (negatives sign-extended to 64 bits ⇒ 10-byte varint);
  ZigZag for `sint*`; bool as 0/1 but decoders accept any non-zero varint;
  length-delimited string/bytes; unknown fields skipped *by wire type*; valid
  wire types 0/1/2/5 vs. deprecated groups 3/4 and illegal 6/7.
- **Mojo stdlib source** (`/home/msaelices/src/my-repos/modular/mojo/stdlib/std/`):
  - `collections/string/string.mojo:429` — `String(out, *, from_utf8: Span[Byte,_]) raises`
    is the *validating* constructor (`_is_valid_utf8` → raise), delegating to
    `unsafe_from_utf8` on success. `as_bytes` (line 1386) returns
    `Span[Byte, origin_of(self)]`.
- The already-merged `src/protobuf/wire.mojo` primitives (re-read in full to
  confirm each field helper delegates correctly).
- `mojo-stdlib-contributing` SKILL (docstring conciseness, edge-case coverage,
  assert/raise semantics).

Empirical checks executed (all passed):

- `write_int64`/`read_int64` round-trip for `0, ±1, Int64.MAX, Int64.MIN`.
  Confirmed `-1` → **11 bytes** (1 tag + 10-byte varint), `Int64.MIN` → 11
  bytes, `Int64.MAX` → 10 bytes (1 tag + 9). Matches the spec's sign-extension
  rule exactly.
- `write_sint64`/`read_sint64` round-trip for `0, ±1, Int64.MIN, Int64.MAX`.
- `write_bytes`/`read_bytes` round-trip incl. a `0xFF`/`0x00` payload.
- Empty `write_string`/`read_string` round-trip.
- `read_bool` on a multi-byte varint (150) → `True` (spec-correct).
- Large field number `2^29-1` tag round-trip.
- `uint64 == UInt64.MAX` read back through `read_int64` → `-1` (bit-identical
  reinterpretation, as designed).
- `skip_field`: truncated I64, truncated I32, truncated LEN (length=10, 3 bytes
  present), oversized LEN (varint = 2^64-1), and wire types 3/4/6/7 — **every
  one raises** with the expected message; no OOB, no abort.
- `read_string` on invalid UTF-8 (`0xFF 0xFE`) → raises
  "Cannot construct a String from invalid UTF-8 data".
- The PR's own `test/test_fields.mojo` runs: 4/4 pass.

## Issues Found (7 total)

### Critical (0)

None. The encoding, the two's-complement int64 reinterpretation, and — most
importantly — `skip_field`'s malformed/truncated/oversized-length handling are
all correct and were verified by execution. The `WIRE_LEN` branch computes
`remaining = len(data) - pos` *after* `decode_varint` has advanced `pos`;
because `decode_varint` raises before reading when `pos >= len(data)`, on its
success `pos <= len(data)`, so `remaining >= 0` and the `length > UInt64(remaining)`
guard is evaluated before the `Int(length)` advance — the same overflow-safe
ordering as `decode_bytes`. No OOB or overflow is reachable.

### Factual error (0)

None. Spot-checked claims that are all correct:

- Module/docs claim int64/int32 are "two's-complement varint" — correct, and the
  negative-value 10-byte-varint behavior was verified.
- `read_bool` docstring "any non-zero varint is `True`" — matches the spec's
  decoder leniency (verified with 150).
- The `write_*` type-mapping table (`write_uint64` ↔ uint32/uint64/enum,
  `write_fixed32` ↔ fixed32/sfixed32/float bit-cast, `write_bytes` ↔
  bytes/embedded messages, etc.) is accurate.
- messages.md "groups 3/4, and 6/7 are rejected" — correct; valid wire types are
  0/1/2/5, and `skip_field`'s `else` catches all of 3/4/6/7 (verified).
- `String(from_utf8=...)` *is* the raising/validating constructor (vs.
  `unsafe_from_utf8`) — confirmed against `string.mojo:429`.

### Completeness gap (4)

- **[test/test_fields.mojo — whole file]** `write_bytes`/`read_bytes` are
  **never imported or tested.** `read_bytes` is the only reader returning a
  zero-copy `Span[Byte, data.origin]` view (a distinct, origin-bearing return
  path), and `write_bytes` is the only writer taking a raw `Span[Byte,_]`. String
  round-trips do *not* exercise them (string read goes through the validating
  `from_utf8` path, not the raw span return). Add a `bytes` round-trip,
  including a payload with high/zero bytes (`0x00`, `0xFF`) to prove binary
  transparency. *(I verified such a round-trip works; the point is the PR ships
  no test for it.)*

- **[test/test_fields.mojo — `read_string`]** The **invalid-UTF-8 raising path
  is untested.** `read_string`'s docstring advertises a `Raises:` contract, and
  the messages.md doc highlights "`read_string` validates UTF-8 and raises", yet
  no test feeds invalid bytes (e.g. `len=2, 0xFF 0xFE`) through `read_string`
  inside `assert_raises()`. This is the headline behavioral difference from
  `read_bytes` and should be covered. *(Verified it does raise.)*

- **[test/test_fields.mojo — `skip_field`]** Only the **invalid-wire-type** path
  (`skip_field(..., 3)` on empty data) and the **happy** skip path are tested.
  The **truncation/overflow guards are untested**: truncated I64, truncated I32,
  truncated LEN, and oversized-LEN. These four guards are the entire safety
  rationale for `skip_field` against malformed/adversarial input; per the
  contributing skill ("cover edge cases: out-of-bounds, exact-width, empty"),
  each guard deserves an `assert_raises()` test. *(All four verified to raise.)*

- **[test/test_fields.mojo — value coverage]** No boundary values for the varint
  writers: `Int64.MIN`/`Int64.MAX` through `write_int64` (the case that produces
  the 11- vs 10-byte varint asymmetry), `UInt64.MAX` through `write_uint64`, and
  ZigZag extremes through `write_sint64` are untested. The only int64 value
  exercised is `-5`. Add MIN/MAX round-trips to lock the two's-complement and
  ZigZag behavior. *(All verified correct, but unprotected by tests.)*

### Inconsistency (1)

- **[src/protobuf/fields.mojo (module docstring & all `write_*`) vs.
  docs/concepts/messages.md]** The write/read **asymmetry is a genuine footgun**
  and it is documented *somewhat*, but inconsistently. `write_*` emits *tag +
  value*; `read_*` reads *value only* (the caller must have separately consumed
  the tag via `decode_tag`). The module docstring's decode-loop example does the
  right thing, and messages.md explains the split. However, the per-function
  `read_*` docstrings (e.g. `read_int64`: "Reads a varint `int64`/`int32`
  value") do **not** state "the tag must already have been consumed", so a user
  reading hover-docs for a single `read_*` in isolation can easily double-read or
  mis-pair tag and value (the symptom would be silent misalignment, not a raise).
  Recommend one short clause in each `read_*` docstring, or a shared note, making
  the precondition local to the function. (Classified Inconsistency, not
  Critical: the API behaves as documented at the module level; the risk is
  purely doc-locality.)

### Question (1)

- **[src/protobuf/fields.mojo — missing 32-bit & float/double helpers]** There
  are no `int32`/`uint32`/`sint32` (32-bit varint) helpers and no
  `float`/`double` convenience wrappers — callers route 32-bit varints through
  the 64-bit helpers and must bit-cast floats to `UInt32`/`UInt64` themselves.
  For protobuf, funnelling `int32`/`uint32` through 64-bit varints is *wire-
  compatible* (a `uint32` and a `uint64` of the same value encode identically;
  a negative `int32` field is even *spec-required* to be sign-extended to a
  10-byte varint, which the 64-bit path does correctly), so this is a
  *reasonable v1 deferral*, not a bug. **Question for the author:** is the plan
  to add typed 32-bit and float/double wrappers in the typed-message layer, and
  should the module docstring say so explicitly so users don't assume the
  omission is an oversight? (The docs table already hints at the bit-cast
  convention, which is good.) Not flagging as a gap given the stated v1 scope.

### Minor (1)

- **[src/protobuf/fields.mojo — `read_string` docstring]** Minor wording: the
  `Raises:` clause says "If the bytes are not valid UTF-8, or the length is
  malformed." Good. For parity, the other `read_*`/`skip_field` docstrings that
  can raise on truncation (`read_int64`, `read_fixed*`, etc.) omit a `Raises:`
  section even though they propagate `decode_varint`/`decode_fixed*` errors.
  Per the stdlib docstring style (`Raises:` "when applicable"), a one-line
  `Raises:` ("If the input is truncated.") on the readers would be more
  consistent. Low priority — these are thin delegators and the underlying
  primitives document their raises.

## Verified Correct

The following were specifically attacked and held up (most by execution):

1. **int64 two's-complement varint.** `write_int64`/`read_int64` use
   `encode_varint(UInt64(value))` / `Int64(decode_varint(...))` — bit-reinterpret,
   not numeric-convert. `-1` → `0xFFFF…FF` → 10-byte varint; `Int64.MIN`/`MAX`
   and `0` all round-trip. Cross-type `UInt64.MAX` reads back as `-1`. Matches
   spec.
2. **ZigZag `sint64`.** Composes `zigzag_encode`+`encode_varint` on write and
   `decode_varint`+`zigzag_decode` on read; round-trips `0, ±1, MIN, MAX`.
3. **`uint64` plain varint, `bool` 0/1 with non-zero-is-true decode.** Verified.
4. **`fixed32`/`fixed64`.** Correct wire types tagged (`WIRE_I32=5`,
   `WIRE_I64=1`) and delegate to `encode_fixed*`/`decode_fixed*`; values
   `0xCAFEBABE` / `0x1122334455667788` round-trip.
5. **`write_string` / `read_string`.** Write uses `value.as_bytes()` (UTF-8,
   correct origin per `string.mojo:1386`), length-delimited; read uses the
   *validating* `String(from_utf8=...)`. Non-ASCII "héllo" is lossless;
   invalid UTF-8 raises. Trusting an already-constructed Mojo `String` on write
   (no re-validation) is correct — a Mojo `String` is invariantly valid UTF-8.
6. **`write_bytes` / `read_bytes`.** `WIRE_LEN`; read returns a zero-copy
   `Span[Byte, data.origin]`. Binary-transparent (verified with `0xFF`/`0x00`).
   The `Span[Byte, data.origin]` return annotation compiles and is correct.
7. **`skip_field` — all branches.** VARINT discards a varint; I64 advances 8
   behind a `pos+8 > len` guard; LEN reads a length varint then guards
   `length > UInt64(remaining)` (remaining provably ≥ 0) *before* `pos += Int(length)`;
   I32 advances 4 behind a `pos+4 > len` guard; `else` raises for 3/4/6/7. No
   OOB or overflow reachable on malformed input — verified across truncated and
   oversized cases.
8. **Mojo syntax.** `UInt64(1) if value else UInt64(0)` ternary,
   `Int64(...)`/`UInt64(...)` reinterpretation, `elif`/`else` flow,
   `String(from_utf8=...) raises`, and the `var a, b = decode_tag(...)` tuple
   unpacking in tests/docs all compile and run.
