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
    read_bytes,
    read_double,
    read_float,
    read_int64,
    read_string,
    read_uint64,
    skip_field,
    write_bool,
    write_bytes,
    write_double,
    write_float,
    write_int64,
    write_string,
    write_uint64,
)
from protobuf.size import (
    bool_field_size,
    bytes_field_size,
    fixed32_field_size,
    fixed64_field_size,
    int64_field_size,
    string_field_size,
    tag_size,
    uint64_field_size,
    varint_size,
)
from protobuf.wire import WIRE_LEN, decode_tag, encode_tag, encode_varint

# Reflected type names, used to dispatch a struct field to the right codec.
# This is collision-safe: builtins reflect to bare names (e.g. `Bool`,
# `SIMD[DType.int64, 1]`), while user-defined types are module-qualified (e.g.
# `mymod.Bool`), so a same-named user type fails the `==` and falls through to
# the unsupported-type guard rather than matching the wrong codec.
comptime _INT_NAME = reflect[Int].name()
comptime _INT32_NAME = reflect[Int32].name()
comptime _INT64_NAME = reflect[Int64].name()
comptime _UINT32_NAME = reflect[UInt32].name()
comptime _UINT64_NAME = reflect[UInt64].name()
comptime _BOOL_NAME = reflect[Bool].name()
comptime _STRING_NAME = reflect[String].name()
comptime _BYTES_NAME = reflect[List[Byte]].name()
comptime _FLOAT32_NAME = reflect[Float32].name()
comptime _FLOAT64_NAME = reflect[Float64].name()

# `Optional[T]` field names, used to add proto3 explicit-presence semantics: an
# absent (`None`) optional emits nothing, while a present one emits its inner
# value exactly like the corresponding plain field (so a present-but-zero scalar
# is still written, which is how presence is distinguished from absence on the
# wire). Reflection cannot peel the inner `T` from an `Optional[T]` field type
# generically (the type is erased to `AnyType` and `Optional`'s `T` sits behind
# a `Variant`), so each supported inner type is matched by name, mirroring the
# plain-field dispatch above.
comptime _OPT_INT_NAME = reflect[Optional[Int]].name()
comptime _OPT_INT32_NAME = reflect[Optional[Int32]].name()
comptime _OPT_INT64_NAME = reflect[Optional[Int64]].name()
comptime _OPT_UINT32_NAME = reflect[Optional[UInt32]].name()
comptime _OPT_UINT64_NAME = reflect[Optional[UInt64]].name()
comptime _OPT_BOOL_NAME = reflect[Optional[Bool]].name()
comptime _OPT_STRING_NAME = reflect[Optional[String]].name()
comptime _OPT_BYTES_NAME = reflect[Optional[List[Byte]]].name()
comptime _OPT_FLOAT32_NAME = reflect[Optional[Float32]].name()
comptime _OPT_FLOAT64_NAME = reflect[Optional[Float64]].name()


trait Message(Defaultable, Movable, ImplicitlyDestructible):
    """A type that can be serialized to and from the protobuf wire format.

    The three methods have **default implementations driven by reflection**: a
    struct that conforms and is default-constructible gets `encode_to`,
    `merge_field`, and `encoded_size` for free, with **field number = the field's
    1-based position**. Supported field types: `Int`, `Int32`, `Int64`, `UInt32`,
    `UInt64`, `Bool`, `String`, `Float32`, `Float64`, and `List[Byte]` (protobuf
    `bytes`). `Int`, the machine-width integer, maps to an `int64` varint. A field
    whose type itself conforms to `Message` is encoded as a **nested message**
    (length-delimited). Any other type is a compile error unless the methods are
    overridden.

    Wrapping any of those scalar types in `Optional` gives proto3 **explicit
    presence**: an absent (`None`) field emits nothing and decodes back to
    `None`, while a present field is encoded exactly like its plain counterpart.
    This distinguishes "unset" from a default value, so a present-but-zero scalar
    (e.g. `Optional(Int64(0))`) is still written. `Optional` of a nested
    `Message` is not handled by the reflection default (the inner type cannot be
    recovered generically); use an override for that.

    Truly recursive messages (a type that contains itself) need indirection
    (e.g. an `OwnedPointer` field) and an explicit override; the reflection
    default only handles acyclic nesting.

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
            comptime if name == _INT_NAME:
                total += int64_field_size(idx + 1, Int64(rebind[Int](f)))
            elif name == _INT32_NAME:
                total += int64_field_size(idx + 1, Int64(rebind[Int32](f)))
            elif name == _INT64_NAME:
                total += int64_field_size(idx + 1, rebind[Int64](f))
            elif name == _UINT32_NAME:
                total += uint64_field_size(idx + 1, UInt64(rebind[UInt32](f)))
            elif name == _UINT64_NAME:
                total += uint64_field_size(idx + 1, rebind[UInt64](f))
            elif name == _BOOL_NAME:
                total += bool_field_size(idx + 1)
            elif name == _STRING_NAME:
                total += string_field_size(idx + 1, rebind[String](f))
            elif name == _BYTES_NAME:
                total += bytes_field_size(idx + 1, Span(rebind[List[Byte]](f)))
            elif name == _FLOAT32_NAME:
                total += fixed32_field_size(idx + 1)
            elif name == _FLOAT64_NAME:
                total += fixed64_field_size(idx + 1)
            elif name == _OPT_INT_NAME:
                ref o = rebind[Optional[Int]](f)
                if o:
                    total += int64_field_size(idx + 1, Int64(o.value()))
            elif name == _OPT_INT32_NAME:
                ref o = rebind[Optional[Int32]](f)
                if o:
                    total += int64_field_size(idx + 1, Int64(o.value()))
            elif name == _OPT_INT64_NAME:
                ref o = rebind[Optional[Int64]](f)
                if o:
                    total += int64_field_size(idx + 1, o.value())
            elif name == _OPT_UINT32_NAME:
                ref o = rebind[Optional[UInt32]](f)
                if o:
                    total += uint64_field_size(idx + 1, UInt64(o.value()))
            elif name == _OPT_UINT64_NAME:
                ref o = rebind[Optional[UInt64]](f)
                if o:
                    total += uint64_field_size(idx + 1, o.value())
            elif name == _OPT_BOOL_NAME:
                ref o = rebind[Optional[Bool]](f)
                if o:
                    total += bool_field_size(idx + 1)
            elif name == _OPT_STRING_NAME:
                ref o = rebind[Optional[String]](f)
                if o:
                    total += string_field_size(idx + 1, o.value())
            elif name == _OPT_BYTES_NAME:
                ref o = rebind[Optional[List[Byte]]](f)
                if o:
                    total += bytes_field_size(idx + 1, Span(o.value()))
            elif name == _OPT_FLOAT32_NAME:
                ref o = rebind[Optional[Float32]](f)
                if o:
                    total += fixed32_field_size(idx + 1)
            elif name == _OPT_FLOAT64_NAME:
                ref o = rebind[Optional[Float64]](f)
                if o:
                    total += fixed64_field_size(idx + 1)
            elif conforms_to(field_type, Message):
                var sub = _message_size(rebind[field_type](f))
                total += tag_size(idx + 1) + varint_size(UInt64(sub)) + sub
            else:
                comptime assert False, "Message: unsupported field type"
        return total

    def encode_to(self, mut output: List[Byte]):
        """Appends this message's fields to `output` (by reflection by default)."""
        comptime for idx in range(reflect[Self].field_count()):
            comptime field_type = reflect[Self].field_types()[idx]
            comptime name = reflect[field_type].name()
            ref f = reflect[Self].field_ref[idx](self)
            comptime if name == _INT_NAME:
                write_int64(idx + 1, Int64(rebind[Int](f)), output)
            elif name == _INT32_NAME:
                write_int64(idx + 1, Int64(rebind[Int32](f)), output)
            elif name == _INT64_NAME:
                write_int64(idx + 1, rebind[Int64](f), output)
            elif name == _UINT32_NAME:
                write_uint64(idx + 1, UInt64(rebind[UInt32](f)), output)
            elif name == _UINT64_NAME:
                write_uint64(idx + 1, rebind[UInt64](f), output)
            elif name == _BOOL_NAME:
                write_bool(idx + 1, rebind[Bool](f), output)
            elif name == _STRING_NAME:
                write_string(idx + 1, rebind[String](f), output)
            elif name == _BYTES_NAME:
                write_bytes(idx + 1, Span(rebind[List[Byte]](f)), output)
            elif name == _FLOAT32_NAME:
                write_float(idx + 1, rebind[Float32](f), output)
            elif name == _FLOAT64_NAME:
                write_double(idx + 1, rebind[Float64](f), output)
            elif name == _OPT_INT_NAME:
                ref o = rebind[Optional[Int]](f)
                if o:
                    write_int64(idx + 1, Int64(o.value()), output)
            elif name == _OPT_INT32_NAME:
                ref o = rebind[Optional[Int32]](f)
                if o:
                    write_int64(idx + 1, Int64(o.value()), output)
            elif name == _OPT_INT64_NAME:
                ref o = rebind[Optional[Int64]](f)
                if o:
                    write_int64(idx + 1, o.value(), output)
            elif name == _OPT_UINT32_NAME:
                ref o = rebind[Optional[UInt32]](f)
                if o:
                    write_uint64(idx + 1, UInt64(o.value()), output)
            elif name == _OPT_UINT64_NAME:
                ref o = rebind[Optional[UInt64]](f)
                if o:
                    write_uint64(idx + 1, o.value(), output)
            elif name == _OPT_BOOL_NAME:
                ref o = rebind[Optional[Bool]](f)
                if o:
                    write_bool(idx + 1, o.value(), output)
            elif name == _OPT_STRING_NAME:
                ref o = rebind[Optional[String]](f)
                if o:
                    write_string(idx + 1, o.value(), output)
            elif name == _OPT_BYTES_NAME:
                ref o = rebind[Optional[List[Byte]]](f)
                if o:
                    write_bytes(idx + 1, Span(o.value()), output)
            elif name == _OPT_FLOAT32_NAME:
                ref o = rebind[Optional[Float32]](f)
                if o:
                    write_float(idx + 1, o.value(), output)
            elif name == _OPT_FLOAT64_NAME:
                ref o = rebind[Optional[Float64]](f)
                if o:
                    write_double(idx + 1, o.value(), output)
            elif conforms_to(field_type, Message):
                # A nested message is length-delimited: tag, byte length, bytes.
                encode_tag(idx + 1, WIRE_LEN, output)
                encode_varint(
                    UInt64(_message_size(rebind[field_type](f))), output
                )
                _append_message(rebind[field_type](f), output)
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
                comptime if name == _INT_NAME:
                    rebind[Int](
                        reflect[Self].field_ref[idx](self)
                    ) = Int(read_int64(data, pos))
                elif name == _INT32_NAME:
                    rebind[Int32](
                        reflect[Self].field_ref[idx](self)
                    ) = Int32(read_int64(data, pos))
                elif name == _INT64_NAME:
                    rebind[Int64](
                        reflect[Self].field_ref[idx](self)
                    ) = read_int64(data, pos)
                elif name == _UINT32_NAME:
                    rebind[UInt32](
                        reflect[Self].field_ref[idx](self)
                    ) = UInt32(read_uint64(data, pos))
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
                elif name == _BYTES_NAME:
                    var owned = List[Byte]()
                    owned.extend(read_bytes(data, pos))
                    rebind[List[Byte]](
                        reflect[Self].field_ref[idx](self)
                    ) = owned^
                elif name == _FLOAT32_NAME:
                    rebind[Float32](
                        reflect[Self].field_ref[idx](self)
                    ) = read_float(data, pos)
                elif name == _FLOAT64_NAME:
                    rebind[Float64](
                        reflect[Self].field_ref[idx](self)
                    ) = read_double(data, pos)
                elif name == _OPT_INT_NAME:
                    rebind[Optional[Int]](
                        reflect[Self].field_ref[idx](self)
                    ) = Optional[Int](Int(read_int64(data, pos)))
                elif name == _OPT_INT32_NAME:
                    rebind[Optional[Int32]](
                        reflect[Self].field_ref[idx](self)
                    ) = Optional[Int32](Int32(read_int64(data, pos)))
                elif name == _OPT_INT64_NAME:
                    rebind[Optional[Int64]](
                        reflect[Self].field_ref[idx](self)
                    ) = Optional[Int64](read_int64(data, pos))
                elif name == _OPT_UINT32_NAME:
                    rebind[Optional[UInt32]](
                        reflect[Self].field_ref[idx](self)
                    ) = Optional[UInt32](UInt32(read_uint64(data, pos)))
                elif name == _OPT_UINT64_NAME:
                    rebind[Optional[UInt64]](
                        reflect[Self].field_ref[idx](self)
                    ) = Optional[UInt64](read_uint64(data, pos))
                elif name == _OPT_BOOL_NAME:
                    rebind[Optional[Bool]](
                        reflect[Self].field_ref[idx](self)
                    ) = Optional[Bool](read_bool(data, pos))
                elif name == _OPT_STRING_NAME:
                    rebind[Optional[String]](
                        reflect[Self].field_ref[idx](self)
                    ) = Optional[String](read_string(data, pos))
                elif name == _OPT_BYTES_NAME:
                    var owned = List[Byte]()
                    owned.extend(read_bytes(data, pos))
                    rebind[Optional[List[Byte]]](
                        reflect[Self].field_ref[idx](self)
                    ) = Optional[List[Byte]](owned^)
                elif name == _OPT_FLOAT32_NAME:
                    rebind[Optional[Float32]](
                        reflect[Self].field_ref[idx](self)
                    ) = Optional[Float32](read_float(data, pos))
                elif name == _OPT_FLOAT64_NAME:
                    rebind[Optional[Float64]](
                        reflect[Self].field_ref[idx](self)
                    ) = Optional[Float64](read_double(data, pos))
                elif conforms_to(field_type, Message):
                    rebind[field_type](
                        reflect[Self].field_ref[idx](self)
                    ) = decode[field_type](read_bytes(data, pos))
                else:
                    comptime assert False, "Message: unsupported field type"
                handled = True
        if not handled:
            skip_field(data, pos, wire_type)


# Small `Message`-bound helpers, called from the `conforms_to(..., Message)`
# branch of the reflection default so a nested-message field can be sized and
# encoded generically. They are pure forwarders, so always inline them.
@always_inline
def _message_size[MessageType: Message](msg: MessageType) -> Int:
    return msg.encoded_size()


@always_inline
def _append_message[
    MessageType: Message
](msg: MessageType, mut output: List[Byte]):
    msg.encode_to(output)


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
