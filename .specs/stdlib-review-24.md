## Adversarial Review: mojo-protobuf #24 (proto3 enum support)

### Methodology

- Read the full diff and every changed file: `codegen/protoc_gen_mojo.py`
  (SCALAR/PACKED enum entries, `_enum_constants`, `gen_file`),
  `codegen/test_protoc_gen_mojo.py`, `test/proto/enums.proto`,
  `test/test_codegen.mojo`, `test/test_interop.py`, `docs/concepts/codegen.md`,
  `pixi.toml`.
- Read the runtime helpers the generated code reuses: `src/protobuf/fields.mojo`
  (`write_int64` L64-67, `read_int64` L138-144, `read_packed_signed` L281-292),
  `src/protobuf/size.mojo` (`int64_field_size` L40-42, `varint_size` L18-25).
  Confirmed the enum arm reuses the *exact* int32 codepath
  (`Int64(...)` -> `encode_varint(UInt64(...))` / `varint_size(UInt64(...))`).
- Ran the generator on `enums.proto` (clean) and on crafted adversarial protos:
  a negative-valued enum, two flatten-colliding enums, an enum constant that
  collides with a flattened struct name, a deep nested enum, a top-level-only
  enum, and an out-of-range (open) enum value.
- Compiled and round-tripped the generated Mojo, and **byte-compared against the
  reference `protobuf`** (`protoc --python_out`) for the negative/packed case
  (identical 41-byte output) and the open-enum case.
- Ran `test-codegen-unit` (11), `test-codegen` (7), `test-interop` (8): all
  pass, matching the PR's claims.

### Issues Found (3 total)

#### Critical (1)

1. **codegen/protoc_gen_mojo.py:567-591 (`_enum_constants`)** — Enum-value
   constants are emitted with **no collision detection**, so the generator can
   produce a non-compiling file with duplicate `comptime` names, or a constant
   that shadows a generated struct. `_collect_messages` (L261-265) *does* guard
   message-name flattening collisions and even has a unit test
   (`test_struct_name_collision`), but `_enum_constants` has no equivalent.

   Evidence A (constant vs constant): proto enum value names are scoped to the
   enclosing scope, so two *different* enums can flatten to the same constant.
   `coll.proto` with top-level `enum A_B { ...; C = 5; }` and
   `enum A { ...; B_C = 9; }` (both valid proto3, protoc accepts) generates:
   ```
   comptime A_B_C = Int32(5)
   comptime A_B_C = Int32(9)
   ```
   Compiling: `error: invalid redefinition of 'A_B_C'` ... `note: previous
   definition here`. EXIT was 0 from the generator — the breakage is silent
   until the user's `mojo build`.

   Evidence B (constant vs struct): top-level `enum Foo_Bar { ...; Baz = 1; }`
   plus `message Foo { message Bar_Baz {} }` (distinct scopes, protoc accepts)
   generates `comptime Foo_Bar_Baz = Int32(1)` **and** `struct
   Foo_Bar_Baz(Message)`. Compiling: `error: cannot define a struct here with
   name 'Foo_Bar_Baz'` ... `note: conflicts with this previous declaration`.

   This is the same class of bug the PR explicitly defends against for messages
   ("a clear generator error rather than emitting wrong code"), left unhandled
   for enums. Fix: track emitted constant names (and the message/struct
   namespace) and `raise GenError` on collision, mirroring `_collect_messages`.
   Realistically rare in hand-written schemas, but the failure mode (silently
   emit code that won't compile) is exactly what the generator's design tries to
   avoid, and the flattening makes it strictly more likely than C++/Python where
   the scopes keep the names distinct.

#### Factual Errors (0)

#### Completeness Gaps (1)

1. **codegen/test_protoc_gen_mojo.py:109 (`test_enum_supported`)** — No unit test
   asserts that colliding enum constants raise (cf. the existing
   `test_struct_name_collision` for messages). Given the Critical above, a
   regression test should accompany the fix. (Gap, not a behavioral error in the
   shipped happy path.)

#### Inconsistencies (1)

1. **codegen/protoc_gen_mojo.py:582-590 vs 248-270** — `_enum_constants.walk`
   recurses into *all* `message_type` / `nested_type`, whereas
   `_collect_messages` skips synthetic `map_entry` messages (L257-259). In
   practice this is harmless: a map-entry message has no `enum_type`, so
   `emit(m.enum_type, ...)` iterates nothing and no spurious constant is
   produced (verified — a `map<string, Enum>` field is rejected earlier by
   `_check_field` anyway). Worth a one-line comment or an explicit
   `if m.options.map_entry: continue` for parity, so a future reader does not
   assume map entries are filtered here too. No wire/codegen impact today.

#### Questions (0)

#### Minor (0 actionable)

- Generated import line and the packed `read_packed_signed[...]` call exceed 80
  cols in `enums.mojo` (95 and 84). Pre-existing for `int32`/packed fields; enum
  reuses the same arms and does not make it worse. Not introduced by this PR.

### Verified Correct

- **Enum wire mapping incl. negative values.** Singular enum encodes via
  `write_int64(n, Int64(self.f))` and sizes via `int64_field_size(n,
  Int64(self.f))`; both funnel through `varint_size/encode_varint(UInt64(...))`,
  so a negative enum (`-1`) becomes a 10-byte two's-complement varint. Crafted
  `Signed { ZERO=0; NEG=-1; POS=5; }`, encoded a message and **byte-compared to
  the reference protobuf: identical 41-byte output** (`8 255 255 255 255 255 255
  255 255 255 1 ...`). `len(encoded) == encoded_size()` held (41 == 41), so
  encode/size agree on the 10-byte negative.
- **Packed repeated enum.** `repeated Signed` packed via the int32 PACKED spec;
  bytes (`18 11 5 255...1`) match the reference exactly. Decode accepts both the
  packed (`WIRE_LEN` -> `read_packed_signed[DType.int32]`) and non-packed
  (`else` -> per-element `Int32(read_int64(...))`) forms per spec.
- **Open enum.** Reference-encoded out-of-range value `999` (`8 231 7`) decodes
  to `Int32(999)` and re-encodes byte-identically — unknown values preserved,
  not clamped/dropped (it is a bare `Int32`).
- **Constant flattening.** Top-level `Color_RED`/`GREEN`/`BLUE = Int32(0/1/2)`,
  nested `Thing.Kind` -> `Thing_Kind_UNKNOWN`/`PRIMARY`, deeply nested
  `Outer.Inner.Deep` -> `Outer_Inner_Deep_D0/D1`. All numbers correct. Constants
  are valid module-level `comptime` (no `var`), emitted after imports / before
  structs; a top-level-enum-only file (no messages) compiles and the constants
  are still emitted.
- **Field-shape coverage.** Singular, packed `repeated`, `optional`
  (`Optional[Int32]`, encodes only when present), and nested-enum fields all
  generate, compile, and round-trip; the adversarial `Use` message exercised all
  shapes simultaneously.
- **Rejections still intact.** proto2 (syntax/required), group, fixed/sfixed,
  map, oneof still raise; `_UNSUPPORTED_TYPE` only had `TYPE_ENUM` removed.
  `test_enum_unsupported` was correctly converted to `test_enum_supported`
  asserting the Int32 field, both constants, the packed `List[Int32]`, and the
  SIMD decode helper; no lingering test expects enums to error.
- **Interop.** Both-direction drivers exercise singular + packed-repeated +
  optional + nested enum and compare to the reference; nested reference access
  `pb.Thing.PRIMARY` and top-level `pb.GREEN`/`pb.RED`/`pb.BLUE` are valid (both
  resolve to the right numbers). All 8 interop tests pass.
- **Docs.** `docs/concepts/codegen.md` and README accurately state enum ->
  `Int32` + `comptime E_VALUE` constants, nested flattening, and that
  `repeated` enum packs like `repeated int32`; enum removed from the unsupported
  list.
