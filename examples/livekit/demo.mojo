"""Build, encode, and decode real LiveKit messages with the generated bindings.

Run with `pixi run livekit-demo` (which first generates `gen/` from the vendored
`.proto` files). The bindings are produced by protoc-gen-mojo from LiveKit's
unmodified `livekit_models.proto`, exercising nested repeated messages, maps,
enums, oneofs, cross-file references, and the `google.protobuf.Timestamp`
well-known type — all wire-compatible with any other protobuf implementation.
"""

from protobuf.message import decode, encode
from protobuf.well_known import Timestamp
from livekit_models import (
    ParticipantInfo,
    TrackInfo,
    RTPStats,
    ParticipantInfo_State_ACTIVE,
    ParticipantInfo_Kind_STANDARD,
    TrackType_VIDEO,
    TrackType_AUDIO,
    TrackSource_CAMERA,
    TrackSource_MICROPHONE,
)


def _participant() -> ParticipantInfo:
    var cam = TrackInfo()
    cam.sid = String("TR_cam")
    cam.type_ = TrackType_VIDEO
    cam.name = String("camera")
    cam.width = 1920
    cam.height = 1080
    cam.source = TrackSource_CAMERA
    cam.mime_type = String("video/VP8")

    var mic = TrackInfo()
    mic.sid = String("TR_mic")
    mic.type_ = TrackType_AUDIO
    mic.name = String("microphone")
    mic.source = TrackSource_MICROPHONE
    mic.mime_type = String("audio/opus")

    var p = ParticipantInfo()
    p.sid = String("PA_abc123")
    p.identity = String("alice@example.com")
    p.name = String("Alice")
    p.state = ParticipantInfo_State_ACTIVE
    p.kind = ParticipantInfo_Kind_STANDARD
    p.tracks = [cam^, mic^]
    p.attributes["device"] = String("chrome-120")
    p.attributes["region"] = String("us-east")
    p.is_publisher = True
    return p^


def main() raises:
    # A ParticipantInfo: nested repeated TrackInfo, a string map, enums.
    var p = _participant()
    var pbytes = encode(p)
    var pg = decode[ParticipantInfo](Span(pbytes))
    print("ParticipantInfo:", pg.identity, "with", len(pg.tracks), "tracks,",
          len(pg.attributes), "attributes,", len(pbytes), "bytes")
    print("  track[0]:", pg.tracks[0].name, pg.tracks[0].width, "x",
          pg.tracks[0].height)

    # An RTPStats with google.protobuf.Timestamp well-known-type fields.
    var s = RTPStats()
    s.start_time = Timestamp(1_700_000_000, 0)
    s.end_time = Timestamp(1_700_000_300, 500_000_000)
    s.packets = 540_000
    s.bytes = 486_000_000
    s.packets_lost = 320
    var sbytes = encode(s)
    var sg = decode[RTPStats](Span(sbytes))
    print(
        "RTPStats:",
        sg.packets,
        "packets,",
        sg.bytes,
        "bytes over",
        sg.end_time.seconds - sg.start_time.seconds,
        "s,",
        len(sbytes),
        "wire bytes",
    )
    print("OK: real LiveKit schema round-trips through mojo-protobuf")
