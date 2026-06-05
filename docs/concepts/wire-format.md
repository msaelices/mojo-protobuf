# The protobuf wire format

Protocol Buffers ("protobuf") is a binary format for serializing structured
data. This page explains the **lowest layer** — how individual bytes encode
values. It's the foundation everything else is built on, and it's almost all
plain bit-twiddling. Official spec:
<https://protobuf.dev/programming-guides/encoding/>.

## The mental model: a message is a list of `(tag, value)` pairs

A serialized protobuf message is just a flat sequence:

```
[tag][value][tag][value]...
```

Each **tag** says *which field* this is and *how to read* the value that
follows. Crucially, **field names never appear on the wire — only field
numbers.** That's why you need the schema (a `.proto` file) to turn a decoded
message back into named fields. The primitives on this page deal only with the
numbers and raw values; schema handling comes later in the project.

## 1. Varint — variable-length integers

A 64-bit integer doesn't always need 8 bytes. Protobuf encodes integers in
**1–10 bytes** so that small numbers are cheap. The rules:

- Each byte stores **7 bits** of the number.
- Groups are emitted **least-significant first** (little-endian).
- The **high bit (`0x80`) of each byte is a continuation flag**: `1` means "more
  bytes follow", `0` means "this is the last byte".

### Worked example: encoding `150`

```
150            = 0b1001 0110
low 7 bits     = 0010110  -> more bits remain, set continuation -> 0x96
150 >> 7 = 1   = 0000001  -> no more bits, leave flag clear     -> 0x01
result         = [0x96, 0x01]
```

Decoding reverses this: read 7-bit groups, shifting each into place, until you
hit a byte with the continuation flag clear.

Two failure cases the decoder must reject:

- **Truncated**: the buffer ends while a continuation bit is still set.
- **Overlong / malformed**: more than 64 bits worth of groups arrive.

## 2. ZigZag — making negative numbers cheap

Plain two's-complement negatives have their top bit set, so `-1` is
`0xFFFF…FF`. As a varint that's the worst case: **10 bytes**. To avoid paying
that for every small negative number, the `sint32`/`sint64` types first apply
**ZigZag**, which interleaves positives and negatives so small magnitudes stay
small:

```
value:    0   -1    1   -2    2   -3   ...
encoded:  0    1    2    3    4    5   ...
```

Now `-1` encodes as `1` (one byte). The encode/decode are standard bit formulas
and are exact inverses across the whole range, including `Int64.MIN`/`MAX`.

## 3. Field tags and wire types

The **tag** packs the field number and a 3-bit **wire type** into a single
varint:

```
tag = (field_number << 3) | wire_type
```

The wire type tells the decoder *how many bytes the value is and how to read
them* — without it, a decoder couldn't skip past an unknown field:

| Wire type | Constant | How the value is read | Example field types |
|---|---|---|---|
| `0` | `WIRE_VARINT` | a varint | int32/64, uint32/64, bool, enum, sint* |
| `1` | `WIRE_I64` | exactly 8 bytes, little-endian | fixed64, sfixed64, double |
| `2` | `WIRE_LEN` | a varint *length*, then that many bytes | string, bytes, sub-messages, packed repeated |
| `5` | `WIRE_I32` | exactly 4 bytes, little-endian | fixed32, sfixed32, float |

(Wire types `3` and `4` were the deprecated "group" encoding and are not used.)

## Where this lives in the code

| Concept | Code in `src/protobuf/wire.mojo` |
|---|---|
| Varint | `encode_varint`, `decode_varint` |
| ZigZag | `zigzag_encode`, `zigzag_decode` |
| Tags / wire types | `encode_tag`, `decode_tag`, `WIRE_*` constants |
| Fixed 32/64 | `encode_fixed32`/`64`, `decode_fixed32`/`64` |
| Length-delimited | `encode_bytes`, `decode_bytes` |

## Implementation status

| Layer | Status |
|---|---|
| Varint, ZigZag, tags | ✅ implemented |
| `WIRE_I32` / `WIRE_I64` value codecs (`encode_fixed32`/`64`, `decode_fixed32`/`64`) | ✅ implemented |
| `WIRE_LEN` value codec (`encode_bytes`/`decode_bytes`, length-prefixed; zero-copy view on decode) | ✅ implemented |
| Message API (typed structs, full encode/decode) | ⏳ next |
| `.proto` → Mojo code generation | 🔜 later |

## How to review code that uses this

You don't need protobuf expertise — review it as plain algorithms:

- Check the bit operations (shifts, masks, the continuation flag) against the
  rules above.
- Check that each `encode_*` and `decode_*` pair are exact inverses (the
  round-trip tests assert this).
- Check the edge cases: truncated input, overlong varint, min/max values.
- Sanity-check against the spec using the `150 -> [0x96, 0x01]` example, which
  is asserted in the tests.
