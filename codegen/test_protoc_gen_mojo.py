#!/usr/bin/env python3
"""Unit tests for the protoc-gen-mojo generator.

Builds `FileDescriptorProto`s directly (no protoc needed) to check both the
happy path and that every unsupported feature fails loudly instead of emitting
silently-wrong code.
"""

from google.protobuf import descriptor_pb2

from protoc_gen_mojo import gen_file, GenError

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
    assert "struct Point(Message):" in out
    assert "struct Foo(Message):" in out
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


def test_repeated_string_unsupported():
    # Non-packed repeated (string/bytes/message) is a follow-up.
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    _add_field(m, "xs", 1, FD.TYPE_STRING, label=FD.LABEL_REPEATED)
    _expect_error(fd, "repeated")


def test_map_unsupported():
    # A map<K,V> lowers to a repeated nested message with options.map_entry; it
    # must error with a map-specific message, not the generic repeated one.
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    entry = m.nested_type.add()
    entry.name = "CountsEntry"
    entry.options.map_entry = True
    _add_field(entry, "key", 1, FD.TYPE_STRING)
    _add_field(entry, "value", 2, FD.TYPE_INT32)
    f = _add_field(m, "counts", 1, FD.TYPE_MESSAGE, label=FD.LABEL_REPEATED)
    f.type_name = ".t.M.CountsEntry"
    _expect_error(fd, "map")


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


def test_oneof_unsupported():
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    m.oneof_decl.add().name = "choice"
    f = _add_field(m, "a", 1, FD.TYPE_INT64)
    f.oneof_index = 0  # real oneof (no proto3_optional)
    _expect_error(fd, "oneof")


def test_proto2_required_unsupported():
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    _add_field(m, "a", 1, FD.TYPE_INT64, label=FD.LABEL_REQUIRED)
    _expect_error(fd, "required")


def test_cross_file_message_ref_unsupported():
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    f = _add_field(m, "other", 1, FD.TYPE_MESSAGE)
    f.type_name = ".other.Thing"  # not defined in this file
    _expect_error(fd, "cross-file")


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
