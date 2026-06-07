## Adversarial Review: mojo-protobuf #27 (oneof + optional message)

### Methodology

Files read in full:
- `codegen/protoc_gen_mojo.py` (PR + `origin/main` via `git show` for diffing generator behavior) — `gen_message` oneof grouping (lines 481-500), the message-arm `optional` branch (lines 651-702), the sibling-clear post-process (lines 778-792), the removed `_check_field` oneof rejection (lines 320-330), the if→elif rewrite (lines 801-814).
- Runtime helpers: confirmed `decode[M]` (`src/protobuf/message.mojo:439`), `read_string`/`read_bytes`/`read_int64`/`read_bool` (`src/protobuf/fields.mojo`) — every symbol the new arms emit exists and matches the call shape.
- `test/test_codegen.mojo`, `test/test_interop.py`, `test/proto/oneof.proto`, `docs/concepts/codegen.md`, `README.md`.

Generator runs / experiments:
- `pixi run codegen-gen` + full read of generated `test/gen/oneof.mojo` (struct M with 7 oneof members across 2 oneofs + interleaved singular field 20; struct HasOpt = `optional Inner`).
- **NFC proof**: regenerated example/telem/rep/maps/enums with the `origin/main` generator via `pixi run protoc` and `diff`'d against the PR output — all five **byte-for-byte UNCHANGED**.
- Authored an adversarial proto (`Outer` with a 5-member oneof whose message member type `HasOneof` *itself* contains a oneof, plus a second nested-oneof message) — generated, compiled, byte-compared and round-tripped against the reference `protobuf` (all via `pixi run protoc`/`pixi run python`/`mojo run`).
- Byte-exact compares (Mojo vs reference `SerializeToString`) for every member kind set, both at a non-default and at its **default** value (string "", int32 0, bytes empty, enum 0, bool false), surrounded by non-default singular fields.
- **Last-one-wins** decode in both orders (`i` then `s`; `s` then `i`) cross-checked against reference `WhichOneof`.
- Independent-oneofs-don't-cross-clear runtime decode (text in `payload` + ok in `status` both retained, matching reference `WhichOneof` on each).
- `optional Message` present-empty / absent, both encode-side bytes and forward-decode of reference bytes.
- `size == len(encode)` checked for nested-message-member and optional-message paths.
- Full suite: `pixi run test` → wire 28, fields 18, message 39, size 9, codegen-unit 16, codegen-e2e 12, interop 14. All green.

### Issues Found (1 total)

#### Critical (0)
None.

#### Factual Errors (0)
None.

#### Completeness Gaps (0)
None blocking. (See the Minor note on default-scalar omission, which the PR already documents.)

#### Inconsistencies (0)
None.

#### Questions (0)
None.

#### Minor (1)

1. **`codegen/protoc_gen_mojo.py:659-681` / `docs/concepts/codegen.md`** — An `optional Message` (or oneof message member) that is **present but empty** does not re-encode byte-identically to the reference, because the *inner* message still emits its default-valued singular scalars. Example: `HasOpt{ maybe = Inner{} }` (Inner has `int32 n = 1`) encodes in Mojo as `0a02 0800` vs the reference's `0a00`. This is **not** a oneof/optional-message defect: the outer presence framing (tag + length, and absent⇒nothing) is correct, presence round-trips correctly, and forward-decode of the reference's `0a00` yields a present `Inner` with `n=0` (verified). The divergence is the pre-existing "proto3 default-valued scalar omission is a follow-up" limitation, which affects plain singular message fields identically and which the PR explicitly documents (`docs/concepts/codegen.md`: "Canonical proto3 omission of default-valued scalars is still a follow-up"). No code change required; noting only because a reader might expect "present-but-empty" to be byte-exact across implementations. The PR's own docs/tests do NOT claim byte-exactness here (they claim presence-distinct-from-absent, which holds).

### Verified Correct

- **Oneof wire correctness, every kind**: string/int32/message/bytes/enum oneof members each byte-exact vs the reference for a set member surrounded by non-default singular fields.
- **Default-valued member still serialized (presence)**: `text=""`, `count=0`, `raw=empty`, `kind=0`, `ok=false` each emit their tag + value byte-exact with the reference (`08011a00…`, `…2000…`, `…3200…`, `…3800…`, `…5000…`). Only the set member is written.
- **`size == len(encode)`** for the message-member path (`Optional[M]`) and the optional-message path — verified `len(encode(m)) == m.encoded_size()` is True.
- **Last-one-wins on decode**: raw bytes with two members of one oneof decode to the LAST member; both orders (`i`-then-`s` ⇒ s; `s`-then-`i` ⇒ i) match reference `WhichOneof`.
- **Independent oneofs don't cross-clear**: decoding `text` (payload) + `ok` (status) keeps both; the generated sibling-clears for field 3 clear only {count,sub,raw,kind} (same oneof), never {ok,err}. Confirmed in generated source (`oneof.mojo:115-152`) and at runtime.
- **Sibling-clear post-process targets the right block**: clears land *inside* each oneof member's `elif` (e.g. field 3's clears at lines 117-120), and the trailing non-oneof field 20 (`trailer`) and the singular `id` (field 1) get **no** clears (no off-by-one). The bytes oneof member (field 6, multi-line body `var _b_raw; extend; self.raw = Optional(...)`) gets its clears appended *after* all its lines, still inside the branch. Clear-line indentation is 12 spaces, matching the branch body; compiles.
- **Post-process runs before the if→elif rewrite**: confirmed by source order (lines 781-792 precede 801-807); at post-process time all branches are `if field_number == N:`, so `int(s[len("if field_number == "):].rstrip(":"))` parses correctly for the first (`if`) and subsequent members.
- **`optional Message` arm**: non-optional singular message UNCHANGED (`Person.location` still `var location: Point`, always-encoded — example.mojo byte-identical to origin/main). `optional Message`/oneof message members emit `Optional[M]` with `if self.x:` encode, `Optional[M](decode[M](...))` decode, `self.x.value().encoded_size()/encode_to`. Absent ⇒ emits nothing (verified `b""`); forward-decode of reference present-empty ⇒ present.
- **`optional Message` was genuinely broken before**: origin/main's message arm ignored `optional` and emitted plain always-encoded `M`, so an "absent" optional message would still write a tag+len — a real wire bug the PR fixes. No existing test asserted the old behavior.
- **proto3 synthetic-optional is NOT treated as a real oneof** (highest-risk regression): grouping and the `optional=True` forcing are both guarded by `not f.proto3_optional` (lines 485, 495). example.proto has `optional` scalars/bytes (nickname/age/ou32/od/ob) — `example.mojo` is byte-for-byte UNCHANGED vs origin/main, and its `merge_field` contains **no** `self.<x> = None` sibling-clears (the only `= None` lines are `__init__` defaults). The synthetic single-member oneof yields a plain `Optional[T]`.
- **Multi-oneof / nested-oneof compile + round-trip**: adversarial `Outer` (5-member oneof, message member whose type has its own oneof, interleaved singular `tail`) compiles with no warnings and round-trips byte-exact (`nested_with_oneof` mojo==ref).
- **Empty message**: no oneof member set ⇒ oneof emits nothing; decodes to all-None members.
- **Flat decode blocks**: oneof members are always singular (proto3 forbids repeated/map in a oneof), so no member nests a second `if field_number ==`; the post-process's block-boundary scan is sound. The packed-repeated nested `if wire_type` arm is unreachable for oneof members.
- **`_check_field` no longer rejects real oneofs**; still rejects proto2 required, repeated-of-unsupported-type, etc.
- **Interop both ways incl WhichOneof**: 14 interop tests pass, including `test_oneof_reverse` (Mojo encodes → reference `WhichOneof('payload')=='sub'`, `WhichOneof('status')=='err'`) and `test_oneof_forward` (reference `count=0`,`ok=True` → Mojo decodes count present, ok present, last-wins).
- **NFC on all existing protos**: example/telem/rep/maps/enums regenerate byte-identically (post-process is a strict no-op when `oneof_clears` is empty).
- **Docs/README accuracy**: codegen.md Oneofs section (Optional-per-member, last-one-wins, no WhichOneof, set-at-most-one, default-valued-member-present) and the `optional Message`→`Optional[M]` note match the implementation; README status/roadmap updated.
