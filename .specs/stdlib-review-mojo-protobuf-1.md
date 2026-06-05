## Adversarial Review: mojo-protobuf #1

### Methodology
Verified ~30 claims against three authoritative sources, refuting most by direct
empirical execution rather than reasoning alone:

- **Protobuf encoding spec** (<https://protobuf.dev/programming-guides/encoding/>):
  varint/LEB128 rules, 150 example, ZigZag formulas + table, wire-type table
  (0/1/2/5, plus deprecated 3/4 groups), tag packing.
- **Mojo stdlib source** (local `/home/msaelices/src/my-repos/modular/mojo/stdlib/std/`):
  - `builtin/simd.mojo` — `__lshift__`/`__rshift__` (`pop.shl`/`pop.shr`), int
    constructors/`cast`, to confirm arithmetic shift + bit-reinterpreting casts.
  - `builtin/int.mojo` — `Int.__lshift__`/`__rshift__` (`index.shl`/`index.shrs`),
    `Int.MIN`/`MAX`.
  - `testing/suite.mojo` + `testing/__init__.mojo` — `TestSuite.discover_tests[__functions_in_module()]().run()`
    is the documented current runner; `mojo test` CLI confirmed removed
    (`mojo test` → `error: no such command 'test'`).
- **mojo-stdlib-contributing** SKILL (technical rules: docstring conciseness,
  edge-case coverage, assert semantics).

Crucially, I **ran the code**: the full test suite (7/7 pass), plus a custom
harness exercising ZigZag at `Int64.MIN`/`MAX`, varint at `UInt64.MAX`,
arithmetic-shift sign extension, `Int64.MIN << 1` overflow, the overlong 11-byte
varint path, the non-canonical 10th-byte path, and trailing-byte behavior.

### Issues Found (9 total)

#### Critical (0)
None. The encoding/decoding math is correct. All four risky operations were
empirically confirmed:
- `zigzag_encode`/`zigzag_decode` are exact inverses for `0, -1, 1, -2,
  Int64.MAX, Int64.MIN` (ran it; all OK).
- `Int64(-1) >> 63 == -1` — `pop.shr` is arithmetic (sign-extending) for signed
  dtypes, so the `(value >> 63)` mask is correct.
- `Int64.MIN << 1 == 0` — wraps, does **not** trap.
- `UInt64(Int64(...))` reinterprets two's-complement bits (via `cast`), not
  value-clamps, so `zigzag_encode(Int64.MIN) == UInt64.MAX` as required.

#### Factual Errors (0)
Every factual claim in `docs/concepts/wire-format.md` matched the spec:
the `(tag,value)` model, "field names never on the wire", the worked `150`
breakdown, the ZigZag table (`0→0, -1→1, 1→2, -2→3`), the wire-type table
(0/1/2/5 with correct example field types), "wire types 3/4 were deprecated
groups", fixed64=8-byte LE / fixed32=4-byte LE, and WIRE_LEN = varint length
then bytes. The "where this lives in the code" table matches the actual function
names in `wire.mojo`. The tag formula `(field_number << 3) | wire_type` is
correct.

#### Completeness Gaps (5)

- **[test/test_wire.mojo — missing 10-byte `UInt64.MAX` decode]** —
  `test_varint_roundtrip` round-trips `UInt64.MAX`, which exercises the
  `shift==63` final iteration, but no test asserts the *encoded length is
  exactly 10 bytes* or decodes a hand-built 10-byte varint. The 10-byte boundary
  is the single most error-prone path in the loop; assert `len(buf)==10` for
  `UInt64.MAX` (I confirmed it is 10).

- **[test/test_wire.mojo — overlong (>64-bit) error path untested]** — the PR
  description advertises a ">64-bit guard" and `decode_varint` has a dedicated
  `raise Error("decode_varint: varint exceeds 64 bits")`, but **no test reaches
  that branch**. `test_varint_truncated` only hits the truncation raise. Add an
  11-byte all-continuation buffer; I verified it raises "varint exceeds 64
  bits".

- **[src/protobuf/wire.mojo:50 — non-canonical 10th byte silently accepted]** —
  a 10-byte varint whose final byte is `0x7F` (payload bits 1–6 set, which
  cannot fit in the remaining 1 bit of a 64-bit value) is accepted: `(0x7F <<
  63)` silently truncates to `0x8000…000`, returning `9223372036854775808` with
  no error (verified empirically). The spec gives the 10th byte only 1 valid
  payload bit. This is *lenient* (matches upstream protobuf-C++ behavior, so not
  a correctness bug for interop), but it is an **undocumented** edge: the doc
  says the decoder rejects "more than 64 bits worth of groups arrive," which a
  reader could read as rejecting these high bits. Either tighten the check
  (`shift==63 && (b & 0x7E) != 0` → raise) or document the leniency. At minimum
  add a test pinning the chosen behavior.

- **[test/test_wire.mojo — no trailing-byte / mid-buffer test]** — nothing
  asserts that after decoding a value `pos` stops mid-buffer (so the next field
  can be read). I verified `decode_varint([0x01,0xFF])` returns `1`, `pos==1`.
  This is the core invariant for sequential field decoding and is untested.

- **[test/test_wire.mojo — `decode_tag` error path untested]** — `test_tag`
  covers the happy path only. There is no test that `decode_tag` on a truncated
  buffer propagates the underlying `decode_varint` raise (the docstring's
  "Raises" clause). Cheap to add with `assert_raises()`.

#### Inconsistencies (1)

- **[src/protobuf/__init__.mojo:9]** — the module docstring still reads "Nothing
  is implemented yet beyond this scaffold." This PR is changed by this file
  (line 12, `alias`→`comptime`) yet the now-false sentence is left in place,
  while `wire.mojo` ships a working runtime. Update to reflect the wire layer.
  (Root `README.md:6-7` "No functionality is implemented yet" is the same
  staleness, but `README.md` is not in this PR's changeset.)

#### Questions (1)

- **[src/protobuf/wire.mojo:97,107 — no validation of `field_number`/`wire_type`
  in `encode_tag`, no range/skip handling in `decode_tag`]** — `encode_tag`
  accepts any `Int` for `wire_type` (e.g. `7`, or the deprecated `3`/`4`) and
  any `field_number` (including `0`, which protobuf reserves, and negatives,
  which would corrupt the shift). `decode_tag` returns whatever the low 3 bits
  give without validating it's one of 0/1/2/5. For a low-level primitive this is
  a defensible "trust the caller" design, but worth a deliberate decision +
  one-line doc note, since field 0 / wire type 6–7 are wire-illegal.

#### Minor (2)

- **[src/protobuf/wire.mojo:36 — `shift: UInt64`]** — `shift` is a loop counter
  only ever compared to `64` and used as a shift amount; `Int` would be the
  idiomatic stdlib choice (cf. `Int.__lshift__`). `UInt64 << UInt64` works (tests
  pass) but mixing the counter type with the value type is slightly unusual. NFC.

- **[docs/concepts/wire-format.md:48 — "10 bytes" worst case]** — the doc says a
  64-bit two's-complement negative is "the worst case: **10 bytes**," which is
  correct. No error; noting only that the same doc's varint section says "1–10
  bytes" consistently. Verified, not a defect — included for completeness of the
  audit trail.

### Verified Correct

~21 claims verified accurate. Highlights:

- **Varint**: 7-bit groups, `0x80` continuation, little-endian, `150 →
  [0x96,0x01]` (test + doc + spec agree). `UInt64.MAX` encodes to exactly 10
  bytes. Truncation raises. `shift < 64` loop has no off-by-one (handles 1–10
  byte varints, including the 10th byte).
- **ZigZag**: `(n<<1)^(n>>63)` and `(n>>1)^-(n&1)` are exact inverses across
  `Int64.MIN`/`MAX` (empirically). Arithmetic shift confirmed via
  `simd.mojo` `pop.shr`. `Int64.MIN << 1` does not trap. `UInt64(Int64)`
  reinterprets bits.
- **Tags**: `(field_number<<3)|wire_type`; `WIRE_VARINT=0, WIRE_I64=1,
  WIRE_LEN=2, WIRE_I32=5` all match spec; `encode_tag(3, WIRE_LEN) → 26`.
- **Mojo syntax**: `def` used throughout; `decode_varint`/`decode_tag` correctly
  marked `raises` (and the non-raising `encode_*`/`zigzag_*` correctly are not);
  `def main()` does NOT imply raises (confirmed — a non-raising probe failed to
  compile). `comptime` (not `alias`) for `VERSION` and `WIRE_*`. `Span[Byte, _]`
  unbinds origin correctly. `Byte` prelude alias used (commit 86974c7 removed a
  redefinition). `Tuple[Int, Int]` return with `var fnum, wtype = ...` unpack
  works. `List[Byte]` literals work.
- **Docstrings**: concise, signature-appropriate Args/Returns/Raises; no verbose
  restatement. Conform to stdlib style.
- **Tooling**: `pixi.toml` correctly replaces the removed `mojo test` with `mojo
  run -I src test/test_wire.mojo` (confirmed `mojo test` no longer exists);
  channels (`conda-forge`, `max-nightly`) sane; `ci.yml` `cache: false` until
  lockfile is reasonable. No dangling references to the deleted
  `test/test_protobuf.mojo` (its `test_version` was migrated into
  `test_wire.mojo`). Test runner uses the documented
  `TestSuite.discover_tests[__functions_in_module()]().run()`.
- **Full suite runs green**: 7/7 pass.

Key sources checked: protobuf encoding spec; `mojo/stdlib/std/builtin/simd.mojo`,
`builtin/int.mojo`, `testing/suite.mojo`, `testing/__init__.mojo`;
mojo-stdlib-contributing SKILL; live execution of the suite + custom edge-case
harness.
