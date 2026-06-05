"""The `Message` trait and generic encode/decode drivers.

The `Message` trait's three methods (`encode_to`, `merge_field`, `encoded_size`)
have default implementations driven by reflection, so a default-constructible
struct of supported fields serializes with **no hand-written code** — field
number is the field's 1-based position:

```mojo
@fieldwise_init
struct Person(Message):
    var id: Int64
    var name: String

    def __init__(out self):  # default-constructible, for decode()
        self.id = 0
        self.name = String("")

var bytes = encode(Person(id=1, name=String("ada")))
var p = decode[Person](Span(bytes))
```

The generic `encode`/`decode` functions drive the rest: `encode` reserves the
buffer using `encoded_size()`, and `decode` default-constructs the message and
runs the tag-reading loop, calling `merge_field` for each field. Override the
three methods (see the `Message` docstring) for custom field numbers, field
types the reflection path doesn't cover, or canonical proto3 output — the
contract a future `protoc` generator emits.
"""

from std.reflection import reflect

from protobuf.fields import (
    read_bool,
    read_int64,
    read_string,
    read_uint64,
    skip_field,
    write_bool,
    write_int64,
    write_string,
    write_uint64,
)
from protobuf.size import (
    bool_field_size,
    int64_field_size,
    string_field_size,
    uint64_field_size,
)
from protobuf.wire import decode_tag

# Reflected type names, used to dispatch a struct field to the right codec.
# This is collision-safe: builtins reflect to bare names (e.g. `Bool`,
# `SIMD[DType.int64, 1]`), while user-defined types are module-qualified (e.g.
# `mymod.Bool`), so a same-named user type fails the `==` and falls through to
# the unsupported-type guard rather than matching the wrong codec.
comptime _INT64_NAME = reflect[Int64].name()
comptime _UINT64_NAME = reflect[UInt64].name()
comptime _BOOL_NAME = reflect[Bool].name()
comptime _STRING_NAME = reflect[String].name()


trait Message(Defaultable, Movable, ImplicitlyDestructible):
    """A type that can be serialized to and from the protobuf wire format.

    The three methods have **default implementations driven by reflection**: a
    struct that conforms and is default-constructible gets `encode_to`,
    `merge_field`, and `encoded_size` for free, with **field number = the field's
    1-based position**. Supported field types: `Int64`, `UInt64`, `Bool`,
    `String` — note the explicit-width `Int64`, not `Int`. Any other type is a
    compile error unless the methods are overridden.

    Override the three methods for custom/non-sequential field numbers, types
    the reflection path doesn't cover, or proto3 niceties (wire-type validation
    of known fields, omitting default-valued scalars). This is the contract a
    `protoc` generator emits.
    """

    def encoded_size(self) -> Int:
        """Returns the number of bytes `encode_to` will append.

        `encode` uses this to reserve the output buffer exactly. The default
        sums each field's size by reflection.
        """
        var total = 0
        comptime for idx in range(reflect[Self].field_count()):
            comptime field_type = reflect[Self].field_types()[idx]
            comptime name = reflect[field_type].name()
            ref f = reflect[Self].field_ref[idx](self)
            comptime if name == _INT64_NAME:
                total += int64_field_size(idx + 1, rebind[Int64](f))
            elif name == _UINT64_NAME:
                total += uint64_field_size(idx + 1, rebind[UInt64](f))
            elif name == _BOOL_NAME:
                total += bool_field_size(idx + 1)
            elif name == _STRING_NAME:
                total += string_field_size(idx + 1, rebind[String](f))
            else:
                comptime assert False, "Message: unsupported field type"
        return total

    def encode_to(self, mut output: List[Byte]):
        """Appends this message's fields to `output` (by reflection by default)."""
        comptime for idx in range(reflect[Self].field_count()):
            comptime field_type = reflect[Self].field_types()[idx]
            comptime name = reflect[field_type].name()
            ref f = reflect[Self].field_ref[idx](self)
            comptime if name == _INT64_NAME:
                write_int64(idx + 1, rebind[Int64](f), output)
            elif name == _UINT64_NAME:
                write_uint64(idx + 1, rebind[UInt64](f), output)
            elif name == _BOOL_NAME:
                write_bool(idx + 1, rebind[Bool](f), output)
            elif name == _STRING_NAME:
                write_string(idx + 1, rebind[String](f), output)
            else:
                comptime assert False, "Message: unsupported field type"

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
        var handled = False
        comptime for idx in range(reflect[Self].field_count()):
            if field_number == idx + 1:
                comptime field_type = reflect[Self].field_types()[idx]
                comptime name = reflect[field_type].name()
                comptime if name == _INT64_NAME:
                    rebind[Int64](
                        reflect[Self].field_ref[idx](self)
                    ) = read_int64(data, pos)
                elif name == _UINT64_NAME:
                    rebind[UInt64](
                        reflect[Self].field_ref[idx](self)
                    ) = read_uint64(data, pos)
                elif name == _BOOL_NAME:
                    rebind[Bool](
                        reflect[Self].field_ref[idx](self)
                    ) = read_bool(data, pos)
                elif name == _STRING_NAME:
                    rebind[String](
                        reflect[Self].field_ref[idx](self)
                    ) = read_string(data, pos)
                else:
                    comptime assert False, "Message: unsupported field type"
                handled = True
        if not handled:
            skip_field(data, pos, wire_type)


def encode[MessageType: Message](msg: MessageType) -> List[Byte]:
    """Serializes a message to a new byte buffer.

    Parameters:
        MessageType: The message type to serialize.

    Args:
        msg: The message to serialize.

    Returns:
        The encoded bytes.
    """
    var output = List[Byte](capacity=msg.encoded_size())
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
