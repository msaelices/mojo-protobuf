#!/usr/bin/env python3
"""Wire-interop tests: generated Mojo code <-> the reference protobuf library.

Both directions are exercised against `example.proto`:

- reverse: the generated Mojo encodes a `Person`, the reference Python protobuf
  decodes those bytes and checks every field;
- forward: the reference protobuf encodes a `Person`, the generated Mojo decodes
  those bytes and asserts the fields.

Requires `protoc`, the Python `protobuf` runtime, and `mojo` (all provided by the
pixi environment). Run via `pixi run test-interop`, which first regenerates
`test/gen/example.mojo` from `test/proto/example.proto`.
"""

import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.join(ROOT, "test", "gen")

# A Mojo driver that encodes a fixed Person and prints its bytes (space-separated
# decimal octets) on the last line of stdout.
ENC_DRIVER = """\
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
    var data = encode(p)
    var s = String("")
    for i in range(len(data)):
        if i > 0:
            s += " "
        s += String(Int(data[i]))
    print(s)
"""

# A Mojo driver that decodes reference-encoded bytes (spliced in as a literal)
# and asserts the fields, printing INTEROP_OK on success.
DEC_DRIVER = """\
from std.testing import assert_equal, assert_true, assert_false
from protobuf.message import decode
from example import Person


def main() raises:
    var data: List[Byte] = [%s]
    var got = decode[Person](Span(data))
    assert_equal(got.id, 42)
    assert_equal(got.name, String("Adaé"))
    assert_true(got.active)
    assert_true(got.nickname)
    assert_equal(got.nickname.value(), String("countess"))
    assert_false(got.age)
    assert_equal(len(got.avatar), 3)
    assert_equal(got.avatar[2], Byte(255))
    assert_equal(got.location.x, -3)
    assert_equal(got.location.y, 4)
    print("INTEROP_OK")
"""


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


def _reference_module():
    tmp = tempfile.mkdtemp()
    subprocess.run(
        ["protoc", "-I", "test/proto", "--python_out", tmp, "example.proto"],
        cwd=ROOT, check=True,
    )
    sys.path.insert(0, tmp)
    import example_pb2
    return example_pb2


def test_reverse_mojo_encodes_reference_decodes(pb):
    line = _run_mojo(ENC_DRIVER).strip().splitlines()[-1]
    data = bytes(int(x) for x in line.split())
    p = pb.Person.FromString(data)
    assert p.id == 7, p.id
    assert p.name == "Grace", p.name
    assert p.active is True
    assert p.HasField("age") and p.age == 99, p.age
    assert not p.HasField("nickname")
    assert p.avatar == b"\xaa\xbb", p.avatar
    assert p.location.x == -3 and p.location.y == 4, p.location


def test_forward_reference_encodes_mojo_decodes(pb):
    p = pb.Person(
        id=42, name="Adaé", active=True, nickname="countess",
        avatar=b"\x01\x02\xff", location=pb.Point(x=-3, y=4),
    )
    literal = ", ".join(f"Byte({b})" for b in p.SerializeToString())
    out = _run_mojo(DEC_DRIVER % literal)
    assert "INTEROP_OK" in out, out


def main():
    pb = _reference_module()
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t(pb)
        print(f"PASS {t.__name__}")
    print(f"\n{len(tests)} interop tests passed")


if __name__ == "__main__":
    main()
