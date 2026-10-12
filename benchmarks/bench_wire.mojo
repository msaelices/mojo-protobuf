"""Benchmarks for the wire-format primitives (`protobuf.wire`).

Varints are the hot path of every protobuf encode/decode, so they get the most
coverage: small (1-byte) values stress per-call overhead, large (multi-byte)
values stress the shift/mask loop. Run with `pixi run bench-wire`.
"""

from std.benchmark import (
    Bench,
    BenchConfig,
    Bencher,
    BenchId,
    black_box,
    keep,
)

from protobuf.size import varint_size
from protobuf.wire import (
    decode_fixed64,
    decode_tag,
    decode_varint,
    encode_fixed64,
    encode_tag,
    encode_varint,
    WIRE_VARINT,
    zigzag_decode,
    zigzag_encode,
)

comptime BATCH = 1000


def _ramp(n: Int, modulo: UInt64, scale: UInt64) -> List[UInt64]:
    # A runtime-built list the optimizer can't constant-fold through.
    var out = List[UInt64](capacity=n)
    for i in range(n):
        out.append((UInt64(i) % modulo) * scale)
    return out^


def _mixed(n: Int) -> List[UInt64]:
    # Bit widths spread over 1..64 in an order the branch predictor can't learn,
    # so every varint length from 1 to 10 bytes shows up.
    var out = List[UInt64](capacity=n)
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    for _ in range(n):
        state = state * 6364136223846793005 + 1442695040888963407
        out.append((state | 1) >> ((state >> 58) & 63))
    return out^


# ===-----------------------------------------------------------------------===#
# Varint
# ===-----------------------------------------------------------------------===#


def bench_varint_encode_small(mut b: Bencher) raises:
    var values = _ramp(BATCH, 100, 1)  # 0..99 -> 1 byte each
    var out = List[Byte](capacity=BATCH * 2)

    @always_inline
    def call_fn() raises {imm values, mut out}:
        out.clear()
        for v in values:
            encode_varint(v, out)
        keep(Bool(out))

    b.iter(call_fn)
    keep(Bool(values))
    keep(Bool(out))


def bench_varint_encode_large(mut b: Bencher) raises:
    var values = _ramp(BATCH, 997, 0x0002_0003_0004_0005)  # ~9-10 bytes each
    var out = List[Byte](capacity=BATCH * 10)

    @always_inline
    def call_fn() raises {imm values, mut out}:
        out.clear()
        for v in values:
            encode_varint(v, out)
        keep(Bool(out))

    b.iter(call_fn)
    keep(Bool(values))
    keep(Bool(out))


def bench_varint_decode_small(mut b: Bencher) raises:
    var values = _ramp(BATCH, 100, 1)
    var buf = List[Byte]()
    for v in values:
        encode_varint(v, buf)

    @always_inline
    def call_fn() raises {imm buf}:
        var pos = 0
        for _ in range(BATCH):
            keep(decode_varint(buf, pos))

    b.iter(call_fn)
    keep(Bool(buf))


def bench_varint_decode_large(mut b: Bencher) raises:
    var values = _ramp(BATCH, 997, 0x0002_0003_0004_0005)
    var buf = List[Byte]()
    for v in values:
        encode_varint(v, buf)

    @always_inline
    def call_fn() raises {imm buf}:
        var pos = 0
        for _ in range(BATCH):
            keep(decode_varint(buf, pos))

    b.iter(call_fn)
    keep(Bool(buf))


def bench_varint_size_small(mut b: Bencher) raises:
    var values = _ramp(BATCH, 100, 1)  # 1 byte each

    @always_inline
    def call_fn() raises {imm values}:
        var n = 0
        for v in black_box(Span(values)):
            n += varint_size(v)
        keep(n)

    b.iter(call_fn)
    keep(Bool(values))


def bench_varint_size_large(mut b: Bencher) raises:
    var values = _ramp(BATCH, 997, 0x0002_0003_0004_0005)  # ~9-10 bytes each

    @always_inline
    def call_fn() raises {imm values}:
        var n = 0
        for v in black_box(Span(values)):
            n += varint_size(v)
        keep(n)

    b.iter(call_fn)
    keep(Bool(values))


def bench_varint_size_mixed(mut b: Bencher) raises:
    var values = _mixed(BATCH)  # 1-10 bytes, unpredictable

    @always_inline
    def call_fn() raises {imm values}:
        var n = 0
        for v in black_box(Span(values)):
            n += varint_size(v)
        keep(n)

    b.iter(call_fn)
    keep(Bool(values))


# ===-----------------------------------------------------------------------===#
# ZigZag / tag / fixed
# ===-----------------------------------------------------------------------===#


def bench_zigzag_roundtrip(mut b: Bencher) raises:
    var values = _ramp(BATCH, 1009, 0x0000_0001_0002_0003)

    @always_inline
    def call_fn() raises {imm values}:
        for v in values:
            keep(zigzag_decode(zigzag_encode(Int64(v))))

    b.iter(call_fn)
    keep(Bool(values))


def bench_tag_encode(mut b: Bencher) raises:
    var out = List[Byte](capacity=BATCH * 2)

    @always_inline
    def call_fn() raises {mut out}:
        out.clear()
        for i in range(BATCH):
            encode_tag(i + 1, WIRE_VARINT, out)
        keep(Bool(out))

    b.iter(call_fn)
    keep(Bool(out))


def bench_tag_decode(mut b: Bencher) raises:
    var buf = List[Byte]()
    for i in range(BATCH):
        encode_tag(i + 1, WIRE_VARINT, buf)

    @always_inline
    def call_fn() raises {imm buf}:
        var pos = 0
        for _ in range(BATCH):
            var field_number, wire_type = decode_tag(buf, pos)
            keep(field_number)
            keep(wire_type)

    b.iter(call_fn)
    keep(Bool(buf))


def bench_fixed64_roundtrip(mut b: Bencher) raises:
    var values = _ramp(BATCH, 1013, 0x0102_0304_0506_0708)
    var out = List[Byte](capacity=BATCH * 8)

    @always_inline
    def call_fn() raises {imm values, mut out}:
        out.clear()
        for v in values:
            encode_fixed64(v, out)
        var pos = 0
        for _ in range(BATCH):
            keep(decode_fixed64(out, pos))

    b.iter(call_fn)
    keep(Bool(values))
    keep(Bool(out))


def main() raises:
    var m = Bench(BenchConfig(num_repetitions=3))
    m.bench_function(bench_varint_encode_small, BenchId("varint_encode_small"))
    m.bench_function(bench_varint_encode_large, BenchId("varint_encode_large"))
    m.bench_function(bench_varint_decode_small, BenchId("varint_decode_small"))
    m.bench_function(bench_varint_decode_large, BenchId("varint_decode_large"))
    m.bench_function(bench_varint_size_small, BenchId("varint_size_small"))
    m.bench_function(bench_varint_size_large, BenchId("varint_size_large"))
    m.bench_function(bench_varint_size_mixed, BenchId("varint_size_mixed"))
    m.bench_function(bench_zigzag_roundtrip, BenchId("zigzag_roundtrip"))
    m.bench_function(bench_tag_encode, BenchId("tag_encode"))
    m.bench_function(bench_tag_decode, BenchId("tag_decode"))
    m.bench_function(bench_fixed64_roundtrip, BenchId("fixed64_roundtrip"))
    print(m)
