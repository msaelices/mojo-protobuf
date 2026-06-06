"""Round-trip test for protoc-gen-mojo output (regenerated into test/gen)."""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from protobuf.message import decode, encode

from example import Person, Point


def test_codegen_roundtrip() raises:
    var p = Person()
    p.id = 42
    p.name = String("Ada")
    p.active = True
    p.nickname = Optional(String("countess"))
    p.age = None
    p.avatar = [Byte(1), Byte(2), Byte(3)]
    p.location = Point(3, 4)

    var data = encode(p)
    assert_equal(len(data), p.encoded_size())  # generated size matches output
    var got = decode[Person](Span(data))
    assert_equal(got.id, 42)
    assert_equal(got.name, String("Ada"))
    assert_true(got.active)
    assert_true(got.nickname)
    assert_equal(got.nickname.value(), String("countess"))
    assert_false(got.age)  # absent optional stays None
    assert_equal(len(got.avatar), 3)
    assert_equal(got.avatar[2], Byte(3))
    assert_equal(got.location.x, 3)  # nested message round-trips
    assert_equal(got.location.y, 4)


def test_codegen_defaults_from_empty() raises:
    var got = decode[Person](Span(List[Byte]()))
    assert_equal(got.id, 0)
    assert_equal(got.name, String(""))
    assert_false(got.active)
    assert_false(got.nickname)
    assert_equal(got.location.x, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
