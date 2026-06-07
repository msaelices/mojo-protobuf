## Adversarial Review: mojo-protobuf #26 (map<K,V> -> Dict[K,V])

### Methodology

Files read in full: `codegen/protoc_gen_mojo.py` (the whole generator, focusing on
`_gen_map_field` L336-465, `_is_map_field` L303-308, `_MAP_KEY_TYPES` L311-316,
`_check_field` L319-333, the parameterized `_Scalar.read` lambdas L67-137,
`_collect_messages` map_entries-as-dict L250-273, `gen_message` dispatch L484-487),
plus the diff to `codegen/test_protoc_gen_mojo.py`, `docs/concepts/codegen.md`,
`README.md`, `test/proto/maps.proto`, `test/test_codegen.mojo`, `test/test_interop.py`.
Runtime helpers cross-checked against `src/protobuf/{fields,size,wire,message}.mojo`
(signatures of `decode_tag` -> `Tuple[Int,Int]` with `mut pos`, `read_bytes` ->
`Span[Byte, data.origin]`, `read_string/read_int64/...`, `skip_field`, `encode_tag`,
`encode_varint`, `WIRE_LEN=2`, `tag_size`, `varint_size`, `*_field_size`).

Generator runs / experiments:
- Ran full suite: wire 28, fields 18, message 39, size 9, codegen-unit 14,
  codegen-e2e 10, interop 12 — all green (matches PR claim).
- NFC proof for `_Scalar.read`: regenerated example/telem/enums/rep with the
  origin/main generator and the PR generator; `diff` of all four is IDENTICAL.
- Authored adversarial `/tmp/adv.proto`: singular field before maps, `map<bool,int64>`
  (bool key, default-valued entry), `map<uint64,string>` (uint64 key, max-value key,
  default key+value entry), `map<string,Kind>` (enum value, default enum entry),
  `Inner` used both as a singular field and as `map<int32,Inner>` value, where `Inner`
  itself contains a `map<string,int32>` + `repeated string` + `optional int64`, a second
  `map<string,string>` (two maps), and a singular field after. Generated, compiled,
  round-tripped (`len(encode)==encoded_size()` asserted), and verified against the
  reference protobuf both ways.
- Single-entry byte-compares of `map<int32,Inner>`, `map<bool,int64>` default entry,
  `map<string,string>` default value, `map<uint64,string>` max key against
  `SerializeToString()`: the map-field bytes are byte-identical to the reference.
- Crafted raw bytes for last-key-wins, value-only entry (default key), key-only
  message-value entry (default message), unknown-field-inside-entry skip, and a
  truncated message-value entry (must raise).
- Drove all forbidden map key types (double/float/bytes/enum/message) through
  `gen_file` to confirm `GenError`.

### Issues Found (1 total)

#### Critical (0)

#### Factual Errors (0)

#### Completeness Gaps (1)
1. **codegen/protoc_gen_mojo.py:348-349** — `kf = next(x for x in entry.field if x.number == 1)` /
   `vf = next(... number == 2)` raise an **uncaught `StopIteration`** (not a clean
   `GenError`) if a `map_entry` descriptor is missing field 1 or 2. Evidence: fed a
   `map_entry` nested type with only the `key` field (no `value`) to `gen_file`; the
   plugin propagates a bare `StopIteration` instead of the file's promised "clear error".
   Severity is low: protoc always synthesizes both `key=1` and `value=2` for a real
   `map<K,V>`, so this is unreachable from genuine protoc output; it only matters as
   defensive hardening consistent with the module's stated "never silently wrong /
   clear error" philosophy. Optional fix: guard with a `GenError` if either field is
   absent.

#### Inconsistencies (0)

#### Questions (0)

#### Minor (2)
1. **test/gen/maps.mojo (generated)** — several emitted lines exceed 80 cols (up to
   115: the import lines, and the `var _entlen = ...` / `encode_varint(UInt64(... + ...))`
   entry-length lines, e.g. L75/L89/L108/L113). 15 over-long lines vs 2-5 in the other
   generated files. This is generated code (not run through mblack) and over-long
   import/decode lines already exist on `main`, so it is the established pattern, just
   notably worse here. Cosmetic only.
2. **docs/concepts/codegen.md:102** — "The output is byte-identical to the reference
   protobuf" is precisely true only for single-entry maps; for multi-entry maps `Dict`
   iteration order is unspecified so the byte *order* of entries can differ from the
   reference (proto itself leaves map serialization order unspecified, so this is not a
   correctness bug). The same optimistic phrasing is used elsewhere in the doc for
   non-map fields, so it is consistent, but a one-line caveat ("entry order is
   unspecified, like the reference") would be more precise.

### Verified Correct

- **Map wire correctness — always-both + default-valued entries.** Mojo encodes both
  key and value for every entry even at default: `map<bool,int64>` `{False:0}` ->
  `18 4 08 00 10 00`; `map<uint64,string>` `{0:""}` -> `1a 04 08 00 12 00`;
  `map<int32,Inner>` `{0:Inner()}` -> `... 08 00 12 00`. Byte-identical to the
  reference for the map field in every single-entry case checked.
- **size == bytes.** `assert_equal(len(encode(m)), m.encoded_size())` holds for the
  multi-entry, all-value-kinds adversarial message (and the PR's own `test_codegen_maps`).
  The size pass recomputes `_entlen` independently of encode and agrees, including the
  message-value path (`ksize + tag_size(2) + varint_size(vsz) + vsz` in both).
- **All value kinds:** scalar (`int32`), `string`, message, `bytes`, `enum` — all
  round-trip and interop both ways. Message value writes exactly
  `tag2 + varint(vsz) + encode_to`, entry-length varint covers it; byte-compared
  `map<int32,Inner>` single entry against reference (`50 07 08 05 12 03 34 01 7a`, identical).
- **Both key kinds:** `string` key and integral keys (`int32`, `uint64`, `bool`) all
  compile as `Dict` keys and round-trip; `uint64` max key (`18446744073709551615`)
  preserved.
- **`_Scalar.read` parameterization is NFC for non-map codegen.** All 11 rewritten
  lambdas preserve exact semantics (`Int32(read_int64(...))`, `UInt32(read_uint64(...))`,
  `Int32(read_sint64(...))`, `read_string`, `read_bool`, `read_double/float`, enum =
  `Int32(read_int64(...))`); regenerating example/telem/enums/rep with the old vs new
  generator yields byte-IDENTICAL output. Defaults (`s="data", p="pos"`) reproduce the
  prior `read_x(data, pos)` exactly at every singular/optional call site.
- **No local collisions / no trivial-`^` warnings.** A message with five maps + a
  repeated + an optional + interleaved singular fields compiles; name-qualified locals
  (`_entry_<f>`, `_ep_<f>`, `_k_<f>`, `_v_<f>`, `_efn_<f>`, `_ewt_<f>`, `_vb_<f>`) never
  collide; the `var _efn, _ewt = decode_tag(...)` tuple-unpack compiles. `^` is present
  for String key and String/bytes/message value, ABSENT for Int*/UInt*/Bool/enum; no
  "transfer has no effect" warning is emitted (`map<string,int32>` and `map<int32,Inner>`
  both clean).
- **Dict key/value validity.** `Dict[String|Int32|UInt64|Bool, ...]` all compile;
  values `Int32`, `String`, `List[Byte]`, message struct all valid (structs are
  `(Message, Copyable)`).
- **Last-key-wins.** Crafted two entries with key "a" -> Dict keeps the last value.
- **Decode robustness.** Value-only entry inserts under the default key; key-only
  message-value entry yields a default-constructed message; an unknown field number
  inside the entry is `skip_field`-ed without desync; a truncated message-value entry
  raises out of `read_bytes`/`decode` (does not silently truncate). The inner
  `while _ep < len(_entry)` cannot infinite-loop: `decode_tag`, every reader, and
  `skip_field` all advance `_ep`.
- **Key-type validation.** `map<double|float|bytes|enum|message, V>` each raise
  `GenError("... map key type N is not supported")`.
- **Non-map repeated message still `List[T]`.** `rep.proto` `repeated Tag` generates
  `var tags: List[Tag]` (not a Dict); `_is_map_field` does not swallow ordinary
  repeated messages.
- **Synthetic `*Entry` not emitted.** Zero `struct *Entry` in `maps.mojo` or the
  adversarial output; `map_entries` as a dict did not break `_collect_messages` or the
  `_enum_constants` map-entry skip.
- **Interop both ways.** Reference parses Mojo-encoded adversarial bytes and agrees on
  every field (incl. default-valued entries); reference-encoded single-entry maps decode
  in Mojo. PR's own 12 interop tests pass.
