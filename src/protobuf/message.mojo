"""The `Message` trait and generic encode/decode drivers.

A protobuf message type conforms to `Message` by providing two methods:

- `encode_to(self, mut output)` — append the message's fields, using the
  `protobuf.fields` `write_*` helpers.
- `merge_field(mut self, field_number, wire_type, data, mut pos)` — handle one
  field: read it into the right struct field, or `skip_field` if unknown.

The generic `encode`/`decode` functions then drive the rest: `encode` collects
the bytes, and `decode` default-constructs the message and runs the tag-reading
loop, calling `merge_field` for each field. This is the contract a future
`protoc` code generator will emit for each message.

```mojo
struct Person(Message):
    var id: Int64
    var name: String

    def __init__(out self):
        self.id = 0
        self.name = String("")

    def encode_to(self, mut output: List[Byte]):
        write_int64(1, self.id, output)
        write_string(2, self.name, output)

    def merge_field(
        mut self, field_number: Int, wire_type: Int,
        data: Span[Byte, _], mut pos: Int,
    ) raises:
        if field_number == 1:
            self.id = read_int64(data, pos)
        elif field_number == 2:
            self.name = read_string(data, pos)
        else:
            skip_field(data, pos, wire_type)

var bytes = encode(Person(id=1, name=String("ada")))
var p = decode[Person](Span(bytes))
```
"""

from protobuf.wire import decode_tag


trait Message(Defaultable, Movable, ImplicitlyDestructible):
    """A type that can be serialized to and from the protobuf wire format.

    Conforming types must be default-constructible (so `decode` can build one to
    fill in) and provide `encode_to` and `merge_field`.
    """

    def encode_to(self, mut output: List[Byte]):
        """Appends this message's fields to `output`."""
        ...

    def merge_field(
        mut self,
        field_number: Int,
        wire_type: Int,
        data: Span[Byte, _],
        mut pos: Int,
    ) raises:
        """Reads one field into `self`, or skips it if the number is unknown.

        Args:
            field_number: The field number from the tag.
            wire_type: The wire type from the tag.
            data: The byte view being decoded.
            pos: The read offset, positioned at the value; advanced past it.

        Raises:
            If the field value is malformed or an unknown field has an invalid
            wire type.
        """
        ...


def encode[MessageType: Message](msg: MessageType) -> List[Byte]:
    """Serializes a message to a new byte buffer.

    Parameters:
        MessageType: The message type to serialize.

    Args:
        msg: The message to serialize.

    Returns:
        The encoded bytes.
    """
    var output = List[Byte]()
    msg.encode_to(output)
    return output^


def decode[
    MessageType: Message
](data: Span[Byte, _]) raises -> MessageType:
    """Deserializes a message from `data`.

    Default-constructs a `MessageType`, then reads every `(tag, value)` pair,
    dispatching each to `merge_field` (which fills known fields and skips
    unknown ones).

    Parameters:
        MessageType: The message type to deserialize.

    Args:
        data: The encoded bytes.

    Returns:
        The decoded message.

    Raises:
        If the input is malformed.
    """
    var msg = MessageType()
    var pos = 0
    while pos < len(data):
        var field_number, wire_type = decode_tag(data, pos)
        msg.merge_field(field_number, wire_type, data, pos)
    return msg^
