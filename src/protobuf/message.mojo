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

# `Optional[T]` fields add proto3 explicit-presence semantics: an absent
# (`None`) optional emits nothing, while a present one emits its inner value
# exactly like the corresponding plain field (so a present-but-zero scalar is
# still written, which is how presence is distinguished from absence on the
# wire). An optional field is detected by `reflect[Self].field_at[idx]`'s
# `base_name()`, and its inner `T` is recovered generically as
# `Optional.IteratorType[...].Element` (the member alias backing `Optional`'s
# `Iterable` conformance, which a trait-bounded helper may access) — so the
# optional path reuses the same per-type helpers as plain fields instead of
# enumerating `Optional[T]` names by hand. A same-named user type is rejected
# by the full-name `comptime assert` in the helpers, mirroring the collision
# safety above.


trait Message(Defaultable, Deinitable, Movable):
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

    Wrapping any supported field type in `Optional` gives proto3 **explicit
    presence**: an absent (`None`) field emits nothing and decodes back to
    `None`, while a present field is encoded exactly like its plain counterpart.
    This distinguishes "unset" from a default value, so a present-but-zero scalar
    (e.g. `Optional(Int64(0))`) is still written. This includes nested messages:
    an `Optional` field whose inner type conforms to `Message` emits a (possibly
    empty) length-delimited field when present and nothing when `None`.

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
            comptime FT = reflect[Self].field_at[idx]
            ref f = reflect[Self].field_ref[idx](self)
            comptime if FT.base_name() == "Optional":
                # `conforms_to` (unlike the name check) narrows `FT.T` so the
                # field can bind to the `OptT: Iterable` helper parameter.
                comptime if conforms_to(FT.T, Iterable):
                    total += _optional_field_size(idx + 1, f)
                else:
                    comptime assert (
                        False
                    ), "Message: unsupported Optional-like field type"
            elif conforms_to(FT.T, Message):
                total += _message_field_size(idx + 1, rebind[FT.T](f))
            else:
                total += _scalar_field_size[FT.T](idx + 1, f)
        return total

    def encode_to(self, mut output: List[Byte]):
        """Appends this message's fields to `output` (by reflection by default).
        """
        comptime for idx in range(reflect[Self].field_count()):
            comptime FT = reflect[Self].field_at[idx]
            ref f = reflect[Self].field_ref[idx](self)
            comptime if FT.base_name() == "Optional":
                comptime if conforms_to(FT.T, Iterable):
                    _write_optional_field(idx + 1, f, output)
                else:
                    comptime assert (
                        False
                    ), "Message: unsupported Optional-like field type"
            elif conforms_to(FT.T, Message):
                _write_message_field(idx + 1, rebind[FT.T](f), output)
            else:
                _write_scalar_field[FT.T](idx + 1, f, output)

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
                comptime FT = reflect[Self].field_at[idx]
                comptime if FT.base_name() == "Optional":
                    comptime if conforms_to(FT.T, Iterable):
                        _merge_optional_field(
                            reflect[Self].field_ref[idx](self), data, pos
                        )
                    else:
                        comptime assert (
                            False
                        ), "Message: unsupported Optional-like field type"
                elif conforms_to(FT.T, Message):
                    rebind[FT.T](reflect[Self].field_ref[idx](self)) = decode[
                        FT.T
                    ](read_bytes(data, pos))
                else:
                    _merge_scalar_field(
                        reflect[Self].field_ref[idx](self), data, pos
                    )
                handled = True
        if not handled:
            skip_field(data, pos, wire_type)


# `Optional[T]` field helpers. The message methods reach these when a field's
# `base_name()` is `Optional`; the field binds to `OptT: Iterable` (which
# `Optional` conforms to), making `OptT.IteratorType[...].Element` — the inner
# `T` — legal to name in generic code. The full-name `comptime assert` then
# rejects any same-named non-stdlib type, and the value is rebound to an
# `Optional` and dispatched through the same per-type helpers as plain fields.


@always_inline
def _optional_field_size[OptT: Iterable](field_number: Int, o: OptT) -> Int:
    comptime Inner = OptT.IteratorType[ImmutAnyOrigin].Element
    comptime assert (
        reflect[OptT].name() == reflect[Optional[Inner]].name()
    ), "Message: unsupported Optional-like field type"
    ref opt = rebind[Optional[Inner]](o)
    if not opt:
        return 0
    comptime if conforms_to(Inner, Message):
        return _message_field_size(field_number, opt.value())
    else:
        return _scalar_field_size[Inner](field_number, opt.value())


@always_inline
def _write_optional_field[
    OptT: Iterable
](field_number: Int, o: OptT, mut output: List[Byte]):
    comptime Inner = OptT.IteratorType[ImmutAnyOrigin].Element
    comptime assert (
        reflect[OptT].name() == reflect[Optional[Inner]].name()
    ), "Message: unsupported Optional-like field type"
    ref opt = rebind[Optional[Inner]](o)
    if opt:
        comptime if conforms_to(Inner, Message):
            _write_message_field(field_number, opt.value(), output)
        else:
            _write_scalar_field[Inner](field_number, opt.value(), output)


@always_inline
def _merge_optional_field[
    OptT: Iterable
](mut dst: OptT, data: Span[Byte, _], mut pos: Int) raises:
    comptime Inner = OptT.IteratorType[ImmutAnyOrigin].Element
    comptime assert (
        reflect[OptT].name() == reflect[Optional[Inner]].name()
    ), "Message: unsupported Optional-like field type"
    # Overwriting the field destroys whatever it held, so the `Optional` written
    # to must be `Deinitable`, which it only is once its inner type is — and
    # `Iterable` bounds the element as `Movable` alone. `conforms_to` narrows
    # `Inner` against a user trait, so the nested-message arm gets that bound for
    # free by binding to `T: Message`; it does not narrow against the builtin
    # `Deinitable`, so the scalar arms name a concrete inner type instead, using
    # the same reflected-name dispatch as the plain scalar helpers below.
    comptime if conforms_to(Inner, Message):
        _merge_optional_message(rebind[Optional[Inner]](dst), data, pos)
    else:
        comptime name = reflect[Inner].name()
        comptime if name == _INT_NAME:
            _merge_optional_scalar[Int](dst, data, pos)
        elif name == _INT32_NAME:
            _merge_optional_scalar[Int32](dst, data, pos)
        elif name == _INT64_NAME:
            _merge_optional_scalar[Int64](dst, data, pos)
        elif name == _UINT32_NAME:
            _merge_optional_scalar[UInt32](dst, data, pos)
        elif name == _UINT64_NAME:
            _merge_optional_scalar[UInt64](dst, data, pos)
        elif name == _BOOL_NAME:
            _merge_optional_scalar[Bool](dst, data, pos)
        elif name == _STRING_NAME:
            _merge_optional_scalar[String](dst, data, pos)
        elif name == _BYTES_NAME:
            _merge_optional_scalar[List[Byte]](dst, data, pos)
        elif name == _FLOAT32_NAME:
            _merge_optional_scalar[Float32](dst, data, pos)
        elif name == _FLOAT64_NAME:
            _merge_optional_scalar[Float64](dst, data, pos)
        else:
            comptime assert False, "Message: unsupported field type"


@always_inline
def _merge_optional_message[
    T: Message
](mut opt: Optional[T], data: Span[Byte, _], mut pos: Int) raises:
    opt = Optional[T](decode[T](read_bytes(data, pos)))


@always_inline
def _merge_optional_scalar[
    T: Deinitable & Movable, OptT: Iterable
](mut dst: OptT, data: Span[Byte, _], mut pos: Int) raises:
    rebind[Optional[T]](dst) = Optional[T](_read_scalar[T](data, pos))


# Per-type codec dispatch shared by the plain and `Optional[T]` field paths.
# Each helper matches the field (or peeled inner) type by reflected name and
# forwards to the corresponding `protobuf.fields` / `protobuf.size` helper; a
# type that matches no arm is a compile error. Always inline them so the
# dispatch collapses into the message methods.


@always_inline
def _scalar_field_size[T: AnyType](field_number: Int, value: T) -> Int:
    comptime name = reflect[T].name()
    comptime if name == _INT_NAME:
        return int64_field_size(field_number, Int64(rebind[Int](value)))
    elif name == _INT32_NAME:
        return int64_field_size(field_number, Int64(rebind[Int32](value)))
    elif name == _INT64_NAME:
        return int64_field_size(field_number, rebind[Int64](value))
    elif name == _UINT32_NAME:
        return uint64_field_size(field_number, UInt64(rebind[UInt32](value)))
    elif name == _UINT64_NAME:
        return uint64_field_size(field_number, rebind[UInt64](value))
    elif name == _BOOL_NAME:
        return bool_field_size(field_number)
    elif name == _STRING_NAME:
        return string_field_size(field_number, rebind[String](value))
    elif name == _BYTES_NAME:
        return bytes_field_size(field_number, Span(rebind[List[Byte]](value)))
    elif name == _FLOAT32_NAME:
        return fixed32_field_size(field_number)
    elif name == _FLOAT64_NAME:
        return fixed64_field_size(field_number)
    else:
        comptime assert False, "Message: unsupported field type"


@always_inline
def _write_scalar_field[
    T: AnyType
](field_number: Int, value: T, mut output: List[Byte]):
    comptime name = reflect[T].name()
    comptime if name == _INT_NAME:
        write_int64(field_number, Int64(rebind[Int](value)), output)
    elif name == _INT32_NAME:
        write_int64(field_number, Int64(rebind[Int32](value)), output)
    elif name == _INT64_NAME:
        write_int64(field_number, rebind[Int64](value), output)
    elif name == _UINT32_NAME:
        write_uint64(field_number, UInt64(rebind[UInt32](value)), output)
    elif name == _UINT64_NAME:
        write_uint64(field_number, rebind[UInt64](value), output)
    elif name == _BOOL_NAME:
        write_bool(field_number, rebind[Bool](value), output)
    elif name == _STRING_NAME:
        write_string(field_number, rebind[String](value), output)
    elif name == _BYTES_NAME:
        write_bytes(field_number, Span(rebind[List[Byte]](value)), output)
    elif name == _FLOAT32_NAME:
        write_float(field_number, rebind[Float32](value), output)
    elif name == _FLOAT64_NAME:
        write_double(field_number, rebind[Float64](value), output)
    else:
        comptime assert False, "Message: unsupported field type"


@always_inline
def _merge_scalar_field[
    T: AnyType
](mut dst: T, data: Span[Byte, _], mut pos: Int) raises:
    comptime name = reflect[T].name()
    comptime if name == _INT_NAME:
        rebind[Int](dst) = Int(read_int64(data, pos))
    elif name == _INT32_NAME:
        rebind[Int32](dst) = Int32(read_int64(data, pos))
    elif name == _INT64_NAME:
        rebind[Int64](dst) = read_int64(data, pos)
    elif name == _UINT32_NAME:
        rebind[UInt32](dst) = UInt32(read_uint64(data, pos))
    elif name == _UINT64_NAME:
        rebind[UInt64](dst) = read_uint64(data, pos)
    elif name == _BOOL_NAME:
        rebind[Bool](dst) = read_bool(data, pos)
    elif name == _STRING_NAME:
        rebind[String](dst) = read_string(data, pos)
    elif name == _BYTES_NAME:
        var owned = List[Byte]()
        owned.extend(read_bytes(data, pos))
        rebind[List[Byte]](dst) = owned^
    elif name == _FLOAT32_NAME:
        rebind[Float32](dst) = read_float(data, pos)
    elif name == _FLOAT64_NAME:
        rebind[Float64](dst) = read_double(data, pos)
    else:
        comptime assert False, "Message: unsupported field type"


@always_inline
def _read_scalar[T: Movable](data: Span[Byte, _], mut pos: Int) raises -> T:
    """Reads one scalar value as `T`; the `Optional[T]` merge path uses this
    to build the wrapped value (`T` is `Optional`'s param, hence `Movable`)."""
    comptime name = reflect[T].name()
    comptime if name == _INT_NAME:
        var v = Int(read_int64(data, pos))
        return rebind_var[T](v)
    elif name == _INT32_NAME:
        var v = Int32(read_int64(data, pos))
        return rebind_var[T](v)
    elif name == _INT64_NAME:
        var v = read_int64(data, pos)
        return rebind_var[T](v)
    elif name == _UINT32_NAME:
        var v = UInt32(read_uint64(data, pos))
        return rebind_var[T](v)
    elif name == _UINT64_NAME:
        var v = read_uint64(data, pos)
        return rebind_var[T](v)
    elif name == _BOOL_NAME:
        var v = read_bool(data, pos)
        return rebind_var[T](v)
    elif name == _STRING_NAME:
        var v = read_string(data, pos)
        return rebind_var[T](v^)
    elif name == _BYTES_NAME:
        var v = List[Byte]()
        v.extend(read_bytes(data, pos))
        return rebind_var[T](v^)
    elif name == _FLOAT32_NAME:
        var v = read_float(data, pos)
        return rebind_var[T](v)
    elif name == _FLOAT64_NAME:
        var v = read_double(data, pos)
        return rebind_var[T](v)
    else:
        comptime assert False, "Message: unsupported field type"


# Nested-message field helpers (tag, byte length, bytes), called from the
# `conforms_to(..., Message)` branches so a message-typed field can be sized
# and encoded generically. Pure forwarders, so always inline them.
@always_inline
def _message_field_size[
    MessageType: Message
](field_number: Int, msg: MessageType) -> Int:
    var sub = msg.encoded_size()
    return tag_size(field_number) + varint_size(UInt64(sub)) + sub


@always_inline
def _write_message_field[
    MessageType: Message
](field_number: Int, msg: MessageType, mut output: List[Byte]):
    encode_tag(field_number, WIRE_LEN, output)
    encode_varint(UInt64(msg.encoded_size()), output)
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


def decode[MessageType: Message](data: Span[Byte, _]) raises -> MessageType:
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
