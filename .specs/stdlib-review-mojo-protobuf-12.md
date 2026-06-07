# Adversarial Stdlib Review: msaelices/mojo-protobuf #12

"Support `List[Byte]` (protobuf `bytes`) fields in the reflection default"

## Methodology

Applied stdlib-level technical rigor to a personal pure-Mojo protobuf library
(process rules — changelog, `Assisted-by: AI`, GH-issue-first, draft procedure —
deliberately ignored as out of scope for this repo).

Verified the change by reading the diff and the actual source of the helpers it
calls, then PROVING the make-or-break claims with executed probes (`pixi run
mojo run -I src ...`, since bare `mojo` 1.0.0b1 cannot run `reflect`):

Sources read as ground truth:
- `src/protobuf/message.mojo` — the three reflection methods (`encoded_size`,
  `encode_to`, `merge_field`) and the new `List[Byte]` arms (lines 119-120,
  149-150, 210-215).
- `src/protobuf/fields.mojo:198-206` — `read_bytes` returns
  `Span[Byte, data.origin]` (a zero-copy VIEW into the decode input).
- `src/protobuf/wire.mojo:236-261` — `decode_bytes` (bounds-checked, returns
  `data[start : start+length]`, a view) and `encode_bytes:223-233`.
- `src/protobuf/size.mojo:65-67` — `bytes_field_size = tag_size + varint_size(len)
  + len`.
- Mojo stdlib `mojo/stdlib/std/collections/list.mojo:881-920` — the
  `extend(Span)` overload, which calls `uninit_copy_n[overlapping=False]` into
  freshly reserved storage (a genuine deep copy, no aliasing).

Probes executed (all under `pixi run`):
1. Dangling-view: decode a `Blob`, then clobber EVERY byte of the input buffer
   with `0xEE`; assert `got.data` unchanged. PASS.
2. Input-drop: decode inside an inner scope so the source buffer is destroyed,
   then read the field. PASS.
3. Repeated field (move-assign): concatenate two encodings so field 2 appears
   twice; assert last-one-wins and no crash/abort. PASS.
4. Multi-byte length: 200-byte payload (2-byte length varint). PASS, with
   `len(encode) == encoded_size()`.
5. Very large: 20000-byte payload (3-byte length varint). PASS, size agrees.
6. Size agreement: empty / small / 150-byte cases all agree.
7. Encode-borrow: `encode(b)` twice, assert field still intact afterward. PASS.
8. Dispatch: a struct with a `List[Int]` field through the defaults — confirmed
   it hits the `comptime assert False, "Message: unsupported field type"` guard
   (compile error), i.e. does NOT mis-match `_BYTES_NAME`. PASS.
9. Explicit empty bytes on the wire (length prefix 0) round-trips. PASS.
10. Truncated length prefix (bumped to 99) raises out of `decode`. PASS.

All probe files were removed after running.

## Issues Found (2 total)

### Critical (0)

None. The highest-priority correctness concerns were all PROVEN sound:

- **No dangling view / no use-after-free.** `read_bytes` returns a view into the
  input (`fields.mojo:200`, origin `data.origin`), but the decode arm
  (`message.mojo:211-212`) does `var owned = List[Byte](); owned.extend(view)`.
  `List.extend(Span)` (`list.mojo:913` `uninit_copy_n[overlapping=False]`) copies
  into fresh storage. Probe 1 clobbered the entire input buffer post-decode and
  the field was unchanged; probe 2 dropped the input buffer entirely and the
  field stayed valid. The decoded field genuinely OWNS its bytes.
- **Move-assign is sound, no leak / double-free.** `rebind[List[Byte]](field_ref)
  = owned^` (message.mojo:213-215) move-assigns into a field that already held a
  (default or prior) `List`. Probe 3 decoded a buffer with the bytes field twice;
  last value won, with no abort — the first `List` is properly destroyed by the
  move-assign before `owned` is moved in.
- **Encode/size borrow, no copy/consume.** `Span(rebind[List[Byte]](f))`
  (message.mojo:120, 150) reinterprets then borrows the field; probe 7 encoded
  the same message twice and the field remained intact (2 bytes, original
  contents). `encode_to` takes `self` borrowed.
- **Dispatch is distinct.** `_BYTES_NAME = reflect[List[Byte]].name()` matched a
  `var data: List[Byte]` field and probe 8 confirmed a `List[Int]` field does NOT
  match it — it falls through to the unsupported-type `comptime assert False`
  guard, a clean compile error rather than a mis-encode.

### Factual Errors (0)

None. The docstring/docs claims are accurate:
- `read_bytes` docstring ("zero-copy view into `data`", `fields.mojo:201`) matches
  the implementation.
- The added docs/trait prose ("`List[Byte]` (protobuf `bytes`)") matches the new
  arms; the supported-types list in both `docs/concepts/messages.md` and the
  trait docstring was updated consistently.

### Completeness Gaps (2)

1. **[test/test_message.mojo:286-298]** — No test proves OWNERSHIP, which is the
   entire point of this arm (the bytes arm differs from every scalar arm
   precisely because decode must take ownership of a view). `test_reflection_
   bytes_field` decodes into `got` and reads it, but never perturbs or drops the
   source buffer, so it would still pass even if the field were a dangling view
   into the input. Add a test that mutates/drops the input buffer after decode
   and asserts the field is unchanged (proven correct here by probe 1/2 — the
   behavior is right, only the regression coverage is missing). This is the
   single most valuable test to add, since a future refactor of `read_bytes`/
   `extend` could silently reintroduce a view without any existing test catching
   it.

2. **[test/test_message.mojo:286-301]** — Coverage is shallow. The only
   round-trip is a 3-byte payload (1-byte length prefix), so neither the 2-byte
   (>=128) nor 3-byte (>=16384) length-varint paths are exercised, and there is
   no test for: a repeated/duplicated bytes field (move-assign / last-wins, the
   prior-`List`-drop path), an explicit empty bytes field present on the wire
   (length prefix 0, the zero-length `extend` path — distinct from the absent-
   field `test_reflection_bytes_empty`), or a truncated length prefix raising.
   All four behave correctly (probes 3, 4/5, 9, 10) but are untested. Add at
   least the >=128-byte round-trip with `len(encode) == encoded_size()` and the
   duplicate-field last-wins case.

### Inconsistencies (0)

None. The `List[Byte]` arm mirrors the `String` arm in all three methods
(`encoded_size`/`encode_to`/`merge_field`) and reuses the existing
`bytes_field_size`/`write_bytes`/`read_bytes` helpers that `string_*` already
delegates to. Placement of the new `elif name == _BYTES_NAME` branch (after
`_STRING_NAME`, before `_FLOAT32_NAME`) is consistent across all three methods
and matches the constant declaration order.

### Questions (0)

None blocking. (One observation, not a defect: this library does not skip
zero/default scalar fields on encode — `encode_to` always writes every field —
so an all-default message still emits its scalar fields. This is pre-existing,
unrelated to this PR, and consistent with the rest of the codebase; noted only
because it affected a probe's arithmetic, not the PR.)

### Minor (0)

None.

## Verified Correct

10 probed behaviors verified accurate; the implementation is correct and
memory-safe. The two findings are coverage gaps in the tests, not defects in the
code. Key sources checked: `src/protobuf/message.mojo` (lines 119-120, 149-150,
210-215), `src/protobuf/fields.mojo:198-206`, `src/protobuf/wire.mojo:236-261`,
`src/protobuf/size.mojo:65-67`, and Mojo stdlib
`mojo/stdlib/std/collections/list.mojo:881-920` (`extend(Span)` =>
`uninit_copy_n`).

The two make-or-break points called out by the orchestrator are both PROVEN
sound:
- (a) the decoded bytes are an OWNED COPY, not a dangling view — clobbering or
  dropping the input buffer leaves the field intact (probes 1, 2);
- (b) the move-assign on a repeated bytes field correctly drops the field's prior
  `List` with no abort/leak, and last-one-wins (probe 3).
