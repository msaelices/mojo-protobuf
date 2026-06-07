## Adversarial Review: mojo-protobuf #25 (non-packed repeated + Copyable)

### Methodology

Files read:
- `codegen/protoc_gen_mojo.py` — new non-packed branch (`gen_message`, lines 406-477),
  `_check_field` (300-316), `_NONPACKED_REPEATED` (297), struct header (608), decode
  elif-chain assembly (587-600).
- Runtime helpers: `src/protobuf/fields.mojo` (`write_string` 118, `write_bytes` 112,
  `read_string` 232, `read_bytes` 201-209, `skip_field` 314), `src/protobuf/size.mojo`
  (`bytes_field_size` 65, `string_field_size` 70, `tag_size` 28, `varint_size` 18),
  `src/protobuf/message.mojo` (`trait Message` 103, `decode` driver 460-465).
- Tests: `codegen/test_protoc_gen_mojo.py`, `test/test_codegen.mojo`,
  `test/test_interop.py`, `test/proto/rep.proto`, docs.

Generator runs:
- `pixi run test-codegen-unit` (13 pass), full `pixi run test` (codegen-e2e 8, interop 10).
- Generated `rep.proto` and inspected `/tmp/r25/rep.mojo`.
- Authored an adversarial `adv25.proto`: singular `int32` before/after repeated;
  `repeated string` (incl. empty element); TWO `repeated Inner` message fields (`_sz`
  scope check); `Inner` used both repeated and singular (`solo`); TWO `repeated bytes`
  fields (`_b_<name>` collision check); nested `Inner` with its own `repeated string` +
  `optional int32`; empty repeated/empty bytes/empty inner. Inspected `/tmp/adv25/adv25.mojo`.

Byte-compares against reference protobuf (pixi protoc + python protobuf):
- adv25 full message: Mojo `encode` produced **byte-identical** output to
  `SerializeToString()` (76 bytes incl. empty string `18 0`, empty bytes `34 0`, empty
  nested msg `26 0`, negative varint `64 253 255...1`, interleaved fields).
- Compiled+ran a Mojo round-trip of adv25 (`ADV_OK`), a robustness test
  (`ROBUST_OK`: bytes-aliasing copy survives clobbering the source buffer; single
  occurrence; malformed sub-message raises), and a multi-byte UTF-8 test (`UTF8_OK`:
  `len(encode) == encoded_size()`).

### Issues Found (3 total)

#### Critical (0)
None. Non-packed encode/decode is wire-correct in every case tested.

#### Factual Errors (0)
None.

#### Completeness Gaps (1)

1. **`test/test_codegen.mojo:170-188` / decode robustness** — The suite never exercises
   the **malformed repeated-message sub-message** decode path or a **single-occurrence**
   repeated field; it only tests 2-element lists + the empty case. I verified externally
   (`ROBUST_OK`) that a truncated `decode[M](read_bytes(...))` raises and that a length-1
   repeated field round-trips, so this is a coverage gap, not a defect. Worth a small
   added assertion (e.g. `assert_raises` on a truncated nested message), but not blocking.

#### Inconsistencies (0)
None. `_sz` (repeated message, loop-scoped), `_sz_solo` (singular message), `_b_<name>`
(per-field) are all distinct; two repeated-message and two repeated-bytes fields generate
correctly with no name collisions (verified in `/tmp/adv25/adv25.mojo`).

#### Questions (1)

1. **`docs/concepts/codegen.md` Copyable note / `protoc_gen_mojo.py:608`** — `Copyable`
   in current Mojo does NOT imply `ImplicitlyCopyable`. The docs example
   `r.tags = [Tag("k", "v")]` works (constructor rvalues move into the list — verified
   `lit.mojo` prints `2`), but copying a *named* existing message value requires an
   explicit `.copy()` or `^` transfer (e.g. `m.a = [i0.copy(), i1.copy()]`,
   `m.solo = i2.copy()` — I hit `value of type 'Inner' cannot be implicitly copied` until
   I added `.copy()`). The doc phrasing "copied like the value types they are" could
   mislead a user into expecting implicit copy. Question: intentional to leave structs
   `Copyable`-but-not-`ImplicitlyCopyable`? (This is the standard/safe choice; just flag
   the doc nuance.)

#### Minor (1)

1. **Generated import lines >80 cols** (`/tmp/adv25/adv25.mojo` lines: `from
   protobuf.fields import ...` 115 cols, `from protobuf.size import ...` 102 cols) — the
   `_imports_block` join is pre-existing and unchanged by this PR; the new helpers
   (`write_string`/`read_string`/`string_field_size`/`tag_size`/`varint_size`/`decode`)
   push some files further over 80. Generated code, so cosmetic only; noting per the
   line-length check. The size line `total += tag_size(num) + varint_size(UInt64(_sz)) +
   _sz` stays under 80.

### Verified Correct

- **Non-packed wire correctness, byte-for-byte vs reference protobuf**: `repeated string`
  (`write_string(num, _e)` / `string_field_size(num, _e)` / append `read_string`),
  `repeated bytes` (`write_bytes(num, Span(_e))` / `bytes_field_size(num, Span(_e))`),
  `repeated <message>` (`encode_tag(num, WIRE_LEN)` + `encode_varint(UInt64(encoded_size()))`
  + `encode_to`; size `tag_size(num)+varint_size(UInt64(sz))+sz`). adv25 output is
  identical to `SerializeToString()`.
- **size == bytes**: `len(encode(m)) == m.encoded_size()` asserted for adv25, rep Record,
  and multi-byte UTF-8 (`string_field_size` uses `as_bytes()` len, matching `write_string`).
- **Empty repeated emits nothing**: empty `names`/`blobs`/`tags` produce zero bytes (loop
  body never runs); decode yields length-0 lists (`test_codegen_repeated_nonpacked` empty
  case + adv25 byte-compare with empty elements `18 0`/`34 0`/`26 0` matching reference for
  *present-but-empty* elements).
- **Bytes aliasing copy is sound**: `var _b = List[Byte](); _b.extend(read_bytes(...));
  append(_b^)` survives clobbering the source buffer (`ROBUST_OK`). `read_bytes` returns a
  zero-copy view into `data`; the `.extend` copies out before the view can dangle.
- **Repeated message round-trip + nested-in-nested**: `Inner` with its own `repeated
  string`+`optional int32` round-trips inside `repeated Inner`; `Inner` reused as a
  singular `solo` field works (same struct, different code path).
- **Copyable validity**: every generated field type is Copyable (scalars, `String`,
  `List[Byte]`, `List[T]`, `Optional[T]`, nested generated structs which are themselves
  `(Message, Copyable)`). `trait Message(Defaultable, Movable, ...)` requires Movable, not
  Copyable, so `(Message, Copyable)` compiles (confirmed: all generated files compile).
- **No hot-path copies**: encode/size loops use `for ref _e in self.<f>:` (verified in
  generated output) — reference binding, no per-element copy. The `Copyable` change does
  not pessimize the encode path.
- **`_check_field` coverage**: repeated string/bytes/message allowed; repeated
  fixed32/fixed64/sfixed32/sfixed64/group rejected with "repeated of this type is not
  supported" (verified — these were never in PACKED, so rejection is pre-existing and
  preserved); `map<K,V>` rejected with the map-specific error. Packed numeric scalars
  (double/bool/...) still allowed.
- **Field-number ordering / interleaving**: `encode_items`/`size_items` sorted by number
  (582-585); adv25 interleaves singular `int32` (#1,#8) with repeated (#2-#7) and emits in
  ascending order matching the reference.
- **Decode robustness**: malformed nested sub-message raises (propagates out of
  `decode[M]`), `pos` advanced past the whole LEN blob by `read_bytes` regardless of inner
  outcome; single occurrence and zero occurrences both handled.
- **Interop both directions**: `test_rep_forward_*` and `test_rep_reverse_*` pass
  (byte-level, Mojo<->reference both ways).
- **No stale `(Message)` assertions**: `test_happy_path` updated to `(Message, Copyable)`;
  remaining `struct X(Message):` hits are hand-written docs/benchmark examples, not
  generator-output assertions.
- **Removed `test_repeated_string_unsupported`**: nothing else expected that error string
  (grep clean).
