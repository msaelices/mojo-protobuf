#!/usr/bin/env python3
"""Unit tests for the protoc-gen-mojo generator.

Builds `FileDescriptorProto`s directly (no protoc needed) to check both the
happy path and that every unsupported feature fails loudly instead of emitting
silently-wrong code.
"""

from google.protobuf import descriptor_pb2

from protoc_gen_mojo import gen_file, GenError, _register_types

FD = descriptor_pb2.FieldDescriptorProto


def _file(package="t"):
    fd = descriptor_pb2.FileDescriptorProto()
    fd.name = "t.proto"
    fd.syntax = "proto3"
    fd.package = package
    return fd


def _add_field(msg, name, number, type_, label=FD.LABEL_OPTIONAL, **kw):
    f = msg.field.add()
    f.name = name
    f.number = number
    f.type = type_
    f.label = label
    for k, v in kw.items():
        setattr(f, k, v)
    return f


def _expect_error(fd, needle):
    try:
        gen_file(fd)
    except GenError as e:
        assert needle in str(e), f"expected '{needle}' in error, got: {e}"
        return
    raise AssertionError(f"expected GenError containing '{needle}'")


def test_happy_path():
    fd = _file()
    point = fd.message_type.add()
    point.name = "Point"
    _add_field(point, "x", 1, FD.TYPE_INT32)
    foo = fd.message_type.add()
    foo.name = "Foo"
    _add_field(foo, "id", 1, FD.TYPE_INT64)
    _add_field(foo, "name", 5, FD.TYPE_STRING)
    _add_field(foo, "nick", 7, FD.TYPE_STRING, proto3_optional=True)
    _add_field(foo, "blob", 8, FD.TYPE_BYTES)
    mf = _add_field(foo, "p", 9, FD.TYPE_MESSAGE)
    mf.type_name = ".t.Point"

    out = gen_file(fd)
    assert "struct Point(Message, Copyable):" in out
    assert "struct Foo(Message, Copyable):" in out
    assert "var nick: Optional[String]" in out
    assert "var blob: List[Byte]" in out
    assert "var p: Point" in out
    # non-sequential field numbers are used verbatim, not positions
    assert "write_string(5, self.name, output)" in out
    assert "elif field_number == 7:" in out
    # presence: absent optional emits nothing
    assert "if self.nick:" in out


def test_repeated_packed_scalar_supported():
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    _add_field(m, "xs", 1, FD.TYPE_INT64, label=FD.LABEL_REPEATED)
    _add_field(m, "ds", 2, FD.TYPE_DOUBLE, label=FD.LABEL_REPEATED)
    out = gen_file(fd)
    assert "var xs: List[Int64]" in out
    assert "var ds: List[Float64]" in out
    assert "if wire_type == WIRE_LEN:" in out  # accepts packed
    assert "self.xs.append(read_int64(" in out  # and non-packed


def test_repeated_nonpacked():
    # repeated string/bytes/message -> List[...] with one tag+value per element.
    fd = _file()
    tag = fd.message_type.add()
    tag.name = "Tag"
    _add_field(tag, "k", 1, FD.TYPE_STRING)
    m = fd.message_type.add()
    m.name = "M"
    _add_field(m, "names", 1, FD.TYPE_STRING, label=FD.LABEL_REPEATED)
    _add_field(m, "blobs", 2, FD.TYPE_BYTES, label=FD.LABEL_REPEATED)
    tf = _add_field(m, "tags", 3, FD.TYPE_MESSAGE, label=FD.LABEL_REPEATED)
    tf.type_name = ".t.Tag"
    out = gen_file(fd)
    assert "var names: List[String]" in out
    assert "var blobs: List[List[Byte]]" in out
    assert "var tags: List[Tag]" in out
    assert "self.names.append(read_string(data, pos))" in out  # one per occurrence
    assert "self.tags.append(decode[Tag](read_bytes(data, pos)))" in out
    assert "for ref _e in self.names:" in out  # encode loops per element


def _add_map_field(m, name, number, key_type, value_type, entry_name,
                   value_type_name=""):
    # Mirror protoc's lowering: a map<K,V> field is a repeated nested message
    # `<Name>Entry { K key = 1; V value = 2; }` with options.map_entry set.
    entry = m.nested_type.add()
    entry.name = entry_name
    entry.options.map_entry = True
    _add_field(entry, "key", 1, key_type)
    vf = _add_field(entry, "value", 2, value_type)
    if value_type_name:
        vf.type_name = value_type_name
    f = _add_field(m, name, number, FD.TYPE_MESSAGE, label=FD.LABEL_REPEATED)
    f.type_name = f".t.M.{entry_name}"
    return f


def test_map_supported():
    # map<K,V> -> Dict[K,V]; scalar and message values both work, each entry a
    # length-delimited key=1/value=2 submessage.
    fd = _file()
    attr = fd.message_type.add()
    attr.name = "Attr"
    _add_field(attr, "unit", 1, FD.TYPE_STRING)
    m = fd.message_type.add()
    m.name = "M"
    _add_map_field(m, "counts", 1, FD.TYPE_STRING, FD.TYPE_INT32, "CountsEntry")
    _add_map_field(m, "attrs", 2, FD.TYPE_INT32, FD.TYPE_MESSAGE, "AttrsEntry",
                   value_type_name=".t.Attr")
    out = gen_file(fd)
    assert "var counts: Dict[String, Int32]" in out
    assert "var attrs: Dict[Int32, Attr]" in out
    # entries are length-delimited submessages, decoded by an inner tag loop
    assert "for _e in self.counts.items():" in out
    assert "var _efn_counts, _ewt_counts = decode_tag(" in out
    # string key transfers (`^`); trivial Int32 value does not
    assert "self.counts[_k_counts^] = _v_counts" in out
    assert "_v_attrs = decode[Attr](read_bytes(" in out  # message value
    # the synthetic *Entry messages are not emitted as structs
    assert "struct CountsEntry" not in out
    assert "struct AttrsEntry" not in out


def test_map_invalid_key_type_unsupported():
    # proto forbids float/double/bytes/message/enum map keys; the generator must
    # reject them rather than emit an invalid Dict key type.
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    _add_map_field(m, "bad", 1, FD.TYPE_DOUBLE, FD.TYPE_INT32, "BadEntry")
    _expect_error(fd, "map key type")


def test_map_malformed_entry_unsupported():
    # A map_entry descriptor missing key=1/value=2 must raise GenError, not an
    # uncaught StopIteration (defensive: real protoc always emits both).
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    entry = m.nested_type.add()
    entry.name = "BadEntry"
    entry.options.map_entry = True
    _add_field(entry, "key", 1, FD.TYPE_STRING)  # value=2 deliberately omitted
    f = _add_field(m, "bad", 1, FD.TYPE_MESSAGE, label=FD.LABEL_REPEATED)
    f.type_name = ".t.M.BadEntry"
    _expect_error(fd, "malformed map entry")


def test_enum_supported():
    # proto3 enum -> Int32 field + comptime named-value constants.
    fd = _file()
    e = fd.enum_type.add()
    e.name = "Color"
    e.value.add(name="RED", number=0)
    e.value.add(name="GREEN", number=1)
    m = fd.message_type.add()
    m.name = "M"
    f = _add_field(m, "c", 1, FD.TYPE_ENUM)
    f.type_name = ".t.Color"
    g = _add_field(m, "cs", 2, FD.TYPE_ENUM, label=FD.LABEL_REPEATED)
    g.type_name = ".t.Color"
    out = gen_file(fd)
    assert "comptime Color_RED = Int32(0)" in out
    assert "comptime Color_GREEN = Int32(1)" in out
    assert "var c: Int32" in out  # singular enum -> Int32
    assert "var cs: List[Int32]" in out  # repeated enum -> packed List[Int32]
    assert "read_packed_signed[DType.int32]" in out


def test_enum_constant_collision_two_enums():
    # Enum `A_B` value `C` and nested enum `A.B` value `C` both flatten to the
    # constant `A_B_C`; must error, not emit a duplicate `comptime`.
    fd = _file()
    e1 = fd.enum_type.add()
    e1.name = "A_B"
    e1.value.add(name="C", number=0)
    m = fd.message_type.add()
    m.name = "A"
    en = m.enum_type.add()
    en.name = "B"
    en.value.add(name="C", number=0)
    _expect_error(fd, "two enums")


def test_enum_constant_collides_with_struct():
    # Constant `Foo_Bar_Baz` (enum `Foo_Bar` value `Baz`) collides with the
    # struct `Foo_Bar_Baz` (message Foo.Bar.Baz); must error.
    fd = _file()
    foo = fd.message_type.add()
    foo.name = "Foo"
    bar = foo.nested_type.add()
    bar.name = "Bar"
    bar.nested_type.add().name = "Baz"
    e = fd.enum_type.add()
    e.name = "Foo_Bar"
    e.value.add(name="Baz", number=0)
    _expect_error(fd, "struct name")


def test_oneof_supported():
    # A real oneof: each member is Optional[T]; decoding one clears the others.
    fd = _file()
    sub = fd.message_type.add()
    sub.name = "Sub"
    _add_field(sub, "n", 1, FD.TYPE_INT32)
    m = fd.message_type.add()
    m.name = "M"
    m.oneof_decl.add().name = "choice"
    f1 = _add_field(m, "text", 3, FD.TYPE_STRING)
    f1.oneof_index = 0
    f2 = _add_field(m, "count", 4, FD.TYPE_INT32)
    f2.oneof_index = 0
    f3 = _add_field(m, "sub", 5, FD.TYPE_MESSAGE)
    f3.oneof_index = 0
    f3.type_name = ".t.Sub"
    out = gen_file(fd)
    assert "var text: Optional[String]" in out
    assert "var count: Optional[Int32]" in out
    assert "var sub: Optional[Sub]" in out  # message member is optional too
    assert "if self.text:" in out  # encode only when present
    # decoding one member clears its siblings (last-one-wins)
    assert "self.text = Optional[String](read_string(data, pos))" in out
    block = out[out.index("field_number == 3:"):]
    block = block[:block.index("field_number == 4:")]
    assert "self.count = None" in block and "self.sub = None" in block


def test_oneof_proto3_optional_is_not_a_oneof():
    # A proto3 `optional` field rides a synthetic 1-member oneof; it must stay a
    # plain Optional with no sibling-clearing, not be treated as a real oneof.
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    m.oneof_decl.add().name = "_a"
    f = _add_field(m, "a", 1, FD.TYPE_INT64, proto3_optional=True)
    f.oneof_index = 0
    out = gen_file(fd)
    assert "var a: Optional[Int64]" in out
    # no sibling-clearing in decode (None appears only as the __init__ default)
    merge = out[out.index("def merge_field"):]
    assert "self.a = None" not in merge


def test_proto2_required_unsupported():
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    _add_field(m, "a", 1, FD.TYPE_INT64, label=FD.LABEL_REQUIRED)
    _expect_error(fd, "required")


def _registry(*fds):
    registry, file_of, map_entries = {}, {}, {}
    for fd in fds:
        scope = "." + fd.package if fd.package else ""
        _register_types(fd.message_type, scope, fd.package, fd.name, registry,
                        file_of, map_entries)
    return registry, file_of, map_entries


def test_cross_file_message_ref_supported():
    # A field whose type is defined in an imported .proto resolves and emits a
    # `from <module> import <Struct>` line.
    common = descriptor_pb2.FileDescriptorProto()
    common.name, common.syntax, common.package = "common.proto", "proto3", "co"
    geo = common.message_type.add()
    geo.name = "Geo"
    _add_field(geo, "lat", 1, FD.TYPE_DOUBLE)
    place = descriptor_pb2.FileDescriptorProto()
    place.name, place.syntax, place.package = "sub/place.proto", "proto3", "pl"
    m = place.message_type.add()
    m.name = "Place"
    f = _add_field(m, "loc", 1, FD.TYPE_MESSAGE)
    f.type_name = ".co.Geo"
    rf = _add_field(m, "near", 2, FD.TYPE_MESSAGE, label=FD.LABEL_REPEATED)
    rf.type_name = ".co.Geo"
    out = gen_file(place, *_registry(common, place))
    assert "from common import Geo" in out  # module path from the source file
    assert "var loc: Geo" in out
    assert "var near: List[Geo]" in out


def test_cross_file_module_path_uses_slashes_as_dots():
    # `foo/bar.proto` -> module `foo.bar`.
    dep = descriptor_pb2.FileDescriptorProto()
    dep.name, dep.syntax, dep.package = "foo/bar.proto", "proto3", "fb"
    t = dep.message_type.add()
    t.name = "T"
    _add_field(t, "x", 1, FD.TYPE_INT32)
    main = _file()
    m = main.message_type.add()
    m.name = "M"
    f = _add_field(m, "t", 1, FD.TYPE_MESSAGE)
    f.type_name = ".fb.T"
    out = gen_file(main, *_registry(dep, main))
    assert "from foo.bar import T" in out


def test_well_known_type_unsupported():
    # protoc passes google.protobuf descriptors in the request, so the registry
    # would resolve them and emit a dangling import; reject with a clear error
    # until a builtin module backs them.
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    f = _add_field(m, "at", 1, FD.TYPE_MESSAGE)
    f.type_name = ".google.protobuf.Timestamp"
    _expect_error(fd, "well-known type")


def test_undefined_type_ref_errors():
    # A message field whose type is not among the generation targets errors
    # clearly (you must pass the defining .proto to protoc too).
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    f = _add_field(m, "other", 1, FD.TYPE_MESSAGE)
    f.type_name = ".nope.Thing"
    _expect_error(fd, "not among the generation targets")


def test_cross_file_name_collision_two_deps():
    # Two dep files whose structs flatten to the same Mojo name, both used by
    # one target, would emit `from a import Geo` + `from b import Geo` -> a Mojo
    # ambiguity. Detect and error instead of emitting broken code.
    a = descriptor_pb2.FileDescriptorProto()
    a.name, a.syntax, a.package = "a.proto", "proto3", "a"
    a.message_type.add().name = "Geo"
    b = descriptor_pb2.FileDescriptorProto()
    b.name, b.syntax, b.package = "b.proto", "proto3", "b"
    b.message_type.add().name = "Geo"
    t = descriptor_pb2.FileDescriptorProto()
    t.name, t.syntax, t.package = "t.proto", "proto3", "t"
    m = t.message_type.add()
    m.name = "M"
    _add_field(m, "ga", 1, FD.TYPE_MESSAGE).type_name = ".a.Geo"
    _add_field(m, "gb", 2, FD.TYPE_MESSAGE).type_name = ".b.Geo"
    try:
        gen_file(t, *_registry(a, b, t))
    except GenError as e:
        assert "imported from both" in str(e), e
        return
    raise AssertionError("expected a cross-file name-collision GenError")


def test_cross_file_name_collision_with_local():
    # An imported type whose Mojo name equals a locally generated struct name.
    dep = descriptor_pb2.FileDescriptorProto()
    dep.name, dep.syntax, dep.package = "dep.proto", "proto3", "d"
    dep.message_type.add().name = "Geo"
    t = descriptor_pb2.FileDescriptorProto()
    t.name, t.syntax, t.package = "t.proto", "proto3", "t"
    t.message_type.add().name = "Geo"  # local Geo
    m = t.message_type.add()
    m.name = "M"
    _add_field(m, "g", 1, FD.TYPE_MESSAGE).type_name = ".d.Geo"
    try:
        gen_file(t, *_registry(dep, t))
    except GenError as e:
        assert "collides with a struct defined in this file" in str(e), e
        return
    raise AssertionError("expected a local/import name-collision GenError")


def test_proto2_unsupported():
    # protoc leaves `syntax` empty for proto2; an empty syntax must be rejected,
    # otherwise a proto2 `optional` scalar would silently lose presence.
    fd = descriptor_pb2.FileDescriptorProto()
    fd.name = "t.proto"  # no syntax set -> proto2
    fd.package = "t"
    m = fd.message_type.add()
    m.name = "M"
    _add_field(m, "a", 1, FD.TYPE_INT32)
    _expect_error(fd, "proto3")


def test_struct_name_collision():
    # A top-level `Outer_Inner` and a nested `Outer.Inner` both flatten to the
    # same Mojo struct name; that must error, not emit a duplicate struct.
    fd = _file()
    fd.message_type.add().name = "Outer_Inner"
    outer = fd.message_type.add()
    outer.name = "Outer"
    outer.nested_type.add().name = "Inner"
    _expect_error(fd, "collides")


def test_fields_emitted_in_number_order():
    # Declaration order is intentionally non-monotonic; the wire methods must
    # emit in ascending field number (canonical).
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    _add_field(m, "b", 5, FD.TYPE_INT64)
    _add_field(m, "a", 2, FD.TYPE_INT64)
    out = gen_file(fd)
    enc = out[out.index("def encode_to"):out.index("def merge_field")]
    assert enc.index("write_int64(2,") < enc.index("write_int64(5,"), enc


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"PASS {t.__name__}")
    print(f"\n{len(tests)} tests passed")


if __name__ == "__main__":
    main()
