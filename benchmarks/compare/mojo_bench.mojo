"""Decode/encode timing for mojo-protobuf on the shared Packed message.

Builds the same 2000 small packed int64 values (byte-identical to packed.bin),
then times one decode / one encode per iteration. Reports ns/op via the
std.benchmark mean (met) printed below.
"""

from std.benchmark import Bench, BenchConfig, Bencher, BenchId, keep
from protobuf.message import decode, encode
from bench import Packed


def main() raises:
    var p = Packed()
    for i in range(2000):
        p.values.append(Int64(i % 100))
    var data = encode(p)

    @parameter
    def bench_decode(mut b: Bencher) raises:
        @always_inline
        @parameter
        def call_fn() raises:
            keep(len(decode[Packed](Span(data)).values))
        b.iter[call_fn]()
        keep(Bool(data))

    @parameter
    def bench_encode(mut b: Bencher) raises:
        @always_inline
        @parameter
        def call_fn() raises:
            keep(Bool(encode(p)))
        b.iter[call_fn]()
        keep(Bool(p.values))

    var m = Bench(BenchConfig(num_repetitions=10))
    m.bench_function[bench_decode](BenchId("decode"))
    m.bench_function[bench_encode](BenchId("encode"))
    print(m)
