from std.testing import assert_equal, TestSuite

from protobuf.fields import (
    read_bool,
    read_int64,
    read_string,
    skip_field,
    write_bool,
    write_fixed32,
    write_int64,
    write_string,
)
from protobuf.message import Message, decode, encode


@fieldwise_init
struct Person(Message):
    var id: Int64
    var name: String
    var active: Bool

    def __init__(out self):
        self.id = 0
        self.name = String("")
        self.active = False

    def encode_to(self, mut output: List[Byte]):
        write_int64(1, self.id, output)
        write_string(2, self.name, output)
        write_bool(3, self.active, output)

    def merge_field(
        mut self,
        field_number: Int,
        wire_type: Int,
        data: Span[Byte, _],
        mut pos: Int,
    ) raises:
        if field_number == 1:
            self.id = read_int64(data, pos)
        elif field_number == 2:
            self.name = read_string(data, pos)
        elif field_number == 3:
            self.active = read_bool(data, pos)
        else:
            skip_field(data, pos, wire_type)


def test_person_roundtrip() raises:
    var bytes = encode(Person(-5, "héllo", True))
    var got = decode[Person](Span(bytes))
    assert_equal(got.id, -5)
    assert_equal(got.name, "héllo")
    assert_equal(got.active, True)


def test_person_defaults_from_empty() raises:
    var empty = List[Byte]()
    var got = decode[Person](Span(empty))
    assert_equal(got.id, 0)
    assert_equal(got.name, "")
    assert_equal(got.active, False)


def test_person_partial_keeps_defaults() raises:
    # Only field 1 is present; the others keep their defaults.
    var buf = List[Byte]()
    write_int64(1, 7, buf)
    var got = decode[Person](Span(buf))
    assert_equal(got.id, 7)
    assert_equal(got.name, "")
    assert_equal(got.active, False)


def test_person_skips_unknown_field() raises:
    var buf = List[Byte]()
    write_int64(1, 42, buf)
    write_string(9, "from a newer schema", buf)  # field 9 unknown to Person
    write_bool(3, True, buf)
    var got = decode[Person](Span(buf))
    assert_equal(got.id, 42)
    assert_equal(got.active, True)
    assert_equal(got.name, "")


def test_person_skips_unknown_fixed_field() raises:
    # Unknown field with a fixed (I32) wire type exercises that skip branch.
    var buf = List[Byte]()
    write_fixed32(8, 0xDEADBEEF, buf)  # unknown I32 field
    write_int64(1, 5, buf)
    var got = decode[Person](Span(buf))
    assert_equal(got.id, 5)


def test_person_last_field_wins() raises:
    # A repeated scalar: the last occurrence overwrites (proto3 semantics).
    var buf = List[Byte]()
    write_int64(1, 10, buf)
    write_int64(1, 20, buf)
    var got = decode[Person](Span(buf))
    assert_equal(got.id, 20)


def test_person_reencode_is_stable() raises:
    var first = encode(Person(7, "ada", False))
    var second = encode(decode[Person](Span(first)))
    assert_equal(len(first), len(second))
    for i in range(len(first)):
        assert_equal(first[i], second[i])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
