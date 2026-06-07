#!/usr/bin/env python3
"""Decode/encode timing for the reference protobuf (upb C backend).

Times two messages — a packed numeric array (`packed.bin`) and a string-heavy
record (`person.bin`) — in a warm loop, reporting nanoseconds per op for
comparison with the Mojo, Go, and Rust harnesses on the same bytes.
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
    for _ in range(max(1, iters // 20)):
        fn()
    best = float("inf")
    for _ in range(5):
        t0 = time.perf_counter_ns()
        for _ in range(iters):
            fn()
        best = min(best, (time.perf_counter_ns() - t0) / iters)
    return best


def _bench(cls, data, touch, label):
    def decode():
        touch(cls.FromString(data))

    msg = cls.FromString(data)

    def encode():
        if not msg.SerializeToString():
            raise SystemExit("bad")

    iters = 50_000
    d = _time(decode, iters)
    e = _time(encode, iters)
    print(f"python(upb)   {label:7} decode {d:8.0f}   encode {e:8.0f}")


def main():
    pb = _pb()
    packed = open(os.path.join(HERE, "packed.bin"), "rb").read()
    person = open(os.path.join(HERE, "person.bin"), "rb").read()
    participant = open(os.path.join(HERE, "participant.bin"), "rb").read()
    _bench(pb.Packed, packed, lambda m: len(m.values), "packed")
    _bench(pb.Person, person, lambda m: m.address.city, "person")
    _bench(pb.ParticipantInfo, participant, lambda m: len(m.tracks),
           "participant")


if __name__ == "__main__":
    main()
