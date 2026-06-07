"""Round-trip test for protoc-gen-mojo output (regenerated into test/gen)."""

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from protobuf.message import decode, encode

from enums import Color_BLUE, Color_GREEN, Color_RED, Thing, Thing_Kind_PRIMARY
from example import AllTypes, Person, Point
from rep import Record, Tag
from telem import PackedAll, Telemetry


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


def test_codegen_all_scalar_types() raises:
    # Covers the scalar arms the Person fixture does not: double, float,
    # uint32/64, sint32/64 (incl. negatives), and optional uint32/double/bytes.
    var a = AllTypes()
    a.d = -2.5
    a.f = 1.5
    a.i32 = -7
    a.i64 = -1234567890123
    a.u32 = UInt32.MAX
    a.u64 = UInt64(9876543210)
    a.s32 = -42  # ZigZag
    a.s64 = -123456789
    a.b = True
    a.s = String("héllo 🌍")  # multi-byte UTF-8
    a.by = [Byte(0), Byte(255)]
    a.ou32 = Optional(UInt32(5))
    a.od = None
    a.ob = Optional(List[Byte]())  # present but empty

    var data = encode(a)
    assert_equal(len(data), a.encoded_size())  # generated size matches output
    var got = decode[AllTypes](Span(data))
    assert_equal(got.d, Float64(-2.5))
    assert_equal(got.f, Float32(1.5))
    assert_equal(got.i32, Int32(-7))
    assert_equal(got.i64, Int64(-1234567890123))
    assert_equal(got.u32, UInt32.MAX)
    assert_equal(got.u64, UInt64(9876543210))
    assert_equal(got.s32, Int32(-42))
    assert_equal(got.s64, Int64(-123456789))
    assert_true(got.b)
    assert_equal(got.s, String("héllo 🌍"))
    assert_equal(len(got.by), 2)
    assert_equal(got.by[1], Byte(255))
    assert_true(got.ou32)
    assert_equal(got.ou32.value(), UInt32(5))
    assert_false(got.od)  # absent stays None
    assert_true(got.ob)  # present-but-empty is distinct from absent
    assert_equal(len(got.ob.value()), 0)


def test_codegen_packed_repeated() raises:
    # Packed repeated varint (samples) + packed repeated fixed64 (temps) +
    # an interleaved scalar, all round-tripping through the generated struct.
    var t = Telemetry()
    t.samples = [Int64(1), Int64(-2), Int64(300), Int64(-400000)]
    t.temps = [Float64(1.5), Float64(-2.5), Float64(3.14159)]
    t.id = 99
    var data = encode(t)
    assert_equal(len(data), t.encoded_size())
    var got = decode[Telemetry](Span(data))
    assert_equal(len(got.samples), 4)
    assert_equal(got.samples[0], 1)
    assert_equal(got.samples[1], -2)
    assert_equal(got.samples[3], -400000)
    assert_equal(len(got.temps), 3)
    assert_equal(got.temps[2], Float64(3.14159))
    assert_equal(got.id, 99)


def test_codegen_packed_repeated_empty() raises:
    # Empty repeated fields emit nothing and decode back to empty lists.
    var t = Telemetry()
    t.id = 7
    var data = encode(t)
    assert_equal(len(data), t.encoded_size())
    var got = decode[Telemetry](Span(data))
    assert_equal(len(got.samples), 0)
    assert_equal(len(got.temps), 0)
    assert_equal(got.id, 7)


def test_codegen_packed_all_types() raises:
    # The packed scalar types not covered by Telemetry (int64/double): int32,
    # uint32, sint32, sint64, bool, float, uint64, with negatives and extremes.
    var p = PackedAll()
    p.i32 = [Int32(-7), Int32(0), Int32.MAX]
    p.u32 = [UInt32(0), UInt32.MAX]
    p.s32 = [Int32(-42), Int32(42), Int32.MIN]  # ZigZag
    p.s64 = [Int64(-123456789), Int64(123456789)]
    p.flags = [True, False, True]
    p.f32 = [Float32(1.5), Float32(-2.5)]
    p.u64 = [UInt64(9876543210)]
    var data = encode(p)
    assert_equal(len(data), p.encoded_size())
    var got = decode[PackedAll](Span(data))
    assert_equal(len(got.i32), 3)
    assert_equal(got.i32[0], Int32(-7))
    assert_equal(got.i32[2], Int32.MAX)
    assert_equal(got.u32[1], UInt32.MAX)
    assert_equal(len(got.s32), 3)
    assert_equal(got.s32[0], Int32(-42))
    assert_equal(got.s32[2], Int32.MIN)
    assert_equal(got.s64[0], Int64(-123456789))
    assert_equal(len(got.flags), 3)
    assert_true(got.flags[0])
    assert_false(got.flags[1])
    assert_equal(got.f32[1], Float32(-2.5))
    assert_equal(got.u64[0], UInt64(9876543210))


def test_codegen_enums() raises:
    # Enum -> Int32 + comptime named constants: singular, packed repeated, and
    # optional enum fields, plus a nested enum.
    var t = Thing()
    t.color = Color_GREEN
    t.palette = [Color_RED, Color_BLUE, Color_GREEN]  # packed repeated enum
    t.accent = Optional(Color_BLUE)
    t.kind = Thing_Kind_PRIMARY
    var data = encode(t)
    assert_equal(len(data), t.encoded_size())
    var got = decode[Thing](Span(data))
    assert_equal(got.color, Color_GREEN)
    assert_equal(len(got.palette), 3)
    assert_equal(got.palette[1], Color_BLUE)
    assert_true(got.accent)
    assert_equal(got.accent.value(), Color_BLUE)
    assert_equal(got.kind, Thing_Kind_PRIMARY)


def test_codegen_repeated_nonpacked() raises:
    # Non-packed repeated: List[String], List[List[Byte]], List[message] — one
    # tag+value per element. Messages are Copyable, so list literals work.
    var r = Record()
    r.names = [String("alice"), String("bob")]
    r.blobs = [List[Byte]([Byte(1), Byte(2)]), List[Byte]([Byte(255)])]
    r.tags = [Tag("env", "prod"), Tag("v", "2")]
    var data = encode(r)
    assert_equal(len(data), r.encoded_size())
    var got = decode[Record](Span(data))
    assert_equal(len(got.names), 2)
    assert_equal(got.names[1], String("bob"))
    assert_equal(len(got.blobs), 2)
    assert_equal(got.blobs[0][1], Byte(2))
    assert_equal(got.blobs[1][0], Byte(255))
    assert_equal(len(got.tags), 2)
    assert_equal(got.tags[0].key, String("env"))
    assert_equal(got.tags[1].value, String("2"))

    var empty = decode[Record](Span(encode(Record())))
    assert_equal(len(empty.names), 0)
    assert_equal(len(empty.tags), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
