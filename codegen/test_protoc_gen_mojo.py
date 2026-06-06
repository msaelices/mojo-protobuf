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


def test_repeated_unsupported():
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    _add_field(m, "xs", 1, FD.TYPE_INT64, label=FD.LABEL_REPEATED)
    _expect_error(fd, "repeated")


def test_enum_unsupported():
    fd = _file()
    m = fd.message_type.add()
    m.name = "M"
    f = _add_field(m, "e", 1, FD.TYPE_ENUM)
    f.type_name = ".t.E"
    _expect_error(fd, "enum")


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


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"PASS {t.__name__}")
    print(f"\n{len(tests)} tests passed")


if __name__ == "__main__":
    main()
