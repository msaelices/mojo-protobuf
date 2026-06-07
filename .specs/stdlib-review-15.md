## Adversarial Review: mojo-protobuf #15 (protoc-gen-mojo code generator)

### Methodology

Verified ~30 claims against the actual runtime source, the generator, the
descriptor/plugin semantics, and by RUNNING the generator + compiling/executing
its output:

- Runtime helpers read in full: `src/protobuf/wire.mojo`, `fields.mojo`,
  `size.mojo`, `message.mojo`. Cross-checked every emitted call's signature and
  semantics (e.g. `fixed32_field_size(num)` takes only the field number `size.mojo:55`;
  `write_int64(num, Int64, output)` `fields.mojo:61`; `read_bytes` returns an
  aliasing `Span[Byte, data.origin]` `fields.mojo:198-206`).
- Generator `codegen/protoc_gen_mojo.py` read in full (412 lines).
- Ran the plugin on `test/proto/example.proto` and on **eight adversarial
  protos** under `/tmp/rev/`: field-less message, reserved-word fields
  (`var`/`in`/`type`), nested message, `map`, `fixed32`, `sfixed64`, nested-enum
  field, repeated message, proto2-optional, name-collision, no-package, and an
  all-15-types message.
- Compiled & executed generated output: example round-trip (`pixi run test-codegen`
  passes 2/2), an all-types round-trip with an explicit `encoded_size()==len(data)`
  assertion (PASS, 87 bytes), and a wire-interop check decoding Mojo-encoded bytes
  with the **reference Python protobuf** library (decoded id/utf8/bool/presence/
  negative-int32/nested correctly).
- `pixi run test-codegen-unit` passes 6/6.

### Issues Found (6 total)

#### Critical (1)

1. **`codegen/protoc_gen_mojo.py:364` (`gen_file`)** — **proto2 files are NOT
   rejected, and proto2 `optional` scalars are emitted as plain (presence-less)
   fields — silently wrong.** The syntax guard is
   `if fd.syntax and fd.syntax != "proto3":`. protoc leaves
   `FileDescriptorProto.syntax` **empty** for proto2 (confirmed:
   `HasField("syntax")==False`, `repr(fd.syntax)==''`), so the guard is skipped
   entirely. The only other proto2 gate is the `LABEL_REQUIRED` check
   (`:184`), which catches `required` but not proto2 `optional`. Result: a proto2
   file with `optional int32 a = 1;` generates a **plain `var a: Int32`**, losing
   proto2 explicit presence (it should be `Optional[Int32]`). Evidence: I ran the
   plugin on a `syntax = "proto2"` file with two `optional` fields — it exited 0
   and produced `var a: Int32` / `var s: String`. The PR body and
   `docs/concepts/codegen.md` both claim "proto2 syntax in general" raises a clear
   error; that claim is **false**. The `test_proto2_required_unsupported` unit
   test only exercises `required`, so it misses this. Fix: gate on
   `fd.syntax != "proto3"` (treat empty/absent as proto2 and reject), not on
   `fd.syntax and ...`.

#### Factual Errors (1)

2. **PR body / `docs/concepts/codegen.md` "Not yet supported" list** — claims
   "proto2 syntax in general" raises a clear generator error. It does not (see
   Critical #1). Every other row of the type-mapping and unsupported list was
   verified accurate (see Verified Correct).

#### Completeness Gaps (3)

3. **`_struct_name`/`_collect_messages` (`codegen/protoc_gen_mojo.py:141-154`) —
   flattened-name collisions emit two structs with the same name → uncompilable
   Mojo, with no GenError.** A top-level message `Outer_Inner` plus a nested
   `Outer.Inner` both flatten to `struct Outer_Inner`. Evidence: ran the plugin
   on such a proto (exit 0, two `struct Outer_Inner(Message):` at lines 10 and 78
   of the output) and compiled it: `error: invalid redefinition of 'Outer_Inner'`.
   The PR acknowledges "field name collisions after `_` suffixing are not checked"
   but says nothing about struct-name collisions. Low real-world likelihood, but
   it is silent codegen breakage rather than a loud GenError. Detect duplicate
   mangled names in `_collect_messages` and raise `GenError`.

4. **`test/test_codegen.mojo` — no round-trip coverage for most supported types.**
   The only fixture (`test/proto/example.proto`) uses just `int64`, `int32`
   (only inside nested `Point`), `string`, `bool`, `bytes`, `optional string`,
   `optional int64`, and a nested message. **Zero** committed e2e coverage for
   `double`, `float`, `uint32`, `uint64`, `sint32`, `sint64`, a top-level plain
   `int32`, `optional bytes`, or any other `optional` scalar variant. I verified
   all of these DO round-trip and size-match by generating+running an all-types
   message (PASS), so the code is correct — but the suite would not catch a future
   regression in, e.g., the sint zigzag or float arms.

5. **Wire interop is claimed but not in CI.** `docs/concepts/codegen.md` and the PR
   body claim the output "round-trips against the reference protobuf
   implementation … encode in Mojo, decode in Python and vice versa." No such
   interop test is committed (the only e2e test is Mojo-internal). I reproduced it
   manually and it DOES work, but the reproducible claim rests on a test that does
   not exist in the suite.

#### Inconsistencies (0)

#### Questions (0)

#### Minor (1)

6. **Non-canonical field order on the wire (`encode_to`).** Generated `encode_to`
   emits fields in **declaration order**, not field-number order (verified: the
   example emits tags in order `1, 5, 3, 7, 9, 10`). This is wire-valid and
   reference protobuf decodes it fine, but it means Mojo output is not
   byte-identical to protobuf's canonical (number-ordered) serialization
   (`reserialize == original` was `False` in my interop check, solely due to
   reordering field 5 before field 3). The doc already flags canonical proto3
   omission as a follow-up; field ordering deserves the same one-line caveat since
   the doc says output "round-trips against the reference … on the wire." Also
   minor: the output-filename fallback for a name not ending in `.proto`
   (`proto_name + ".mojo"`, `:404-405`) is dead in practice since protoc always
   passes `.proto` names.

### Verified Correct

- **size ↔ encode ↔ decode agreement for ALL 15 supported arms** — verified by
  executing an all-types round-trip with `assert len(data) == encoded_size()`
  (PASS). Spot-checks against the runtime:
  - `int32`/`uint32` conversions: `write_int64(n, Int64(x))` /
    `int64_field_size(n, Int64(x))`; `write_uint64(n, UInt64(x))` /
    `uint64_field_size(n, UInt64(x))` (`:88-99`) — match `fields.mojo:55,61` and
    `size.mojo:35,40`. Negative `int32 = -3` correctly emits a 10-byte varint and
    the size arm counts 10 (confirmed in interop dump).
  - `sint32`/`sint64`: `write_sint64`/`sint64_field_size` (zigzag) `:100-111` —
    match `fields.mojo:67`, `size.mojo:45`; `sint32 = -42`, `sint64 = -123456789`
    round-tripped.
  - `double`/`float`: `fixed64_field_size(n)` / `fixed32_field_size(n)` take only
    the field number `:64-75`, matching `size.mojo:55,60`.
  - Nested message length-prefix: `encode_tag(n, WIRE_LEN)` +
    `encode_varint(UInt64(sub.encoded_size()))` + `sub.encode_to` `:213-217`, with
    the size arm computing `tag_size(n) + varint_size(UInt64(sz)) + sz` `:218-222`
    — byte-exact, matching `message.mojo:278-284`.
- **Decode memory safety** — both plain and optional bytes arms copy out of the
  `read_bytes` aliasing view via `List[Byte]()` + `.extend(read_bytes(...))`
  before storing (`:255-257`, `:267-272`); the nested arm uses
  `decode[M](read_bytes(...))` (`:223-226`). Confirmed correct against
  `fields.mojo:198-206`.
- **elif-chain / single-field / field-less messages** — first field stays `if`,
  subsequent become `elif`, trailing `else: skip_field` always present; a
  field-less message emits a bare `skip_field` decode body (`:307-320`). Verified
  in generated `Point` (if/elif/else), `Outer_Inner` (single if/else), and
  `Empty` (bare skip), all of which compile and run.
- **Field NUMBERS not positions** — `example.proto` (`name=5`, `active=3`) emits
  `write_string(5, ...)`, `write_bool(3, ...)`, `elif field_number == 5/3`
  (test/gen/example.mojo:78-79,98-100). Confirmed.
- **proto3 `optional` vs real oneof** — `_check_field` (`:181-189`) raises only
  when `HasField("oneof_index") and not proto3_optional`, so the synthetic oneof
  of a proto3 `optional` field is NOT mistaken for a real oneof; `nickname`/`age`
  correctly became `Optional[...]`. Real oneof rejected (unit test + reasoning).
- **Unsupported features fail loudly** — ran the plugin and got clean GenErrors
  for `map` ("repeated…", it is LABEL_REPEATED), `fixed32`, `sfixed64`, nested
  `enum` used as a field type (TYPE_ENUM → "enum…"), `repeated` message, and
  cross-file message refs (`type_name not in type_map`, `:165-169`). Top-level
  enum decls rejected at `gen_file:373`. All produce non-zero protoc exit.
- **Identifier suffixing** — `var`/`in`/`type` → `var_`/`in_`/`type_` (ran it);
  `_RESERVED` (`:33-39`) covers the relevant Mojo keywords. All field accesses are
  `self.`-qualified, so no collision with method locals (`output`, `pos`, `total`,
  `data`, `field_number`, `wire_type`).
- **Plugin protocol** — `response.supported_features = FEATURE_PROTO3_OPTIONAL`
  is set (`:390-392`); without it protoc would reject proto3 `optional`. On
  `GenError`, `response.error` is set and the response is still written to stdout
  (`:399-402`).
- **`@fieldwise_init` omission for field-less messages** (`:323-325`) — `Empty`
  compiles (no clash with the no-arg `__init__`). No unused imports are emitted
  (imports accumulate per-arm); generated all-types module compiled clean.
- **Nested/sibling forward references** — `Outer` references `Outer_Inner` defined
  later in the file; Mojo allows module-scope forward refs (compiled + ran).
- **Wire interop** — Mojo-encoded `Person` decoded correctly by the reference
  Python protobuf library (id=42, utf8 name "Adaé", bool, nickname present, age
  absent, bytes [1,2,255], `int32 = -3`, nested `Point`).
