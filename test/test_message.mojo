from std.testing import assert_equal, TestSuite

from protobuf.fields import (
    read_bool,
    read_int64,
    read_string,
    skip_field,
    write_bool,
    write_bytes,
    write_fixed32,
    write_int64,
    write_string,
    write_uint64,
)
from protobuf.message import Message, decode, encode
from protobuf.size import (
    bool_field_size,
    int64_field_size,
    string_field_size,
)


@fieldwise_init
struct Person(Message):
    var id: Int64
    var name: String
    var active: Bool

    def __init__(out self):
        self.id = 0
        self.name = String("")
        self.active = False

    def encoded_size(self) -> Int:
        return (
            int64_field_size(1, self.id)
            + string_field_size(2, self.name)
            + bool_field_size(3)
        )

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


# `Contact` writes no serialization methods: it uses the reflection-derived
# defaults from the `Message` trait (field number = 1-based field position).
@fieldwise_init
struct Contact(Message):
    var id: Int64
    var email: String
    var verified: Bool
    var score: UInt64

    def __init__(out self):
        self.id = 0
        self.email = String("")
        self.verified = False
        self.score = 0


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


def test_encoded_size_matches_output() raises:
    var p = Person(-12345, "héllo world", True)
    assert_equal(len(encode(p)), p.encoded_size())


def test_encode_reserves_exactly() raises:
    # encode reserves encoded_size() up front, so the buffer never grows:
    # capacity == length proves no reallocation happened.
    var p = Person(-12345, "a longer name to force several appends", True)
    var bytes = encode(p)
    assert_equal(bytes.capacity, p.encoded_size())
    assert_equal(bytes.capacity, len(bytes))


def test_reflection_default_roundtrip() raises:
    # Contact has no serialization methods; everything comes from reflection.
    var c = Contact(7, "a@b.co", True, 99)
    var bytes = encode(c)
    assert_equal(len(bytes), c.encoded_size())
    var got = decode[Contact](Span(bytes))
    assert_equal(got.id, 7)
    assert_equal(got.email, "a@b.co")
    assert_equal(got.verified, True)
    assert_equal(got.score, 99)


def test_reflection_default_from_empty() raises:
    var got = decode[Contact](Span(List[Byte]()))
    assert_equal(got.id, 0)
    assert_equal(got.email, "")
    assert_equal(got.verified, False)
    assert_equal(got.score, 0)


def test_reflection_last_field_wins() raises:
    var buf = List[Byte]()
    write_int64(1, 10, buf)
    write_int64(1, 20, buf)  # field 1 again -> last wins
    var got = decode[Contact](Span(buf))
    assert_equal(got.id, 20)


def test_reflection_skips_unknown_fields() raises:
    var buf = List[Byte]()
    write_int64(1, 5, buf)
    write_string(9, "from a newer schema", buf)  # unknown LEN field
    write_fixed32(8, 123, buf)  # unknown I32 field
    write_uint64(4, 77, buf)  # known
    var got = decode[Contact](Span(buf))
    assert_equal(got.id, 5)
    assert_equal(got.score, 77)
    assert_equal(got.email, "")  # untouched


# Field order differs from `Contact` to prove numbering is positional, not
# type-based: here field 1 is the String and field 2 the Int64.
@fieldwise_init
struct Flipped(Message):
    var label: String
    var n: Int64

    def __init__(out self):
        self.label = String("")
        self.n = 0


def test_reflection_field_order_is_positional() raises:
    var got = decode[Flipped](Span(encode(Flipped("hi", 42))))
    assert_equal(got.label, "hi")
    assert_equal(got.n, 42)


# A plain machine-width `Int` field (not `Int64`) is supported too.
@fieldwise_init
struct Counter(Message):
    var value: Int

    def __init__(out self):
        self.value = 0


def test_reflection_int_field() raises:
    var got = decode[Counter](Span(encode(Counter(-123456))))
    assert_equal(got.value, -123456)


@fieldwise_init
struct Vec3(Message):
    var x: Float32
    var y: Float64

    def __init__(out self):
        self.x = 0.0
        self.y = 0.0


def test_reflection_float_fields() raises:
    var v = Vec3(3.14, -2.5)
    var bytes = encode(v)
    assert_equal(len(bytes), v.encoded_size())  # float arms agree on size
    var got = decode[Vec3](Span(bytes))
    assert_equal(got.x, Float32(3.14))
    assert_equal(got.y, Float64(-2.5))


@fieldwise_init
struct Nums32(Message):
    var a: Int32
    var b: UInt32

    def __init__(out self):
        self.a = 0
        self.b = 0


def test_reflection_int32_fields() raises:
    # Negatives sign-extend to a 10-byte varint; size must agree with the bytes.
    var vals: List[Int32] = [0, -1, Int32.MIN, Int32.MAX]
    for v in vals:
        var n = Nums32(v, 0)
        var bytes = encode(n)
        assert_equal(len(bytes), n.encoded_size())
        var got = decode[Nums32](Span(bytes))
        assert_equal(got.a, v)

    var u = decode[Nums32](Span(encode(Nums32(0, UInt32.MAX))))
    assert_equal(u.b, UInt32.MAX)


@fieldwise_init
struct Blob(Message):
    var id: Int64
    var data: List[Byte]

    def __init__(out self):
        self.id = 0
        self.data = List[Byte]()


def test_reflection_bytes_field() raises:
    var payload: List[Byte] = [Byte(0x00), Byte(0xFF), Byte(0x10)]  # binary
    var b = Blob(7, payload.copy())
    var bytes = encode(b)
    assert_equal(len(bytes), b.encoded_size())
    var got = decode[Blob](Span(bytes))
    assert_equal(got.id, 7)
    assert_equal(len(got.data), 3)
    assert_equal(got.data[0], Byte(0x00))
    assert_equal(got.data[1], Byte(0xFF))


def test_reflection_bytes_empty() raises:
    var got = decode[Blob](Span(encode(Blob())))
    assert_equal(len(got.data), 0)


def test_reflection_bytes_owns_its_data() raises:
    # The decoded field must own a copy, not a view into the input buffer.
    var payload: List[Byte] = [Byte(1), Byte(2), Byte(3)]
    var buf = encode(Blob(0, payload.copy()))
    var got = decode[Blob](Span(buf))
    for i in range(len(buf)):  # clobber the source bytes
        buf[i] = Byte(0)
    assert_equal(len(got.data), 3)
    assert_equal(got.data[0], Byte(1))
    assert_equal(got.data[2], Byte(3))


def test_reflection_bytes_large() raises:
    # A >= 128-byte payload exercises the 2-byte length prefix.
    var payload = List[Byte]()
    for i in range(200):
        payload.append(Byte(i & 0xFF))
    var b = Blob(0, payload.copy())
    var bytes = encode(b)
    assert_equal(len(bytes), b.encoded_size())
    var got = decode[Blob](Span(bytes))
    assert_equal(len(got.data), 200)
    assert_equal(got.data[199], Byte(199))


def test_reflection_bytes_last_wins() raises:
    # A repeated bytes field must drop the prior List (move-assign) and keep the
    # last value.
    var buf = List[Byte]()
    var first: List[Byte] = [Byte(1)]
    var second: List[Byte] = [Byte(2), Byte(3)]
    write_bytes(2, Span(first), buf)  # Blob.data is field 2
    write_bytes(2, Span(second), buf)
    var got = decode[Blob](Span(buf))
    assert_equal(len(got.data), 2)
    assert_equal(got.data[0], Byte(2))


@fieldwise_init
struct Inner(Message):
    var x: Int64
    var label: String

    def __init__(out self):
        self.x = 0
        self.label = String("")


# `Outer` has a nested `Inner` field; both use the reflection defaults.
@fieldwise_init
struct Outer(Message):
    var id: Int64
    var inner: Inner

    def __init__(out self):
        self.id = 0
        self.inner = Inner()


def test_reflection_nested_roundtrip() raises:
    var o = Outer(7, Inner(42, "hi"))
    var bytes = encode(o)
    assert_equal(len(bytes), o.encoded_size())  # nested size agrees
    var got = decode[Outer](Span(bytes))
    assert_equal(got.id, 7)
    assert_equal(got.inner.x, 42)
    assert_equal(got.inner.label, "hi")


def test_reflection_nested_defaults() raises:
    var got = decode[Outer](Span(List[Byte]()))
    assert_equal(got.id, 0)
    assert_equal(got.inner.x, 0)
    assert_equal(got.inner.label, "")


def test_reflection_nested_skips_unknown() raises:
    var buf = List[Byte]()
    write_string(9, "from a newer schema", buf)  # unknown to Outer
    var sub = encode(Inner(5, "deep"))
    write_bytes(2, Span(sub), buf)  # Outer.inner is field 2
    var got = decode[Outer](Span(buf))
    assert_equal(got.inner.x, 5)
    assert_equal(got.inner.label, "deep")
    assert_equal(got.id, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
