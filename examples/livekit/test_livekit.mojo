"""Regression test: the real LiveKit schema generates and round-trips.

Run with `pixi run livekit-test` (generates `gen/` first). Guards against the
generator regressing on a production schema (51 messages, nested repeated, maps,
enums, oneofs, cross-file `MetricsBatch`, and `google.protobuf.Timestamp`).
"""

from std.testing import assert_equal, assert_true, TestSuite

from protobuf.message import decode, encode
from protobuf.well_known import Timestamp

from livekit_models import (
    ParticipantInfo,
    TrackInfo,
    RTPStats,
    ParticipantInfo_State_ACTIVE,
    TrackType_VIDEO,
    TrackSource_CAMERA,
)


def test_participant_round_trip() raises:
    var cam = TrackInfo()
    cam.sid = String("TR_cam")
    cam.type_ = TrackType_VIDEO
    cam.name = String("camera")
    cam.width = 1920
    cam.source = TrackSource_CAMERA

    var p = ParticipantInfo()
    p.sid = String("PA_1")
    p.identity = String("alice")
    p.state = ParticipantInfo_State_ACTIVE
    p.tracks = [cam^]
    p.attributes["k"] = String("v")

    var data = encode(p)
    assert_equal(len(data), p.encoded_size())
    var got = decode[ParticipantInfo](Span(data))
    assert_equal(got.sid, String("PA_1"))
    assert_equal(got.state, ParticipantInfo_State_ACTIVE)
    assert_equal(len(got.tracks), 1)
    assert_equal(got.tracks[0].name, String("camera"))
    assert_equal(got.tracks[0].width, UInt32(1920))
    assert_equal(got.attributes["k"], String("v"))


def test_rtpstats_timestamp_round_trip() raises:
    # RTPStats uses google.protobuf.Timestamp (a well-known type).
    var s = RTPStats()
    s.start_time = Timestamp(1_700_000_000, 0)
    s.end_time = Timestamp(1_700_000_300, 500_000_000)
    s.packets = 540_000
    s.bytes = 486_000_000

    var data = encode(s)
    assert_equal(len(data), s.encoded_size())
    var got = decode[RTPStats](Span(data))
    assert_equal(got.start_time.seconds, Int64(1_700_000_000))
    assert_equal(got.end_time.seconds, Int64(1_700_000_300))
    assert_equal(got.end_time.nanos, Int32(500_000_000))
    assert_equal(got.packets, UInt32(540_000))
    assert_true(got.bytes == UInt64(486_000_000))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
