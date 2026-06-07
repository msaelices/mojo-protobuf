#!/usr/bin/env python3
"""`protoc-gen-mojo`: a protoc plugin that emits pure-Mojo `Message` structs.

protoc parses the `.proto` files and hands this plugin a `CodeGeneratorRequest`
(itself a protobuf message) on stdin; the plugin walks the descriptors and
writes a `CodeGeneratorResponse` with the generated `.mojo` source on stdout.

Run via:

    protoc --plugin=protoc-gen-mojo=codegen/protoc-gen-mojo \
           --mojo_out=OUTDIR your.proto

Supported: proto3 singular scalars (double, float, int32/64, uint32/64,
sint32/64, bool, string, bytes), `enum` (-> `Int32` + named constants),
`optional` scalars (proto3 explicit presence -> `Optional[T]`), singular nested
messages, packed `repeated` numeric scalars/enums, non-packed `repeated`
string/bytes/message (-> `List[T]`), and `map<K, V>` (-> `Dict[K, V]`).
Unsupported features (oneof, group, fixed/sfixed, proto2) raise a clear error
so the generated code is never silently wrong.
"""

import sys

from google.protobuf import descriptor_pb2
from google.protobuf.compiler import plugin_pb2

FD = descriptor_pb2.FieldDescriptorProto


class GenError(Exception):
    """A .proto feature this generator does not (yet) support."""


# Mojo reserved words that cannot be used as identifiers; suffix with `_`.
_RESERVED = {
    "ref", "mut", "out", "deinit", "read", "var", "def", "fn", "in", "is",
    "as", "if", "else", "elif", "for", "while", "return", "raise", "raises",
    "struct", "trait", "comptime", "alias", "self", "Self", "import", "from",
    "and", "or", "not", "True", "False", "None", "pass", "break", "continue",
    "with", "try", "except", "finally", "yield", "async", "await", "type",
}


def _ident(name: str) -> str:
    return name + "_" if name in _RESERVED else name


# proto scalar type -> codec spec.
#   mojo:    Mojo field type
#   default: default-value expression for the no-arg constructor
#   write:   (num, acc) -> the `write_*(...)` statement
#   size:    (num, acc) -> the per-field size expression
#   read:    (src='data', cur='pos') -> expression decoding one value from span
#            `src` at cursor `cur` (defaults reproduce the singular-field call;
#            map-entry decode passes the entry span + its own cursor)
#   imports: runtime symbols this arm needs (module -> names)
class _Scalar:
    def __init__(self, mojo, default, write, size, read, w, s, r):
        self.mojo = mojo
        self.default = default
        self.write = write
        self.size = size
        self.read = read
        self.imports = {"fields": {w, r}, "size": {s}}


SCALAR = {
    FD.TYPE_DOUBLE: _Scalar(
        "Float64", "Float64(0)",
        lambda n, a: f"write_double({n}, {a}, output)",
        lambda n, a: f"fixed64_field_size({n})",
        lambda s="data", p="pos": f"read_double({s}, {p})",
        "write_double", "fixed64_field_size", "read_double"),
    FD.TYPE_FLOAT: _Scalar(
        "Float32", "Float32(0)",
        lambda n, a: f"write_float({n}, {a}, output)",
        lambda n, a: f"fixed32_field_size({n})",
        lambda s="data", p="pos": f"read_float({s}, {p})",
        "write_float", "fixed32_field_size", "read_float"),
    FD.TYPE_INT64: _Scalar(
        "Int64", "Int64(0)",
        lambda n, a: f"write_int64({n}, {a}, output)",
        lambda n, a: f"int64_field_size({n}, {a})",
        lambda s="data", p="pos": f"read_int64({s}, {p})",
        "write_int64", "int64_field_size", "read_int64"),
    FD.TYPE_UINT64: _Scalar(
        "UInt64", "UInt64(0)",
        lambda n, a: f"write_uint64({n}, {a}, output)",
        lambda n, a: f"uint64_field_size({n}, {a})",
        lambda s="data", p="pos": f"read_uint64({s}, {p})",
        "write_uint64", "uint64_field_size", "read_uint64"),
    FD.TYPE_INT32: _Scalar(
        "Int32", "Int32(0)",
        lambda n, a: f"write_int64({n}, Int64({a}), output)",
        lambda n, a: f"int64_field_size({n}, Int64({a}))",
        lambda s="data", p="pos": f"Int32(read_int64({s}, {p}))",
        "write_int64", "int64_field_size", "read_int64"),
    FD.TYPE_UINT32: _Scalar(
        "UInt32", "UInt32(0)",
        lambda n, a: f"write_uint64({n}, UInt64({a}), output)",
        lambda n, a: f"uint64_field_size({n}, UInt64({a}))",
        lambda s="data", p="pos": f"UInt32(read_uint64({s}, {p}))",
        "write_uint64", "uint64_field_size", "read_uint64"),
    FD.TYPE_SINT32: _Scalar(
        "Int32", "Int32(0)",
        lambda n, a: f"write_sint64({n}, Int64({a}), output)",
        lambda n, a: f"sint64_field_size({n}, Int64({a}))",
        lambda s="data", p="pos": f"Int32(read_sint64({s}, {p}))",
        "write_sint64", "sint64_field_size", "read_sint64"),
    FD.TYPE_SINT64: _Scalar(
        "Int64", "Int64(0)",
        lambda n, a: f"write_sint64({n}, {a}, output)",
        lambda n, a: f"sint64_field_size({n}, {a})",
        lambda s="data", p="pos": f"read_sint64({s}, {p})",
        "write_sint64", "sint64_field_size", "read_sint64"),
    FD.TYPE_BOOL: _Scalar(
        "Bool", "False",
        lambda n, a: f"write_bool({n}, {a}, output)",
        lambda n, a: f"bool_field_size({n})",
        lambda s="data", p="pos": f"read_bool({s}, {p})",
        "write_bool", "bool_field_size", "read_bool"),
    FD.TYPE_STRING: _Scalar(
        "String", 'String("")',
        lambda n, a: f"write_string({n}, {a}, output)",
        lambda n, a: f"string_field_size({n}, {a})",
        lambda s="data", p="pos": f"read_string({s}, {p})",
        "write_string", "string_field_size", "read_string"),
    # proto3 enums are wire-identical to int32 (a two's-complement varint), and
    # are open (unknown values are preserved), so they map to a bare Int32; the
    # named values are emitted as `comptime` constants (see _enum_constants).
    FD.TYPE_ENUM: _Scalar(
        "Int32", "Int32(0)",
        lambda n, a: f"write_int64({n}, Int64({a}), output)",
        lambda n, a: f"int64_field_size({n}, Int64({a}))",
        lambda s="data", p="pos": f"Int32(read_int64({s}, {p}))",
        "write_int64", "int64_field_size", "read_int64"),
}

_UNSUPPORTED_TYPE = {
    FD.TYPE_GROUP: "group",
    FD.TYPE_FIXED32: "fixed32",
    FD.TYPE_FIXED64: "fixed64",
    FD.TYPE_SFIXED32: "sfixed32",
    FD.TYPE_SFIXED64: "sfixed64",
}


# Packed `repeated` scalar codec spec (proto3 default for numeric scalars: one
# length-delimited field holding the values back-to-back, no per-element tags).
#   elem:    Mojo element type (the List holds `List[elem]`)
#   fixed:   True for fixed-width elements (size = width * count), False varint
#   width:   byte width when fixed
#   vwrite:  (v) -> value-only encode statement (appends to `output`)
#   vsize:   (v) -> per-value byte-size expression (varint types only)
#   vread:   (src, p) -> expression decoding one value from span `src` at `p`
#   imports: runtime symbols needed
class _Packed:
    def __init__(self, elem, fixed, width, vwrite, vsize, vread, imports,
                 helper=None):
        self.elem = elem
        self.fixed = fixed
        self.width = width
        self.vwrite = vwrite
        self.vsize = vsize
        self.vread = vread
        self.imports = imports
        # For plain varint ints, a SIMD-accelerated whole-blob decode helper
        # (read_packed_signed/unsigned[dtype]); None falls back to a scalar loop.
        self.helper = helper


PACKED = {
    FD.TYPE_DOUBLE: _Packed(
        "Float64", True, 8,
        lambda v: f"encode_fixed[DType.float64]({v}, output)", lambda v: "8",
        lambda s, p: f"read_double({s}, {p})",
        {"wire": {"encode_fixed"}, "fields": {"read_double"}}),
    FD.TYPE_FLOAT: _Packed(
        "Float32", True, 4,
        lambda v: f"encode_fixed[DType.float32]({v}, output)", lambda v: "4",
        lambda s, p: f"read_float({s}, {p})",
        {"wire": {"encode_fixed"}, "fields": {"read_float"}}),
    FD.TYPE_INT64: _Packed(
        "Int64", False, 0,
        lambda v: f"encode_varint(UInt64({v}), output)",
        lambda v: f"varint_size(UInt64({v}))",
        lambda s, p: f"read_int64({s}, {p})",
        {"fields": {"read_int64", "read_packed_signed"}},
        helper="read_packed_signed[DType.int64]"),
    FD.TYPE_UINT64: _Packed(
        "UInt64", False, 0,
        lambda v: f"encode_varint({v}, output)",
        lambda v: f"varint_size({v})",
        lambda s, p: f"read_uint64({s}, {p})",
        {"fields": {"read_uint64", "read_packed_unsigned"}},
        helper="read_packed_unsigned[DType.uint64]"),
    FD.TYPE_INT32: _Packed(
        "Int32", False, 0,
        lambda v: f"encode_varint(UInt64(Int64({v})), output)",
        lambda v: f"varint_size(UInt64(Int64({v})))",
        lambda s, p: f"Int32(read_int64({s}, {p}))",
        {"fields": {"read_int64", "read_packed_signed"}},
        helper="read_packed_signed[DType.int32]"),
    FD.TYPE_ENUM: _Packed(  # repeated enum packs like repeated int32
        "Int32", False, 0,
        lambda v: f"encode_varint(UInt64(Int64({v})), output)",
        lambda v: f"varint_size(UInt64(Int64({v})))",
        lambda s, p: f"Int32(read_int64({s}, {p}))",
        {"fields": {"read_int64", "read_packed_signed"}},
        helper="read_packed_signed[DType.int32]"),
    FD.TYPE_UINT32: _Packed(
        "UInt32", False, 0,
        lambda v: f"encode_varint(UInt64({v}), output)",
        lambda v: f"varint_size(UInt64({v}))",
        lambda s, p: f"UInt32(read_uint64({s}, {p}))",
        {"fields": {"read_uint64", "read_packed_unsigned"}},
        helper="read_packed_unsigned[DType.uint32]"),
    FD.TYPE_SINT64: _Packed(
        "Int64", False, 0,
        lambda v: f"encode_varint(zigzag_encode({v}), output)",
        lambda v: f"varint_size(zigzag_encode({v}))",
        lambda s, p: f"read_sint64({s}, {p})",
        {"wire": {"zigzag_encode"}, "fields": {"read_sint64"}}),
    FD.TYPE_SINT32: _Packed(
        "Int32", False, 0,
        lambda v: f"encode_varint(zigzag_encode(Int64({v})), output)",
        lambda v: f"varint_size(zigzag_encode(Int64({v})))",
        lambda s, p: f"Int32(read_sint64({s}, {p}))",
        {"wire": {"zigzag_encode"}, "fields": {"read_sint64"}}),
    FD.TYPE_BOOL: _Packed(
        "Bool", False, 0,
        lambda v: f"encode_varint(UInt64(1) if {v} else UInt64(0), output)",
        lambda v: "1",
        lambda s, p: f"read_bool({s}, {p})",
        {"fields": {"read_bool"}}),
}


def _merge_imports(into, extra):
    for mod, names in extra.items():
        into.setdefault(mod, set()).update(names)


def _struct_name(full_name, prefix):
    # `.pkg.Outer.Inner` (stripped of leading dot + package) -> `Outer_Inner`.
    rel = full_name[len(prefix):] if full_name.startswith(prefix) else full_name
    return rel.lstrip(".").replace(".", "_")


def _collect_messages(msgs, scope, package, type_map, out, map_entries):
    """Walk messages + nested types, recording full-name -> Mojo struct name.

    Synthetic map-entry messages (a `map<K, V>` field lowers to a repeated
    nested message with `options.map_entry`) are recorded in `map_entries`
    (full name -> the entry descriptor, whose fields 1/2 are key/value) and
    not emitted as structs.
    """
    for m in msgs:
        full = f"{scope}.{m.name}"
        if m.options.map_entry:
            map_entries[full] = m
            continue
        mojo = _struct_name(full, "." + package if package else ".")
        if any(existing == mojo for existing, _ in out):
            raise GenError(
                f"message '{full}' flattens to Mojo struct name '{mojo}', which "
                "collides with another message; rename one to disambiguate"
            )
        type_map[full] = mojo
        out.append((mojo, m))
        _collect_messages(
            m.nested_type, full, package, type_map, out, map_entries
        )


def _is_bytes(field):
    return field.type == FD.TYPE_BYTES


def _field_mojo_type(field, type_map):
    if field.type == FD.TYPE_BYTES:
        return "List[Byte]"
    if field.type == FD.TYPE_MESSAGE:
        if field.type_name not in type_map:
            raise GenError(
                f"field '{field.name}' references type '{field.type_name}' "
                "defined outside this file (cross-file refs unsupported in v1)"
            )
        return type_map[field.type_name]
    if field.type in SCALAR:
        return SCALAR[field.type].mojo
    if field.type in _UNSUPPORTED_TYPE:
        raise GenError(
            f"field '{field.name}': {_UNSUPPORTED_TYPE[field.type]} is not "
            "supported in v1"
        )
    raise GenError(f"field '{field.name}': unsupported proto type {field.type}")


_NONPACKED_REPEATED = (FD.TYPE_STRING, FD.TYPE_BYTES, FD.TYPE_MESSAGE)


def _is_map_field(field, map_entries):
    return (
        field.label == FD.LABEL_REPEATED
        and field.type == FD.TYPE_MESSAGE
        and field.type_name in map_entries
    )


# proto restricts map keys to integral / bool / string (no float, bytes,
# enum, or message); these are exactly the scalar arms valid as a Dict key.
_MAP_KEY_TYPES = (
    FD.TYPE_INT32, FD.TYPE_INT64, FD.TYPE_UINT32, FD.TYPE_UINT64,
    FD.TYPE_SINT32, FD.TYPE_SINT64, FD.TYPE_BOOL, FD.TYPE_STRING,
)


def _check_field(field, map_entries):
    if _is_map_field(field, map_entries):
        return  # validated in the map handler (key/value types)
    if field.label == FD.LABEL_REPEATED:
        if field.type not in PACKED and field.type not in _NONPACKED_REPEATED:
            # e.g. repeated fixed/sfixed/group
            raise GenError(
                f"field '{field.name}': repeated of this type is not supported"
            )
    if field.label == FD.LABEL_REQUIRED:
        raise GenError(f"field '{field.name}': proto2 required is not supported")
    # proto3 `optional` rides a synthetic oneof; a real oneof has no
    # proto3_optional flag.
    if field.HasField("oneof_index") and not field.proto3_optional:
        raise GenError(f"field '{field.name}': oneof is not supported in v1")


def _gen_map_field(f, name, num, map_entries, type_map, imports,
                   decls, defaults, encode_items, size_items, decode):
    """Emit a proto3 `map<K, V>` field as a Mojo `Dict[K, V]`.

    A map lowers to `repeated Entry { K key = 1; V value = 2; }`; each entry is
    a length-delimited sub-message that always carries both key and value (even
    at default value, unlike normal proto3 fields). Keys are integral/bool/
    string; values reuse every singular arm (scalar/string/bytes/message/enum).
    Last occurrence of a key wins, matching the proto3 map merge rule.
    """
    m = name
    entry = map_entries[f.type_name]
    kf = next((x for x in entry.field if x.number == 1), None)
    vf = next((x for x in entry.field if x.number == 2), None)
    if kf is None or vf is None:
        raise GenError(
            f"field '{f.name}': malformed map entry '{f.type_name}' "
            "(expected key=1 and value=2)"
        )
    if kf.type not in _MAP_KEY_TYPES:
        raise GenError(
            f"field '{f.name}': map key type {kf.type} is not supported"
        )
    kspec = SCALAR[kf.type]
    _merge_imports(imports, kspec.imports)
    _merge_imports(imports, {
        "wire": {"encode_tag", "encode_varint", "WIRE_LEN", "decode_tag"},
        "size": {"tag_size", "varint_size"},
        "fields": {"read_bytes"},
    })
    imports.setdefault("message", set()).add("decode")

    ktype = kspec.mojo
    ksize = kspec.size(1, "_e.key")
    kwrite = kspec.write(1, "_e.key")
    # `^` only for non-trivial types; transferring a trivial register type
    # (Int*/UInt*/Bool/enum) is a no-op the compiler warns about.
    kmove = "^" if kf.type == FD.TYPE_STRING else ""
    vmove = "^" if vf.type in (
        FD.TYPE_STRING, FD.TYPE_BYTES, FD.TYPE_MESSAGE) else ""

    # Value codec: scalar (incl. string / enum), bytes, or nested message.
    if vf.type == FD.TYPE_BYTES:
        vtype, vdefault = "List[Byte]", "List[Byte]()"
        _merge_imports(imports, {
            "fields": {"write_bytes"}, "size": {"bytes_field_size"}})
        vsize = "bytes_field_size(2, Span(_e.value))"
        vwrite = ["            write_bytes(2, Span(_e.value), output)"]
        vread = [
            f"                    var _vb_{m} = List[Byte]()",
            f"                    _vb_{m}.extend(read_bytes(_entry_{m}, _ep_{m}))",
            f"                    _v_{m} = _vb_{m}^",
        ]
        is_msg = False
    elif vf.type == FD.TYPE_MESSAGE:
        vtype = _field_mojo_type(vf, type_map)
        vdefault = f"{vtype}()"
        vsize, vwrite = "", []  # handled inline (encoded_size computed once)
        vread = [
            f"                    _v_{m} = decode[{vtype}]("
            f"read_bytes(_entry_{m}, _ep_{m}))",
        ]
        is_msg = True
    else:
        vspec = SCALAR.get(vf.type)
        if vspec is None:
            _field_mojo_type(vf, type_map)  # raises a precise GenError
            raise GenError(f"field '{f.name}': unsupported map value type")
        _merge_imports(imports, vspec.imports)
        vtype, vdefault = vspec.mojo, vspec.default
        vsize = vspec.size(2, "_e.value")
        vwrite = [f"            {vspec.write(2, '_e.value')}"]
        vread = [f"                    _v_{m} = "
                 f"{vspec.read('_entry_' + m, '_ep_' + m)}"]
        is_msg = False

    decls.append(f"    var {m}: Dict[{ktype}, {vtype}]")
    defaults.append(f"        self.{m} = Dict[{ktype}, {vtype}]()")

    # Encode + size: one length-delimited entry per pair; entry body length is
    # key-field-bytes + value-field-bytes (each includes its own tag).
    if is_msg:
        enc = [
            f"        for _e in self.{m}.items():",
            "            var _vsz = _e.value.encoded_size()",
            "            var _vf = tag_size(2) + varint_size("
            "UInt64(_vsz)) + _vsz",
            f"            encode_tag({num}, WIRE_LEN, output)",
            f"            encode_varint(UInt64({ksize} + _vf), output)",
            f"            {kwrite}",
            "            encode_tag(2, WIRE_LEN, output)",
            "            encode_varint(UInt64(_vsz), output)",
            "            _e.value.encode_to(output)",
        ]
        sz = [
            f"        for _e in self.{m}.items():",
            "            var _vsz = _e.value.encoded_size()",
            f"            var _entlen = {ksize} + tag_size(2) + "
            "varint_size(UInt64(_vsz)) + _vsz",
            f"            total += tag_size({num}) + varint_size("
            "UInt64(_entlen)) + _entlen",
        ]
    else:
        enc = [
            f"        for _e in self.{m}.items():",
            f"            encode_tag({num}, WIRE_LEN, output)",
            f"            encode_varint(UInt64({ksize} + {vsize}), output)",
            f"            {kwrite}",
        ] + vwrite
        sz = [
            f"        for _e in self.{m}.items():",
            f"            var _entlen = {ksize} + {vsize}",
            f"            total += tag_size({num}) + varint_size("
            "UInt64(_entlen)) + _entlen",
        ]
    encode_items.append((num, enc))
    size_items.append((num, sz))

    decode += [
        f"        if field_number == {num}:",
        f"            var _entry_{m} = read_bytes(data, pos)",
        f"            var _ep_{m} = 0",
        f"            var _k_{m} = {kspec.default}",
        f"            var _v_{m} = {vdefault}",
        f"            while _ep_{m} < len(_entry_{m}):",
        f"                var _efn_{m}, _ewt_{m} = decode_tag("
        f"_entry_{m}, _ep_{m})",
        f"                if _efn_{m} == 1:",
        f"                    _k_{m} = {kspec.read('_entry_' + m, '_ep_' + m)}",
        f"                elif _efn_{m} == 2:",
    ] + vread + [
        "                else:",
        f"                    skip_field(_entry_{m}, _ep_{m}, _ewt_{m})",
        f"            self.{m}[_k_{m}{kmove}] = _v_{m}{vmove}",
    ]


def gen_message(mojo_name, desc, type_map, imports, map_entries):
    """Return the Mojo source for one message struct."""
    fields = list(desc.field)
    for f in fields:
        _check_field(f, map_entries)

    decls, defaults = [], []
    encode_items, size_items, decode = [], [], []
    imports.setdefault("message", set()).add("Message")
    imports.setdefault("fields", set()).add("skip_field")

    for f in fields:
        name = _ident(f.name)
        num = f.number
        optional = bool(f.proto3_optional)

        if _is_map_field(f, map_entries):
            _gen_map_field(f, name, num, map_entries, type_map, imports,
                           decls, defaults, encode_items, size_items, decode)
            continue

        if f.label == FD.LABEL_REPEATED and f.type in PACKED:
            pk = PACKED[f.type]  # _check_field already rejected unsupported
            decls.append(f"    var {name}: List[{pk.elem}]")
            defaults.append(f"        self.{name} = List[{pk.elem}]()")
            _merge_imports(imports, pk.imports)
            _merge_imports(imports, {
                "wire": {"encode_tag", "encode_varint", "WIRE_LEN"},
                "size": {"tag_size", "varint_size"},
                "fields": {"read_bytes"},
            })
            enc = [f"        if len(self.{name}) > 0:"]
            if pk.fixed:
                enc += [
                    f"            encode_tag({num}, WIRE_LEN, output)",
                    f"            encode_varint("
                    f"UInt64({pk.width} * len(self.{name})), output)",
                    f"            for _v in self.{name}:",
                    f"                {pk.vwrite('_v')}",
                ]
                sz = [
                    f"        if len(self.{name}) > 0:",
                    f"            var _n_{name} = {pk.width} * len(self.{name})",
                    f"            total += tag_size({num}) + varint_size("
                    f"UInt64(_n_{name})) + _n_{name}",
                ]
            else:
                enc += [
                    f"            var _n_{name} = 0",
                    f"            for _v in self.{name}:",
                    f"                _n_{name} += {pk.vsize('_v')}",
                    f"            encode_tag({num}, WIRE_LEN, output)",
                    f"            encode_varint(UInt64(_n_{name}), output)",
                    f"            for _v in self.{name}:",
                    f"                {pk.vwrite('_v')}",
                ]
                sz = [
                    f"        if len(self.{name}) > 0:",
                    f"            var _n_{name} = 0",
                    f"            for _v in self.{name}:",
                    f"                _n_{name} += {pk.vsize('_v')}",
                    f"            total += tag_size({num}) + varint_size("
                    f"UInt64(_n_{name})) + _n_{name}",
                ]
            encode_items.append((num, enc))
            size_items.append((num, sz))
            # Accept both the packed (LEN) and non-packed (one tag+value per
            # element) forms on decode, per the proto3 spec. Plain varint ints
            # use the SIMD-accelerated whole-blob helper for the packed case.
            if pk.helper is not None:
                packed = (
                    f"                {pk.helper}("
                    f"read_bytes(data, pos), self.{name})"
                )
            else:
                packed = (
                    f"                var _blob_{name} = read_bytes(data, pos)\n"
                    f"                var _p_{name} = 0\n"
                    f"                while _p_{name} < len(_blob_{name}):\n"
                    f"                    self.{name}.append("
                    f"{pk.vread('_blob_' + name, '_p_' + name)})"
                )
            decode += [
                f"        if field_number == {num}:",
                f"            if wire_type == WIRE_LEN:",
                packed,
                f"            else:",
                f"                self.{name}.append("
                f"{pk.vread('data', 'pos')})",
            ]
            continue

        if f.label == FD.LABEL_REPEATED:
            # Non-packed repeated (string / bytes / message): each element is
            # its own tag+value field, appended on each occurrence.
            if f.type == FD.TYPE_STRING:
                decls.append(f"    var {name}: List[String]")
                defaults.append(f"        self.{name} = List[String]()")
                _merge_imports(imports, {
                    "fields": {"write_string", "read_string"},
                    "size": {"string_field_size"},
                })
                encode_items.append((num, [
                    f"        for ref _e in self.{name}:",
                    f"            write_string({num}, _e, output)",
                ]))
                size_items.append((num, [
                    f"        for ref _e in self.{name}:",
                    f"            total += string_field_size({num}, _e)",
                ]))
                decode += [
                    f"        if field_number == {num}:",
                    f"            self.{name}.append(read_string(data, pos))",
                ]
            elif f.type == FD.TYPE_BYTES:
                decls.append(f"    var {name}: List[List[Byte]]")
                defaults.append(f"        self.{name} = List[List[Byte]]()")
                _merge_imports(imports, {
                    "fields": {"write_bytes", "read_bytes"},
                    "size": {"bytes_field_size"},
                })
                encode_items.append((num, [
                    f"        for ref _e in self.{name}:",
                    f"            write_bytes({num}, Span(_e), output)",
                ]))
                size_items.append((num, [
                    f"        for ref _e in self.{name}:",
                    f"            total += bytes_field_size({num}, Span(_e))",
                ]))
                decode += [
                    f"        if field_number == {num}:",
                    f"            var _b_{name} = List[Byte]()",
                    f"            _b_{name}.extend(read_bytes(data, pos))",
                    f"            self.{name}.append(_b_{name}^)",
                ]
            else:  # TYPE_MESSAGE (map entries already rejected by _check_field)
                mt = _field_mojo_type(f, type_map)
                decls.append(f"    var {name}: List[{mt}]")
                defaults.append(f"        self.{name} = List[{mt}]()")
                _merge_imports(imports, {
                    "wire": {"encode_tag", "encode_varint", "WIRE_LEN"},
                    "size": {"tag_size", "varint_size"},
                    "fields": {"read_bytes"},
                    "message": {"decode"},
                })
                encode_items.append((num, [
                    f"        for ref _e in self.{name}:",
                    f"            encode_tag({num}, WIRE_LEN, output)",
                    f"            encode_varint(UInt64(_e.encoded_size()), "
                    f"output)",
                    f"            _e.encode_to(output)",
                ]))
                size_items.append((num, [
                    f"        for ref _e in self.{name}:",
                    f"            var _sz = _e.encoded_size()",
                    f"            total += tag_size({num}) + varint_size("
                    f"UInt64(_sz)) + _sz",
                ]))
                decode += [
                    f"        if field_number == {num}:",
                    f"            self.{name}.append("
                    f"decode[{mt}](read_bytes(data, pos)))",
                ]
            continue

        if f.type == FD.TYPE_MESSAGE:
            mt = _field_mojo_type(f, type_map)
            decls.append(f"    var {name}: {mt}")
            defaults.append(f"        self.{name} = {mt}()")
            acc = f"self.{name}"
            encode_items.append((num, [
                f"        encode_tag({num}, WIRE_LEN, output)",
                f"        encode_varint(UInt64({acc}.encoded_size()), output)",
                f"        {acc}.encode_to(output)",
            ]))
            size_items.append((num, [
                f"        var _sz_{name} = {acc}.encoded_size()",
                f"        total += tag_size({num}) + varint_size("
                f"UInt64(_sz_{name})) + _sz_{name}",
            ]))
            decode += [
                f"        if field_number == {num}:",
                f"            self.{name} = decode[{mt}](read_bytes(data, pos))",
            ]
            _merge_imports(imports, {
                "wire": {"encode_tag", "encode_varint", "WIRE_LEN"},
                "size": {"tag_size", "varint_size"},
                "fields": {"read_bytes"},
                "message": {"decode"},
            })
            continue

        if _is_bytes(f):
            mt = "List[Byte]"
            _merge_imports(imports, {
                "fields": {"write_bytes", "read_bytes"},
                "size": {"bytes_field_size"},
            })
            if optional:
                decls.append(f"    var {name}: Optional[{mt}]")
                defaults.append(f"        self.{name} = None")
                v = f"self.{name}.value()"
                encode_items.append((num, [
                    f"        if self.{name}:",
                    f"            write_bytes({num}, Span({v}), output)",
                ]))
                size_items.append((num, [
                    f"        if self.{name}:",
                    f"            total += bytes_field_size({num}, Span({v}))",
                ]))
                decode += [
                    f"        if field_number == {num}:",
                    f"            var _b_{name} = List[Byte]()",
                    f"            _b_{name}.extend(read_bytes(data, pos))",
                    f"            self.{name} = Optional[{mt}](_b_{name}^)",
                ]
            else:
                decls.append(f"    var {name}: {mt}")
                defaults.append(f"        self.{name} = {mt}()")
                encode_items.append((num, [
                    f"        write_bytes({num}, Span(self.{name}), output)"]))
                size_items.append((num, [
                    f"        total += bytes_field_size({num}, "
                    f"Span(self.{name}))"]))
                decode += [
                    f"        if field_number == {num}:",
                    f"            var _b_{name} = List[Byte]()",
                    f"            _b_{name}.extend(read_bytes(data, pos))",
                    f"            self.{name} = _b_{name}^",
                ]
            continue

        spec = SCALAR.get(f.type)
        if spec is None:
            _field_mojo_type(f, type_map)  # raises a precise GenError
            raise GenError(f"field '{f.name}': unsupported proto type {f.type}")
        _merge_imports(imports, spec.imports)
        if optional:
            decls.append(f"    var {name}: Optional[{spec.mojo}]")
            defaults.append(f"        self.{name} = None")
            v = f"self.{name}.value()"
            encode_items.append((num, [
                f"        if self.{name}:",
                f"            {spec.write(num, v)}",
            ]))
            size_items.append((num, [
                f"        if self.{name}:",
                f"            total += {spec.size(num, v)}",
            ]))
            decode += [
                f"        if field_number == {num}:",
                f"            self.{name} = Optional[{spec.mojo}]("
                f"{spec.read()})",
            ]
        else:
            decls.append(f"    var {name}: {spec.mojo}")
            defaults.append(f"        self.{name} = {spec.default}")
            encode_items.append(
                (num, [f"        {spec.write(num, f'self.{name}')}"]))
            size_items.append(
                (num, [f"        total += {spec.size(num, f'self.{name}')}"]))
            decode += [
                f"        if field_number == {num}:",
                f"            self.{name} = {spec.read()}",
            ]

    # Emit fields on the wire in ascending field-number order (canonical), even
    # if the .proto declares them out of order.
    encode = [ln for _, blk in sorted(encode_items, key=lambda kv: kv[0])
              for ln in blk]
    size = [ln for _, blk in sorted(size_items, key=lambda kv: kv[0])
            for ln in blk]

    # Turn the per-field decode `if` blocks into an elif chain + skip default.
    decode_body = []
    for line in decode:
        if line.lstrip().startswith("if field_number ==") and decode_body:
            decode_body.append("        elif" + line.lstrip()[2:])
        else:
            decode_body.append(line)
    if decode_body:
        decode_body += [
            "        else:",
            "            skip_field(data, pos, wire_type)",
        ]
    else:
        decode_body = ["        skip_field(data, pos, wire_type)"]

    lines = []
    has_fields = bool(fields)
    if has_fields:
        lines.append("@fieldwise_init")
    # Copyable so messages can be held in a `List` (repeated message fields) and
    # copied like the value types they are; the encode path still reads by `ref`.
    lines.append(f"struct {mojo_name}(Message, Copyable):")
    lines += decls if decls else []
    lines.append("")
    lines.append("    def __init__(out self):")
    lines += defaults if defaults else ["        pass"]
    lines.append("")
    lines.append("    def encoded_size(self) -> Int:")
    lines.append("        var total = 0")
    lines += size
    lines.append("        return total")
    lines.append("")
    lines.append("    def encode_to(self, mut output: List[Byte]):")
    lines += encode if encode else ["        pass"]
    lines.append("")
    lines.append("    def merge_field(")
    lines.append("        mut self,")
    lines.append("        field_number: Int,")
    lines.append("        wire_type: Int,")
    lines.append("        data: Span[Byte, _],")
    lines.append("        mut pos: Int,")
    lines.append("    ) raises:")
    lines += decode_body
    return "\n".join(lines)


def _imports_block(imports):
    out = []
    for mod in ("message", "wire", "fields", "size"):
        names = imports.get(mod)
        if not names:
            continue
        joined = ", ".join(sorted(names))
        out.append(f"from protobuf.{mod} import {joined}")
    return "\n".join(out)


def _enum_constants(fd, package):
    """Return each enum's named values as `(constant_name, number)` pairs.

    The constant for value `V` of enum `E` is `<E>_V` with the enum name
    flattened the same way as nested messages (`Outer_Inner`). Covers top-level
    and nested enums.
    """
    prefix = "." + package if package else "."
    consts = []

    def emit(enums, scope):
        for e in enums:
            flat = _struct_name(f"{scope}.{e.name}", prefix)
            for v in e.value:
                consts.append((f"{flat}_{v.name}", v.number))

    def walk(msgs, scope):
        for m in msgs:
            if m.options.map_entry:  # synthetic; skipped like _collect_messages
                continue
            full = f"{scope}.{m.name}"
            emit(m.enum_type, full)
            walk(m.nested_type, full)

    scope = "." + package if package else ""
    emit(fd.enum_type, scope)
    walk(fd.message_type, scope)
    return consts


def gen_file(fd):
    """Generate the .mojo source for one FileDescriptorProto."""
    # protoc leaves `syntax` empty for proto2, so require proto3 explicitly
    # rather than only rejecting a non-empty non-proto3 value.
    if fd.syntax != "proto3":
        got = fd.syntax or "proto2"
        raise GenError(f"{fd.name}: only proto3 is supported (got {got})")

    package = fd.package
    type_map = {}
    ordered = []
    map_entries = {}
    scope = "." + package if package else ""
    _collect_messages(
        fd.message_type, scope, package, type_map, ordered, map_entries
    )

    imports = {}
    bodies = [
        gen_message(mojo, desc, type_map, imports, map_entries)
        for mojo, desc in ordered
    ]

    enums = _enum_constants(fd, package)
    # An enum constant must collide with neither a generated struct name nor
    # another constant, or the module would not compile. Fail loudly here rather
    # than emit broken Mojo (e.g. enum `A.B` value `C` and enum `A_B` value `C`
    # both flatten to `A_B_C`).
    struct_names = {mojo for mojo, _ in ordered}
    seen = set()
    for name, _ in enums:
        if name in struct_names:
            raise GenError(
                f"enum constant '{name}' collides with a generated struct name;"
                " rename the enum or value to disambiguate"
            )
        if name in seen:
            raise GenError(
                f"enum constant '{name}' is generated by two enums; rename one"
                " to disambiguate"
            )
        seen.add(name)

    header = (
        f'"""Generated by protoc-gen-mojo from {fd.name}. Do not edit."""\n\n'
        + _imports_block(imports)
        + "\n\n\n"
    )
    if enums:
        lines = [f"comptime {name} = Int32({num})" for name, num in enums]
        header += "\n".join(lines) + "\n\n\n"
    return header + "\n\n\n".join(bodies) + "\n"


def main():
    request = plugin_pb2.CodeGeneratorRequest.FromString(sys.stdin.buffer.read())
    response = plugin_pb2.CodeGeneratorResponse()
    response.supported_features = (
        plugin_pb2.CodeGeneratorResponse.FEATURE_PROTO3_OPTIONAL
    )

    by_name = {f.name: f for f in request.proto_file}
    for proto_name in request.file_to_generate:
        fd = by_name[proto_name]
        try:
            content = gen_file(fd)
        except GenError as e:
            response.error = f"{proto_name}: {e}"
            sys.stdout.buffer.write(response.SerializeToString())
            return
        out = response.file.add()
        out.name = proto_name[:-len(".proto")] + ".mojo" \
            if proto_name.endswith(".proto") else proto_name + ".mojo"
        out.content = content

    sys.stdout.buffer.write(response.SerializeToString())


if __name__ == "__main__":
    main()
