#!/usr/bin/env python3
"""Wire-interop tests: generated Mojo code <-> the reference protobuf library.

Both directions are exercised against `example.proto` (scalars / optional /
nested) and `telem.proto` (packed repeated): the reference encodes and the
generated Mojo decodes, and vice versa. The packed-repeated case is the key one
since proto3 packs `repeated` numeric fields by default.

Requires `protoc`, the Python `protobuf` runtime, and `mojo` (all provided by the
pixi environment). Run via `pixi run test-interop`, which first regenerates the
`.mojo` sources from `test/proto`.
"""

import importlib
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "test", "gen")

PERSON_ENC = """\
from protobuf.message import encode
from example import Person, Point


def main():
    var p = Person()
    p.id = 7
    p.name = String("Grace")
    p.active = True
    p.age = Optional(Int64(99))
    p.avatar = [Byte(0xAA), Byte(0xBB)]
    p.location = Point(-3, 4)
    _print_bytes(encode(p))
"""

PERSON_DEC = """\
from std.testing import assert_equal, assert_true, assert_false
from protobuf.message import decode
from example import Person


def main() raises:
    var data: List[Byte] = [%s]
    var got = decode[Person](Span(data))
    assert_equal(got.id, 42)
    assert_equal(got.name, String("Adaé"))
    assert_true(got.active)
    assert_equal(got.nickname.value(), String("countess"))
    assert_false(got.age)
    assert_equal(got.avatar[2], Byte(255))
    assert_equal(got.location.x, -3)
    print("INTEROP_OK")
"""

TELEM_ENC = """\
from protobuf.message import encode
from telem import Telemetry


def main():
    var t = Telemetry()
    t.samples = [Int64(1), Int64(-2), Int64(300), Int64(-400000)]
    t.temps = [Float64(1.5), Float64(-2.5)]
    t.id = 99
    _print_bytes(encode(t))
"""

TELEM_DEC = """\
from std.testing import assert_equal
from protobuf.message import decode
from telem import Telemetry


def main() raises:
    var data: List[Byte] = [%s]
    var got = decode[Telemetry](Span(data))
    assert_equal(len(got.samples), 4)
    assert_equal(got.samples[0], 1)
    assert_equal(got.samples[3], -400000)
    assert_equal(len(got.temps), 2)
    assert_equal(got.temps[1], Float64(-2.5))
    assert_equal(got.id, 99)
    print("INTEROP_OK")
"""

# A tiny helper appended to every encode driver: print the bytes as
# space-separated decimal octets on the last line of stdout.
_PRINT_HELPER = """

def _print_bytes(data: List[Byte]):
    var s = String("")
    for i in range(len(data)):
        if i > 0:
            s += " "
        s += String(Int(data[i]))
    print(s)
"""

_TMP = None


def _gen_reference():
    global _TMP
    if _TMP is None:
        _TMP = tempfile.mkdtemp()
        subprocess.run(
            ["protoc", "-I", "test/proto", "--python_out", _TMP,
             "example.proto", "telem.proto"],
            cwd=ROOT, check=True,
        )
        sys.path.insert(0, _TMP)


def _pb(module):
    _gen_reference()
    return importlib.import_module(module)


def _run_mojo(driver_src):
    path = os.path.join(GEN, "_interop_driver.mojo")
    with open(path, "w") as fh:
        fh.write(driver_src)
    try:
        proc = subprocess.run(
            ["mojo", "run", "-I", "src", "-I", "test/gen", path],
            cwd=ROOT, capture_output=True, text=True,
        )
    finally:
        os.remove(path)
    if proc.returncode != 0:
        raise AssertionError(f"mojo run failed:\n{proc.stderr}")
    return proc.stdout


def _mojo_encode(driver):
    line = _run_mojo(driver + _PRINT_HELPER).strip().splitlines()[-1]
    return bytes(int(x) for x in line.split())


def _mojo_decodes(driver, data):
    literal = ", ".join(f"Byte({b})" for b in data)
    out = _run_mojo(driver % literal)
    assert "INTEROP_OK" in out, out


def test_person_reverse_mojo_encodes_reference_decodes():
    pb = _pb("example_pb2")
    p = pb.Person.FromString(_mojo_encode(PERSON_ENC))
    assert p.id == 7 and p.name == "Grace" and p.active is True
    assert p.HasField("age") and p.age == 99 and not p.HasField("nickname")
    assert p.avatar == b"\xaa\xbb"
    assert p.location.x == -3 and p.location.y == 4


def test_person_forward_reference_encodes_mojo_decodes():
    pb = _pb("example_pb2")
    p = pb.Person(
        id=42, name="Adaé", active=True, nickname="countess",
        avatar=b"\x01\x02\xff", location=pb.Point(x=-3, y=4),
    )
    _mojo_decodes(PERSON_DEC, p.SerializeToString())


def test_telem_reverse_mojo_encodes_reference_decodes():
    pb = _pb("telem_pb2")
    t = pb.Telemetry.FromString(_mojo_encode(TELEM_ENC))
    assert list(t.samples) == [1, -2, 300, -400000], list(t.samples)
    assert list(t.temps) == [1.5, -2.5], list(t.temps)
    assert t.id == 99


def test_telem_forward_reference_encodes_mojo_decodes():
    # proto3 packs repeated numeric fields by default; this is the key case.
    pb = _pb("telem_pb2")
    t = pb.Telemetry(samples=[1, -2, 300, -400000], temps=[1.5, -2.5], id=99)
    _mojo_decodes(TELEM_DEC, t.SerializeToString())


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"PASS {t.__name__}")
    print(f"\n{len(tests)} interop tests passed")


if __name__ == "__main__":
    main()
