"""Decode/encode timing for mojo-protobuf on the shared messages.

Builds the same values as `packed.bin` / `person.bin` (byte-identical), plus a
real LiveKit `ParticipantInfo` decoded from the canonical `participant.bin`,
then times one decode / one encode per iteration for each. The `met` (mean)
column printed below is ns/op; run.sh reformats it into the comparison table.
"""

from std.benchmark import Bench, BenchConfig, Bencher, BenchId, keep
from protobuf.message import decode, encode
from bench import Packed, Person, ParticipantInfo, RtpStats


def _read(path: String) raises -> List[Byte]:
    var f = open(path, "r")
    var data = f.read_bytes()
    f.close()
    return data^


def main() raises:
    var p = Packed()
    for i in range(2000):
        p.values.append(Int64(i % 100))
    var pdata = encode(p)

    var person = Person()
    person.id = 12345
    person.name = String("Grace Hopper")
    person.email = String("grace.hopper@example.com")
    person.active = True
    person.balance = 1234.56
    person.age = 85
    person.address.street = String("1 Infinite Loop")
    person.address.city = String("Cupertino")
    person.address.country = String("USA")
    var person_data = encode(person)

    # Real LiveKit ParticipantInfo from the canonical wire bytes (same bytes the
    # Go/Rust/Python harnesses decode), then re-encode the decoded message.
    var part_data = _read("participant.bin")
    var participant = decode[ParticipantInfo](Span(part_data))

    # Real LiveKit RtpStats: numeric-heavy with six google.protobuf.Timestamp
    # fields and a map (the well-known-type codec path).
    var rtp_data = _read("rtpstats.bin")
    var rtpstats = decode[RtpStats](Span(rtp_data))

    def packed_decode(mut b: Bencher) raises {imm pdata}:
        @always_inline
        def f() raises {imm pdata}:
            keep(len(decode[Packed](Span(pdata)).values))

        b.iter(f)
        keep(Bool(pdata))

    def packed_encode(mut b: Bencher) raises {imm p}:
        @always_inline
        def f() raises {imm p}:
            keep(Bool(encode(p)))

        b.iter(f)
        keep(Bool(p.values))

    def person_decode(mut b: Bencher) raises {imm person_data}:
        @always_inline
        def f() raises {imm person_data}:
            keep(Bool(decode[Person](Span(person_data)).name))

        b.iter(f)
        keep(Bool(person_data))

    def person_encode(mut b: Bencher) raises {imm person}:
        @always_inline
        def f() raises {imm person}:
            keep(Bool(encode(person)))

        b.iter(f)
        keep(Bool(person.name))

    def participant_decode(mut b: Bencher) raises {imm part_data}:
        @always_inline
        def f() raises {imm part_data}:
            keep(len(decode[ParticipantInfo](Span(part_data)).tracks))

        b.iter(f)
        keep(Bool(part_data))

    def participant_encode(mut b: Bencher) raises {imm participant}:
        @always_inline
        def f() raises {imm participant}:
            keep(Bool(encode(participant)))

        b.iter(f)
        keep(Bool(participant.sid))

    def rtpstats_decode(mut b: Bencher) raises {imm rtp_data}:
        @always_inline
        def f() raises {imm rtp_data}:
            keep(Int(decode[RtpStats](Span(rtp_data)).packets))

        b.iter(f)
        keep(Bool(rtp_data))

    def rtpstats_encode(mut b: Bencher) raises {imm rtpstats}:
        @always_inline
        def f() raises {imm rtpstats}:
            keep(Bool(encode(rtpstats)))

        b.iter(f)
        keep(Int(rtpstats.packets))

    var m = Bench(BenchConfig(num_repetitions=10))
    m.bench_function(packed_decode, BenchId("packed_decode"))
    m.bench_function(packed_encode, BenchId("packed_encode"))
    m.bench_function(person_decode, BenchId("person_decode"))
    m.bench_function(person_encode, BenchId("person_encode"))
    m.bench_function(participant_decode, BenchId("participant_decode"))
    m.bench_function(participant_encode, BenchId("participant_encode"))
    m.bench_function(rtpstats_decode, BenchId("rtpstats_decode"))
    m.bench_function(rtpstats_encode, BenchId("rtpstats_encode"))
    print(m)
