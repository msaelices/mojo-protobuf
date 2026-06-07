"""Round-trip test for protoc-gen-mojo output (regenerated into test/gen)."""

from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)

from protobuf.message import decode, encode

from common import Geo, Unit_FEET, Unit_METERS
from enums import Color_BLUE, Color_GREEN, Color_RED, Thing, Thing_Kind_PRIMARY
from example import AllTypes, Person, Point
from place import Place
from maps import Attr, Maps, Status_STATUS_ERR, Status_STATUS_OK
from oneof import HasOpt, Inner, Kind_KIND_B, M
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


def test_codegen_maps() raises:
    # map<K, V> -> Dict[K, V] across every value kind: scalar, string, message,
    # bytes, enum; with both string and integral keys and an interleaved
    # singular field. Each entry is a length-delimited key=1/value=2 submessage.
    var m = Maps()
    m.counts["a"] = Int32(0)  # default value still serialized for map entries
    m.counts["b"] = Int32(5)
    m.labels["k"] = String("")
    m.labels["x"] = String("héllo 🌍")  # multi-byte UTF-8 value
    m.attrs[7] = Attr("kg", 10)
    m.attrs[3] = Attr("", 0)  # default-valued message entry
    m.blobs["bin"] = [Byte(1), Byte(255)]
    m.states["svc"] = Status_STATUS_OK
    m.states["db"] = Status_STATUS_ERR
    m.id = 99

    var data = encode(m)
    assert_equal(len(data), m.encoded_size())  # generated size matches output
    var got = decode[Maps](Span(data))
    assert_equal(len(got.counts), 2)
    assert_equal(got.counts["a"], Int32(0))
    assert_equal(got.counts["b"], Int32(5))
    assert_equal(got.labels["k"], String(""))
    assert_equal(got.labels["x"], String("héllo 🌍"))
    assert_equal(len(got.attrs), 2)
    assert_equal(got.attrs[7].unit, String("kg"))
    assert_equal(got.attrs[7].scale, Int64(10))
    assert_equal(got.attrs[3].scale, Int64(0))
    assert_equal(len(got.blobs["bin"]), 2)
    assert_equal(got.blobs["bin"][1], Byte(255))
    assert_equal(got.states["svc"], Status_STATUS_OK)
    assert_equal(got.states["db"], Status_STATUS_ERR)
    assert_equal(got.id, 99)

    var empty = decode[Maps](Span(encode(Maps())))
    assert_equal(len(empty.counts), 0)
    assert_equal(len(empty.attrs), 0)


def test_codegen_oneof() raises:
    # Each oneof member is Optional[T]; at most one is set; decoding a member
    # clears its siblings (proto3 last-one-wins). Two independent oneofs.
    var m = M()
    m.id = 1
    m.sub = Optional(Inner(9))  # message member of `payload`
    m.err = Optional(String("boom"))  # member of the second oneof `status`
    m.trailer = String("end")
    var data = encode(m)
    assert_equal(len(data), m.encoded_size())
    var got = decode[M](Span(data))
    assert_true(got.sub)
    assert_equal(got.sub.value().n, Int32(9))
    assert_false(got.text)  # other payload members absent
    assert_false(got.count)
    assert_true(got.err)
    assert_equal(got.err.value(), String("boom"))
    assert_false(got.ok)
    assert_equal(got.id, 1)
    assert_equal(got.trailer, String("end"))

    # A scalar member set to its default value is still present (oneof presence
    # is tracked independently of value), and clears siblings on decode.
    var z = M()
    z.count = Optional(Int32(0))
    z.kind = Optional(Kind_KIND_B)  # setting a member does not auto-clear count
    var gz = decode[M](Span(encode(z)))
    # on the wire, kind (7) comes after count (4): last-wins -> kind present
    assert_true(gz.kind)
    assert_equal(gz.kind.value(), Kind_KIND_B)
    assert_false(gz.count)


def test_codegen_optional_message() raises:
    # proto3 `optional Message` -> Optional[Inner]: present-but-empty is distinct
    # from absent, and an absent optional message emits nothing.
    var present = HasOpt()
    present.maybe = Optional(Inner(0))  # present, default-valued
    var gp = decode[HasOpt](Span(encode(present)))
    assert_true(gp.maybe)
    assert_equal(gp.maybe.value().n, Int32(0))

    var absent = HasOpt()
    assert_equal(len(encode(absent)), 0)  # absent emits nothing
    var ga = decode[HasOpt](Span(encode(absent)))
    assert_false(ga.maybe)


def test_codegen_crossfile() raises:
    # Cross-file references: `place.proto` imports `common.proto` and uses
    # common.Geo as a singular field, a repeated field, and a map value, plus a
    # cross-file enum (-> Int32). Geo is imported `from common import Geo`.
    var p = Place()
    p.name = String("park")
    p.location = Geo(40.7, -74.0)
    p.waypoints = [Geo(1.0, 2.0), Geo(3.0, 4.0)]
    p.pins["entrance"] = Geo(5.5, 6.6)
    p.unit = Unit_METERS
    var data = encode(p)
    assert_equal(len(data), p.encoded_size())
    var got = decode[Place](Span(data))
    assert_equal(got.name, String("park"))
    assert_equal(got.location.lat, Float64(40.7))
    assert_equal(got.location.lng, Float64(-74.0))
    assert_equal(len(got.waypoints), 2)
    assert_equal(got.waypoints[1].lng, Float64(4.0))
    assert_equal(got.pins["entrance"].lat, Float64(5.5))
    assert_equal(got.unit, Unit_METERS)
    assert_true(Unit_FEET != Unit_METERS)


def test_codegen_default_omission() raises:
    # proto3 omits plain singular fields that hold their default value. A Person
    # with only `id` set encodes to just that one field (tag 1 + varint 42); the
    # default string/bool/bytes and the all-default nested Point are omitted.
    var p = Person()
    p.id = 42
    var data = encode(p)
    assert_equal(len(data), 2)  # 0x08 0x2a only
    assert_equal(data[0], Byte(8))
    assert_equal(data[1], Byte(42))
    assert_equal(len(data), p.encoded_size())
    var got = decode[Person](Span(data))
    assert_equal(got.id, 42)
    assert_equal(got.name, String(""))  # omitted -> default on decode
    assert_false(got.active)
    assert_equal(len(got.avatar), 0)
    assert_equal(got.location.x, 0)  # all-default nested message omitted

    # A default scalar inside an otherwise-set message is still omitted: Point
    # with x=0, y=5 emits only y.
    var pt = Point(0, 5)
    var pd = encode(pt)
    assert_equal(len(pd), pt.encoded_size())
    assert_equal(pd[0], Byte(16))  # field 2 (y), tag 0x10 — x (field 1) omitted
    assert_equal(decode[Point](Span(pd)).y, 5)


def test_codegen_negative_zero_preserved() raises:
    # proto3 detects the float/double default by bit pattern, not numeric
    # equality: -0.0 is non-default and must be written (and round-trip to -0.0,
    # not +0.0), while +0.0 is the default and is omitted.
    var a = AllTypes()
    a.d = Float64(-0.0)
    a.f = Float32(-0.0)
    var data = encode(a)
    assert_equal(len(data), a.encoded_size())
    assert_true(len(data) > 0)  # -0.0 is written, not omitted
    var got = decode[AllTypes](Span(data))
    assert_equal(got.d.to_bits(), Float64(-0.0).to_bits())  # sign preserved
    assert_equal(got.f.to_bits(), Float32(-0.0).to_bits())

    var z = AllTypes()
    z.d = Float64(0.0)  # +0.0 is the default
    assert_equal(len(encode(z)), 0)  # omitted


def test_codegen_repeated_message_malformed_raises() raises:
    # A repeated-message element whose nested sub-message is corrupt must raise
    # out of the per-element decode[Tag], not silently truncate. Here field 3
    # (tags) carries a 4-byte Tag body `[10, 5, 1, 2]`: an inner string (field
    # 1, tag 10) claims length 5 but only 2 bytes follow, so read_string runs
    # off the sub-span.
    var data: List[Byte] = [Byte(26), Byte(4), Byte(10), Byte(5), Byte(1),
                            Byte(2)]
    with assert_raises():
        _ = decode[Record](Span(data))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
