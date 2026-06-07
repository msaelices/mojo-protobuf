"""Well-known `google.protobuf` message types as Mojo `Message` structs.

`Timestamp` and `Duration` are the two common well-known types; both have the
same shape (`int64 seconds = 1; int32 nanos = 2;`). protoc-gen-mojo maps a field
of type `google.protobuf.Timestamp`/`Duration` to these via a
`from protobuf.well_known import ...` line instead of generating them. The wire
encoding is byte-identical to the reference protobuf.
"""

from protobuf.message import Message
from protobuf.fields import read_int64, skip_field, write_int64
from protobuf.size import int64_field_size


@fieldwise_init
struct Timestamp(Message, Copyable):
    var seconds: Int64
    var nanos: Int32

    def __init__(out self):
        self.seconds = Int64(0)
        self.nanos = Int32(0)

    def encoded_size(self) -> Int:
        var total = 0
        if self.seconds != 0:
            total += int64_field_size(1, self.seconds)
        if self.nanos != 0:
            total += int64_field_size(2, Int64(self.nanos))
        return total

    def encode_to(self, mut output: List[Byte]):
        if self.seconds != 0:
            write_int64(1, self.seconds, output)
        if self.nanos != 0:
            write_int64(2, Int64(self.nanos), output)

    def merge_field(
        mut self,
        field_number: Int,
        wire_type: Int,
        data: Span[Byte, _],
        mut pos: Int,
    ) raises:
        if field_number == 1:
            self.seconds = read_int64(data, pos)
        elif field_number == 2:
            self.nanos = Int32(read_int64(data, pos))
        else:
            skip_field(data, pos, wire_type)


@fieldwise_init
struct Duration(Message, Copyable):
    var seconds: Int64
    var nanos: Int32

    def __init__(out self):
        self.seconds = Int64(0)
        self.nanos = Int32(0)

    def encoded_size(self) -> Int:
        var total = 0
        if self.seconds != 0:
            total += int64_field_size(1, self.seconds)
        if self.nanos != 0:
            total += int64_field_size(2, Int64(self.nanos))
        return total

    def encode_to(self, mut output: List[Byte]):
        if self.seconds != 0:
            write_int64(1, self.seconds, output)
        if self.nanos != 0:
            write_int64(2, Int64(self.nanos), output)

    def merge_field(
        mut self,
        field_number: Int,
        wire_type: Int,
        data: Span[Byte, _],
        mut pos: Int,
    ) raises:
        if field_number == 1:
            self.seconds = read_int64(data, pos)
        elif field_number == 2:
            self.nanos = Int32(read_int64(data, pos))
        else:
            skip_field(data, pos, wire_type)
