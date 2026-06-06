"""Benchmarks for whole-message encode/decode (`protobuf.message`).

Measures the reflection-derived `Message` path end to end: `encode` (which sizes
with `encoded_size` then appends via `encode_to`) and `decode` (the tag-dispatch
loop). A small all-scalar message isolates per-field overhead; a larger message
with a long string, a bytes blob, and a nested message stresses the copy paths.
Run with `pixi run bench-message`.
"""

from std.benchmark import Bench, BenchConfig, Bencher, BenchId, keep

from protobuf.fields import read_bytes, read_packed_signed, skip_field
from protobuf.message import Message, decode, encode
from protobuf.size import tag_size, varint_size
from protobuf.wire import encode_tag, encode_varint, WIRE_LEN

comptime BATCH = 100


@fieldwise_init
struct Small(Message):
    var id: Int64
    var name: String
    var active: Bool

    def __init__(out self):
        self.id = 0
        self.name = String("")
        self.active = False


@fieldwise_init
struct ManyInts(Message):
    var a: Int64
    var b: Int64
    var c: Int64
    var d: Int64
    var e: Int64
    var f: Int64
    var g: Int64
    var h: Int64

    def __init__(out self):
        self.a = 0; self.b = 0; self.c = 0; self.d = 0
        self.e = 0; self.f = 0; self.g = 0; self.h = 0


@fieldwise_init
struct Inner(Message):
    var a: Int64
    var b: Int64

    def __init__(out self):
        self.a = 0
        self.b = 0


@fieldwise_init
struct Large(Message):
    var id: Int64
    var name: String
    var description: String
    var payload: List[Byte]
    var x: Int32
    var y: Int32
    var flag: Bool
    var inner: Inner

    def __init__(out self):
        self.id = 0
        self.name = String("")
        self.description = String("")
        self.payload = List[Byte]()
        self.x = 0
        self.y = 0
        self.flag = False
        self.inner = Inner()


def _small() -> Small:
    return Small(42, String("benchmark"), True)


def _large() -> Large:
    var payload = List[Byte](capacity=256)
    for i in range(256):
        payload.append(Byte(i))
    return Large(
        7,
        String("a moderately sized name field"),
        String(
            "a longer description string that exercises the length-delimited "
            "copy path on both encode and decode sides of the codec"
        ),
        payload^,
        -3,
        4,
        True,
        Inner(123456789, -987654321),
    )


@parameter
def bench_encode_small(mut b: Bencher) raises:
    var msg = _small()

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            keep(Bool(encode(msg)))

    b.iter[call_fn]()
    keep(Bool(msg.name))


@parameter
def bench_encode_small_reused(mut b: Bencher) raises:
    var msg = _small()
    var buf = List[Byte](capacity=64)

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            buf.clear()
            msg.encode_to(buf)
            keep(Bool(buf))

    b.iter[call_fn]()
    keep(Bool(msg.name))


@parameter
def bench_encode_large_reused(mut b: Bencher) raises:
    var msg = _large()
    var buf = List[Byte](capacity=512)

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            buf.clear()
            msg.encode_to(buf)
            keep(Bool(buf))

    b.iter[call_fn]()
    keep(Bool(msg.name))


@parameter
def bench_decode_small(mut b: Bencher) raises:
    var data = encode(_small())

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            keep(Bool(decode[Small](Span(data)).name))

    b.iter[call_fn]()
    keep(Bool(data))


@parameter
def bench_roundtrip_small(mut b: Bencher) raises:
    var msg = _small()

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            keep(Bool(decode[Small](Span(encode(msg))).name))

    b.iter[call_fn]()
    keep(Bool(msg.name))


@parameter
def bench_encode_large(mut b: Bencher) raises:
    var msg = _large()

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            keep(Bool(encode(msg)))

    b.iter[call_fn]()
    keep(Bool(msg.name))


@parameter
def bench_decode_large(mut b: Bencher) raises:
    var data = encode(_large())

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            keep(Bool(decode[Large](Span(data)).description))

    b.iter[call_fn]()
    keep(Bool(data))


@parameter
def bench_encoded_size_large(mut b: Bencher) raises:
    var msg = _large()

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            keep(msg.encoded_size())

    b.iter[call_fn]()
    keep(Bool(msg.name))


@parameter
def bench_decode_many_ints(mut b: Bencher) raises:
    var data = encode(
        ManyInts(1, -2, 300, -4000, 50000, -600000, 7000000, -80000000)
    )

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            keep(decode[ManyInts](Span(data)).a)

    b.iter[call_fn]()
    keep(Bool(data))


@fieldwise_init
struct Packed(Message):
    var xs: List[Int64]  # repeated int64 = 1 (packed)

    def __init__(out self):
        self.xs = List[Int64]()

    def encoded_size(self) -> Int:
        var total = 0
        if len(self.xs) > 0:
            var n = 0
            for v in self.xs:
                n += varint_size(UInt64(v))
            total += tag_size(1) + varint_size(UInt64(n)) + n
        return total

    def encode_to(self, mut output: List[Byte]):
        if len(self.xs) > 0:
            var n = 0
            for v in self.xs:
                n += varint_size(UInt64(v))
            encode_tag(1, WIRE_LEN, output)
            encode_varint(UInt64(n), output)
            for v in self.xs:
                encode_varint(UInt64(v), output)

    def merge_field(
        mut self,
        field_number: Int,
        wire_type: Int,
        data: Span[Byte, _],
        mut pos: Int,
    ) raises:
        if field_number == 1 and wire_type == WIRE_LEN:
            read_packed_signed[DType.int64](read_bytes(data, pos), self.xs)
        else:
            skip_field(data, pos, wire_type)


@parameter
def bench_decode_packed_ints(mut b: Bencher) raises:
    # Mixed/large packed values (incl. negatives -> 10-byte): the SIMD prefix
    # bails quickly, so this measures the scalar path stays neutral.
    var p = Packed()
    for i in range(64):
        p.xs.append(Int64(i * 1000 - 32000))
    var data = encode(p)

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            keep(len(decode[Packed](Span(data)).xs))

    b.iter[call_fn]()
    keep(Bool(data))


@parameter
def bench_decode_packed_small(mut b: Bencher) raises:
    # Small (1-byte) packed values: the common case for numeric arrays, where
    # the SIMD prefix bulk-extracts whole chunks.
    var p = Packed()
    for i in range(256):
        p.xs.append(Int64(i % 100))
    var data = encode(p)

    @always_inline
    @parameter
    def call_fn() raises:
        for _ in range(BATCH):
            keep(len(decode[Packed](Span(data)).xs))

    b.iter[call_fn]()
    keep(Bool(data))


def main() raises:
    var m = Bench(BenchConfig(num_repetitions=3))
    m.bench_function[bench_encode_small](BenchId("encode_small"))
    m.bench_function[bench_encode_small_reused](BenchId("encode_small_reused"))
    m.bench_function[bench_decode_small](BenchId("decode_small"))
    m.bench_function[bench_roundtrip_small](BenchId("roundtrip_small"))
    m.bench_function[bench_encode_large](BenchId("encode_large"))
    m.bench_function[bench_encode_large_reused](BenchId("encode_large_reused"))
    m.bench_function[bench_decode_large](BenchId("decode_large"))
    m.bench_function[bench_decode_many_ints](BenchId("decode_many_ints"))
    m.bench_function[bench_decode_packed_ints](BenchId("decode_packed_ints"))
    m.bench_function[bench_decode_packed_small](BenchId("decode_packed_small"))
    m.bench_function[bench_encoded_size_large](BenchId("encoded_size_large"))
    print(m)
