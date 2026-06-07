#!/usr/bin/env python3
"""Decode/encode timing for the reference protobuf (upb C backend).

Decodes/encodes the shared `packed.bin` (2000 small packed int64 values) in a
warm loop and reports nanoseconds per operation, for comparison with the Mojo,
Go, and Rust harnesses on the same message.
"""

import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def _pb():
    tmp = tempfile.mkdtemp()
    subprocess.run(
        ["protoc", "-I", HERE, "--python_out", tmp, "bench.proto"], check=True
    )
    sys.path.insert(0, tmp)
    import bench_pb2
    return bench_pb2


def _time(fn, iters):
    for _ in range(max(1, iters // 20)):  # warmup
        fn()
    best = float("inf")
    for _ in range(5):
        t0 = time.perf_counter_ns()
        for _ in range(iters):
            fn()
        best = min(best, (time.perf_counter_ns() - t0) / iters)
    return best


def main():
    pb = _pb()
    data = open(os.path.join(HERE, "packed.bin"), "rb").read()
    n = len(pb.Packed.FromString(data).values)
    assert n == 2000, n

    def decode():
        m = pb.Packed.FromString(data)
        # touch the field so a lazy backend can't skip parsing it
        if len(m.values) != 2000:
            raise SystemExit("bad")

    msg = pb.Packed.FromString(data)

    def encode():
        if not msg.SerializeToString():
            raise SystemExit("bad")

    iters = 50_000
    dec = _time(decode, iters)
    enc = _time(encode, iters)
    impl = __import__(
        "google.protobuf.internal.api_implementation",
        fromlist=["Type"],
    ).Type()
    print(f"python({impl})  decode {dec:8.0f} ns   encode {enc:8.0f} ns")


if __name__ == "__main__":
    main()
