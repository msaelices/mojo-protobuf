## Adversarial Review: mojo-protobuf #29 (cross-file references)

### Methodology
- Read the full PR diff and the entire post-PR `codegen/protoc_gen_mojo.py` (1056 lines), plus the test diffs (`codegen/test_protoc_gen_mojo.py`, `test/test_codegen.mojo`, `test/test_interop.py`), the new protos (`test/proto/common.proto`, `place.proto`), `pixi.toml`, `docs/concepts/codegen.md`, `README.md`.
- **NFC diff**: created two worktrees (`origin/main`, `origin/feat-crossfile`), generated the six pre-existing single-file protos (example/telem/enums/rep/maps/oneof) with each generator into `/tmp/gen-old` vs `/tmp/gen-new`, and byte-diffed each `.mojo`. All six **IDENTICAL**.
- **Full suite** on the PR branch via `pixi run test`: wire 28, fields 18, message 39, size 9, codegen-unit 18, codegen-e2e 13, interop 16 — all green (matches PR claim).
- **Adversarial multi-file generation** under `/tmp/adv`: a `target.proto` importing two deps (`a.proto`, `b.proto`) and exercising a cross-file dep type as singular + repeated + map-value + optional + oneof-member; a same-Mojo-name collision across two files (`a.Geo` + `b.Geo`); a local-vs-imported `Geo` clash; a `google.protobuf.Timestamp` reference; a proto2 dep file referenced from proto3. Compiled the results with `pixi run mojo run -I src -I /tmp/adv/gen ...` to observe what breaks.
- Checked `_module_path` edge cases and the `gen_file` partial-args contract directly in Python.

### Issues Found (8 total)

#### Critical (3)

1. **Cross-file same-Mojo-name collision emits ambiguous, non-compiling Mojo with no error.** `codegen/protoc_gen_mojo.py:907-919` (`_imports_block`) emits one `from <module> import <names>` line per source file, and `_Resolver.message_type` (`:322-339`) records imports with no global Mojo-name uniqueness check. Two dep files whose structs flatten to the same Mojo name, both referenced by one target, produce:
   ```
   from a import Alpha, Geo
   from b import Beta, Geo
   ```
   `mojo` rejects this: `error: import of 'Geo' is ambiguous`. The per-file collision guard (`_file_structs`, `:293`) only protects names *within* one file; nothing guards cross-file Mojo-name clashes. Reproduced and compile-failed. The PR has no detection and the docs do not warn about it.

2. **Cross-file type whose Mojo name collides with a LOCAL struct emits non-compiling Mojo.** Same root cause. A target with a local `message Geo` plus a field referencing an imported `ld.Geo` emits both `struct Geo(...)` and `from localdep import Geo` in the same module. `mojo`: `error: cannot define a struct here with name 'Geo' ... conflicts with this previous declaration / from localdep import Geo`. Reproduced and compile-failed. No guard at `_imports_block`/`_Resolver` for an imported name shadowing a locally generated struct name (the `struct_names` set built at `:991` is only used against enum constants, not against `module_imports`).

3. **Well-known / non-generated dependency references emit a DANGLING import instead of erroring (contradicts the PR's central "still error" claim).** With global registration in `main()` (`:1030-1035`) running over *every* `request.proto_file`, when protoc resolves `import "google/protobuf/timestamp.proto"` it includes that descriptor in `proto_file`, so `_register_types` registers `.google.protobuf.Timestamp -> Timestamp` with file `google/protobuf/timestamp.proto`. A `google.protobuf.Timestamp` field then resolves via the registry (`_Resolver.message_type`, `:324-331`) and emits `from google.protobuf.timestamp import Timestamp`. But `timestamp.proto` is not in `file_to_generate`, so no `google/protobuf/timestamp.mojo` is ever produced. Result: a dangling import — `mojo`: `error: unable to locate module 'google'`. Reproduced (passed the WKT include dir to protoc; output emitted the import, no error, no module file). The same dangling-import class also occurs for a **proto2 dep** referenced from proto3 (e.g. `from p2dep import Old` where `p2dep.proto` is never and cannot be generated) — the old generator errored ("cross-file refs unsupported"); the PR silently emits broken Mojo. `_WELL_KNOWN = {}` (`:309`) is now dead for this case because the registry resolves the type *before* the `_WELL_KNOWN` fallback is reached (`:332`).

#### Factual Errors (1)

4. **Docs claim WKT references error; they do not.** `docs/concepts/codegen.md` ("Not yet supported"): "well-known types (`google.protobuf.Timestamp`, etc.) — a cross-file reference to one errors until a builtin module is provided." Proven false by Critical #3: it emits a dangling import, no error. The module docstring (`codegen/protoc_gen_mojo.py:18-22`) similarly lists "well-known types … raise a clear error" — also false. PR description's "Well-known types … still error" is the same incorrect claim.

#### Completeness Gaps (1)

5. **No guard exists for any cross-file Mojo-name collision (the registry/output-name split is unprotected).** The `registry` is keyed by unique full proto names, so registry overwrite is not the risk; the risk is two full names mapping to the same *Mojo* name within one output file, and a third case of an imported name equal to a local struct name. None of the three (cross-file/cross-file, imported/local, imported-name/enum-constant) is detected. The PR should at minimum detect-and-error rather than emit broken Mojo. (Severity of the underlying break is Critical, see #1/#2; this entry records the missing-guard completeness aspect.)

#### Inconsistencies (1)

6. **`gen_file`'s default-build guard is all-or-nothing on `registry` only, making the partial-args contract a footgun.** `gen_file(:967)` does `if registry is None: registry, file_of, map_entries = {}, {}, {}` — it keys solely off `registry`. A caller that passes `registry` but leaves `map_entries=None` (e.g. `gen_file(fd, reg, file_of)`) and has any map field hits `field.type_name in None` -> `TypeError: argument of type 'NoneType' is not a container or iterable` (reproduced directly). Not triggered by `main()` (always passes the trio) or current tests, so harmless today, but the signature invites it. Either build all three together or validate the trio.

#### Questions (1)

7. **`_module_path` can emit invalid Mojo module identifiers for some file names.** `_module_path` (`:253-256`) only strips `.proto` and replaces `/`->`.`. Verified outputs: `weird-dir/x.proto -> weird-dir.x` (hyphen — invalid Mojo identifier), `9num/y.proto -> 9num.y` (leading digit — invalid), `./rel.proto -> ..rel`, `/abs/path.proto -> .abs.path` (leading dot). protoc normally hands the import path as written (usually a clean relative path), so this may never bite in practice, but a hyphenated directory is common in real repos and would emit an uncompilable `from weird-dir.x import ...`. Question: should the generator sanitize or reject such paths? (The corresponding output file path uses slashes via `proto_name[:-len(".proto")] + ".mojo"` at `:1047`, which stays consistent with the dotted module — so the path/dots correspondence itself is fine.)

#### Minor (1)

8. **Stale comment references the deleted `_collect_messages`.** `codegen/protoc_gen_mojo.py:940`: `# synthetic; skipped like _collect_messages` — `_collect_messages` no longer exists (replaced by `_register_types` + `_file_structs`). Cosmetic.

### Verified Correct
- **Existing single-file output is byte-NFC**: all six pre-existing protos (example/telem/enums/rep/maps/oneof) generate byte-identical Mojo on `origin/main` vs the PR. Generation order, per-file struct-name collision check (`test_struct_name_collision` passes), enum-constant collision checks (`test_enum_constant_collision_two_enums` passes), map_entry skipping, and nested flattening order all unchanged.
- **Cross-file singular / repeated / map-value / optional / oneof-member all resolve through the resolver with exactly one import line each.** `place.mojo`: a single `from common import Geo`, `location: Geo`, `waypoints: List[Geo]`, `pins: Dict[String, Geo]`, `unit: Int32` (cross-file enum, no import). Adversarial `target.mojo` confirmed the optional (`opt: Optional[Geo]`), oneof (`c_alpha: Optional[Alpha]`, `c_beta: Optional[Beta]`), and map-value (`Dict[String, Alpha]`) paths all record the import.
- **Multiple types from one dep => one sorted import line** (`from a import Alpha, Geo`); **two deps => two separate lines** (`from a ...`, `from b ...`). Import ordering deterministic (regenerated twice, identical) and stable (sorted modules, sorted names; user imports after the `from protobuf.*` block).
- **Module-path mapping** `foo/bar.proto -> foo.bar`, `baz.proto -> baz`; the emitted file path (`foo/bar.mojo`) corresponds to the dotted module.
- **proto2 / group / required dep files do NOT choke `_register_types`** — it only records names and walks `nested_type`/`map_entry`, so a proto2 descriptor in `proto_file` contributes harmless registry entries and never raises (verified with a proto2 file containing `group` + `required`).
- **Only `file_to_generate` files are emitted** — dep files present solely as imports (common in the proto2 and unused-import cases) are not written. Verified.
- **Cross-file enum needs no import** and `_enum_constants` remains per-file (map_entry still skipped, `:940`).
- **Global `registry`/`map_entries` are read-only during generation** — `gen_file` builds a fresh per-call `module_imports` and `imports`; no `gen_file` call mutates the shared global registry or map_entries. Multi-target generation is safe.
- **Full suite + 16 interop both directions green** (Mojo-encoded `Place` parses in reference Python; reference encoding decodes in Mojo).
