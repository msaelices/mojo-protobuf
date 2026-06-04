from std.testing import assert_equal

from protobuf import VERSION


def test_version() raises:
    assert_equal(String(VERSION), "0.1.0")
