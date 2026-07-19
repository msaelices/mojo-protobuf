from std.testing import assert_equal, assert_false, assert_true, TestSuite

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
    assert_equal(bytes.capacity(), p.encoded_size())
    assert_equal(bytes.capacity(), len(bytes))


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


@fieldwise_init
struct L3(Message):
    var v: Int64

    def __init__(out self):
        self.v = 0


@fieldwise_init
struct L2(Message):
    var c: L3

    def __init__(out self):
        self.c = L3()


@fieldwise_init
struct L1(Message):
    var b: L2

    def __init__(out self):
        self.b = L2()


def test_reflection_nested_three_deep() raises:
    var got = decode[L1](Span(encode(L1(L2(L3(99))))))
    assert_equal(got.b.c.v, 99)


# A scalar field AFTER the nested one: the nested decode must consume exactly
# its sub-span and not eat `tail`.
@fieldwise_init
struct Wrap(Message):
    var inner: Inner
    var tail: Int64

    def __init__(out self):
        self.inner = Inner()
        self.tail = 0


def test_reflection_nested_then_scalar() raises:
    var got = decode[Wrap](Span(encode(Wrap(Inner(5, "x"), 77))))
    assert_equal(got.inner.x, 5)
    assert_equal(got.inner.label, "x")
    assert_equal(got.tail, 77)


def test_reflection_nested_owns_strings() raises:
    # A nested message's String must be copied, not a view into the input.
    var buf = encode(Outer(0, Inner(0, "deep")))
    var got = decode[Outer](Span(buf))
    for i in range(len(buf)):
        buf[i] = Byte(0)
    assert_equal(got.inner.label, "deep")


@fieldwise_init
struct OptScalars(Message):
    var id: Int64
    var nick: Optional[String]
    var age: Optional[Int64]
    var score: Optional[Float64]
    var flag: Optional[Bool]

    def __init__(out self):
        self.id = 0
        self.nick = None
        self.age = None
        self.score = None
        self.flag = None


def test_optional_all_present() raises:
    var m = OptScalars(
        7,
        Optional(String("ada")),
        Optional(Int64(42)),
        Optional(Float64(-2.5)),
        Optional(Bool(True)),
    )
    var bytes = encode(m)
    assert_equal(len(bytes), m.encoded_size())
    var got = decode[OptScalars](Span(bytes))
    assert_equal(got.id, 7)
    assert_equal(got.nick.value(), String("ada"))
    assert_equal(got.age.value(), 42)
    assert_equal(got.score.value(), Float64(-2.5))
    assert_equal(got.flag.value(), True)


def test_optional_all_absent_emit_nothing() raises:
    # Absent optionals must contribute no bytes: only the plain `id` is emitted.
    var m = OptScalars()
    m.id = 9
    var bytes = encode(m)
    assert_equal(len(bytes), m.encoded_size())
    assert_equal(len(bytes), int64_field_size(1, 9))  # nothing but field 1
    var got = decode[OptScalars](Span(bytes))
    assert_equal(got.id, 9)
    assert_false(got.nick)
    assert_false(got.age)
    assert_false(got.score)
    assert_false(got.flag)


def test_optional_partial() raises:
    var m = OptScalars()
    m.age = Optional(Int64(99))
    var got = decode[OptScalars](Span(encode(m)))
    assert_false(got.nick)
    assert_true(got.age)
    assert_equal(got.age.value(), 99)
    assert_false(got.flag)


def test_optional_present_zero_is_written() raises:
    # Presence is independent of value: a present-but-zero scalar is still
    # written and decodes back as present, distinct from absent.
    var m = OptScalars()
    m.age = Optional(Int64(0))
    m.flag = Optional(Bool(False))
    assert_true(len(encode(m)) > int64_field_size(1, 0))  # zeros took bytes
    var got = decode[OptScalars](Span(encode(m)))
    assert_true(got.age)
    assert_equal(got.age.value(), 0)
    assert_true(got.flag)
    assert_equal(got.flag.value(), False)


def test_optional_defaults_from_empty() raises:
    # A message absent from the wire keeps every optional as None.
    var got = decode[OptScalars](Span(List[Byte]()))
    assert_equal(got.id, 0)
    assert_false(got.nick)
    assert_false(got.age)


@fieldwise_init
struct OptWide(Message):
    var i: Optional[Int]
    var i32: Optional[Int32]
    var u32: Optional[UInt32]
    var u64: Optional[UInt64]
    var f32: Optional[Float32]
    var data: Optional[List[Byte]]

    def __init__(out self):
        self.i = None
        self.i32 = None
        self.u32 = None
        self.u64 = None
        self.f32 = None
        self.data = None


def test_optional_wide_types() raises:
    var payload: List[Byte] = [Byte(0x00), Byte(0xFF), Byte(0x10)]
    var m = OptWide(
        Optional(Int(-5)),
        Optional(Int32(-1)),
        Optional(UInt32.MAX),
        Optional(UInt64(123456789)),
        Optional(Float32(1.5)),
        Optional(payload.copy()),
    )
    var bytes = encode(m)
    assert_equal(len(bytes), m.encoded_size())
    var got = decode[OptWide](Span(bytes))
    assert_equal(got.i.value(), -5)
    assert_equal(got.i32.value(), Int32(-1))
    assert_equal(got.u32.value(), UInt32.MAX)
    assert_equal(got.u64.value(), UInt64(123456789))
    assert_equal(got.f32.value(), Float32(1.5))
    assert_equal(len(got.data.value()), 3)
    assert_equal(got.data.value()[1], Byte(0xFF))


def test_optional_bytes_owns_its_data() raises:
    # The decoded Optional[bytes] must copy, not view into the input buffer.
    var m = OptWide()
    m.data = Optional(List[Byte]([Byte(1), Byte(2), Byte(3)]))
    var buf = encode(m)
    var got = decode[OptWide](Span(buf))
    for i in range(len(buf)):
        buf[i] = Byte(0)
    assert_true(got.data)
    assert_equal(got.data.value()[0], Byte(1))
    assert_equal(got.data.value()[2], Byte(3))


def test_optional_skips_unknown_field() raises:
    # A present optional followed by an unknown field still decodes (forward
    # compatibility): the unknown field 6 is skipped.
    var m = OptScalars()
    m.age = Optional(Int64(7))
    var buf = encode(m)
    write_int64(6, 999, buf)  # field the schema doesn't know
    var got = decode[OptScalars](Span(buf))
    assert_equal(got.age.value(), 7)


def test_optional_string_unicode() raises:
    # A present Optional[String] must round-trip multi-byte UTF-8 unchanged.
    var m = OptScalars()
    m.nick = Optional(String("héllo 🌍 こんにちは"))
    var got = decode[OptScalars](Span(encode(m)))
    assert_true(got.nick)
    assert_equal(got.nick.value(), String("héllo 🌍 こんにちは"))


def test_optional_present_but_empty() raises:
    # A present-but-empty string/bytes is distinct from absent: it emits a tag
    # plus a zero-length prefix and decodes back as present-and-empty.
    var m = OptScalars()
    m.nick = Optional(String(""))
    var got = decode[OptScalars](Span(encode(m)))
    assert_true(got.nick)
    assert_equal(got.nick.value(), String(""))

    var w = OptWide()
    w.data = Optional(List[Byte]())
    var gw = decode[OptWide](Span(encode(w)))
    assert_true(gw.data)
    assert_equal(len(gw.data.value()), 0)


def test_optional_last_wins() raises:
    # A repeated tag for an optional field keeps the last value: merge_field
    # overwrites the whole Optional each time.
    var buf = List[Byte]()
    write_int64(3, 1, buf)  # OptScalars.age, first occurrence
    write_int64(3, 2, buf)  # same field again
    var got = decode[OptScalars](Span(buf))
    assert_true(got.age)
    assert_equal(got.age.value(), 2)


# An `Optional` nested-message field: explicit presence for messages, handled
# by the reflection default since the inner type is peeled generically.
@fieldwise_init
struct OptNested(Message):
    var id: Int64
    var inner: Optional[Inner]

    def __init__(out self):
        self.id = 0
        self.inner = None


def test_optional_message_roundtrip() raises:
    var m = OptNested(3, Optional(Inner(42, "hi")))
    var bytes = encode(m)
    assert_equal(len(bytes), m.encoded_size())
    var got = decode[OptNested](Span(bytes))
    assert_equal(got.id, 3)
    assert_true(got.inner)
    assert_equal(got.inner.value().x, 42)
    assert_equal(got.inner.value().label, "hi")


def test_optional_message_absent_emits_nothing() raises:
    var m = OptNested()
    m.id = 9
    var bytes = encode(m)
    assert_equal(len(bytes), m.encoded_size())
    assert_equal(len(bytes), int64_field_size(1, 9))  # nothing but field 1
    var got = decode[OptNested](Span(bytes))
    assert_false(got.inner)


def test_optional_message_present_but_default_is_written() raises:
    # Presence is independent of the inner value: a present all-default nested
    # message still emits its (empty) length-delimited field, so it decodes
    # back present — distinguishable from an absent one.
    var m = OptNested(0, Optional(Inner()))
    var bytes = encode(m)
    assert_equal(len(bytes), m.encoded_size())
    var got = decode[OptNested](Span(bytes))
    assert_true(got.inner)
    assert_equal(got.inner.value().x, 0)
    assert_equal(got.inner.value().label, "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
