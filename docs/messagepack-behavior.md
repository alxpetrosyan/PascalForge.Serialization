# MessagePack behaviour

How the MessagePack engine maps Delphi values to and from MessagePack, as
defined by the [MessagePack specification](https://github.com/msgpack/msgpack/blob/master/spec.md).
This document covers **MessagePack only**; see
[`serializer-behavior.md`](serializer-behavior.md),
[`xml-behavior.md`](xml-behavior.md), [`bson-behavior.md`](bson-behavior.md)
and [`cbor-behavior.md`](cbor-behavior.md) for the others.

Ownership is defined once, for every format, in
[`deserialization-ownership.md`](deserialization-ownership.md).

MessagePack is a real engine. Every byte is produced from the format table.
There is no shared binary layer with BSON or CBOR, because the three
disagree about almost everything they appear to have in common — the order of
a length, the width of an integer, whether a map key may be a number.

## The bytes

```pascal
Data    := TMessagePackSerializer.Serialize<TShipment>(Shipment);   // TBytes
Shipment := TMessagePackSerializer.Deserialize<TShipment>(Data);
TMessagePackSerializer.Populate<TShipment>(Existing, Data);
```

And, with no contract:

```pascal
Value := TMessagePackSerializer.Parse(Data);   // the caller owns it
Data  := TMessagePackSerializer.Write(Value);
```

## The format table

Every first byte is written and read. The table below is the ledger
`tests/MessagePackNative` prints, which is the specification's own table in
its own order.

| Family | First byte | Family | First byte |
| --- | --- | --- | --- |
| positive fixint | `0x00`–`0x7f` | fixext 1 | `0xd4` |
| fixmap | `0x80`–`0x8f` | fixext 2 | `0xd5` |
| fixarray | `0x90`–`0x9f` | fixext 4 | `0xd6` |
| fixstr | `0xa0`–`0xbf` | fixext 8 | `0xd7` |
| nil | `0xc0` | fixext 16 | `0xd8` |
| *(never used)* | `0xc1` | str 8 | `0xd9` |
| false | `0xc2` | str 16 | `0xda` |
| true | `0xc3` | str 32 | `0xdb` |
| bin 8, 16, 32 | `0xc4`–`0xc6` | array 16, 32 | `0xdc`, `0xdd` |
| ext 8, 16, 32 | `0xc7`–`0xc9` | map 16, 32 | `0xde`, `0xdf` |
| float 32, 64 | `0xca`, `0xcb` | negative fixint | `0xe0`–`0xff` |
| uint 8, 16, 32, 64 | `0xcc`–`0xcf` | | |
| int 8, 16, 32, 64 | `0xd0`–`0xd3` | | |

### `0xc1`

The specification marks `0xc1` as never used. It is not a reserved extension
point to be skipped politely: a document containing it is not MessagePack.
Meeting it raises `EMessagePackReservedByte`, which carries the **offset** so
the caller can see where the stream stopped making sense.

### Shortest form on write, any form on read

A writer picks the smallest encoding that holds the value — `7` is a positive
fixint, not a `uint 64`. A reader accepts every encoding of every value,
because other implementations make different choices and all of them are
conforming.

One deliberate exception: a `Single` is written as `float 32` and stays a
`float 32`. Widening it to `float 64` would suggest precision that is not
there.

## str and bin are different types

MessagePack separated them in its 2013 revision, and the distinction is the point:

* **str** is text. It is UTF-8 on the wire, and it is validated. Bytes that
  are not well-formed UTF-8 raise `EMessagePackInvalidUtf8`, which names both
  the offset and the reason.
* **bin** is bytes. Nothing interprets them.

A Delphi `string` is always a str; `TBytes` is always a bin. Neither is ever
silently reinterpreted as the other.

## Extensions

An extension is a signed type code and a byte payload:

```pascal
Value := TMessagePackValue.NewExtension(42, SomeBytes);
Code  := Value.ExtensionType;   // Shortint: -128..127
```

Negative codes are reserved by the specification. Exactly one is defined:

### The timestamp extension, type −1

All three of its encodings are written and read:

| Encoding | Bytes | Range |
| --- | --- | --- |
| timestamp 32 | fixext 4 (`0xd6`) | seconds since the epoch, 1970–2106, no nanoseconds |
| timestamp 64 | fixext 8 (`0xd7`) | 34-bit seconds and 30-bit nanoseconds |
| timestamp 96 | ext 8 (`0xc7`) | 64-bit signed seconds and 32-bit nanoseconds |

A writer uses the **smallest of the three that is exact**. A reader takes
whichever arrives.

`TMessagePackKind.Timestamp` is a kind in its own right rather than an
`Extension` carrying a flag, because a consumer asking "is this a point in
time" should not have to know the number −1.

## Integers

`TMessagePackKind.Int` covers `-(2^63) .. High(Int64)` and
`TMessagePackKind.UInt` covers **only** `High(Int64)+1 .. 2^64-1`. Everything
an `Int64` can hold is `Int`, so a consumer testing for `Int` is never
surprised by a small number that happened to arrive in a `uint 32`.

## Malformed input, refused by name

| Exception | Raised for |
| --- | --- |
| `EMessagePackReservedByte` | `0xc1`, with the offset |
| `EMessagePackInvalidUtf8` | a str that is not well-formed UTF-8, with the offset and the reason |
| `EMessagePackDepthExceeded` | nesting past the limit, with the limit |
| `EMessagePackInputError` | truncation, a length or count the remaining bytes cannot satisfy, a timestamp outside the years a `TDateTime` holds when it is read into a `TDateTime` member (structurally it stays a type -1 extension), and a container that refuses an element the document holds (a sorted `TStringList` with `dupError`), named by class |

A declared length that the document cannot possibly contain is rejected
**before** any allocation, so a four-byte file claiming a four-gigabyte string
fails immediately rather than exhausting memory.

## The Delphi contract

| Delphi | MessagePack, by default |
| --- | --- |
| `Boolean` | `true` / `false` |
| every integer width | the smallest int or uint family that holds it |
| `UInt64` above `High(Int64)` | `uint 64` |
| `Single` | `float 32` |
| `Double`, `Extended` | `float 64` |
| `Currency` | the scaled integer Delphi stores — value times 10 000 |
| `string` | str |
| `TBytes` | bin |
| `TDateTime` | timestamp extension −1 |
| `TDate`, `TTime` | ISO 8601 str — they are not instants |
| `TGUID` | the canonical lower-case 36-character str |
| an enumeration | its member name, as a str |
| a class or record | a map with str keys |
| a list or dynamic array | an array |
| a dictionary | a map |
| `TNullable<T>` with no value | **absent** from the map, not `nil` |

The last row is the same rule JSON, XML, BSON and CBOR follow: "the member is
not there" and "the member is there and is null" are different statements.

### Attributes

MessagePack reads only MessagePack's own attributes.

```pascal
type
  TShipment = class
  public
    [MessagePackName('ref')] Reference: string;
    [MessagePackIgnore] Scratch: string;
    [MessagePackDateTimeRepresentation(
       TMessagePackDateTimeRepresentation.UnixMilliseconds)] Issued: TDateTime;
    [MessagePackCurrencyRepresentation(
       TMessagePackCurrencyRepresentation.DecimalString)] Amount: Currency;
    [MessagePackGuidRepresentation(TMessagePackGuidRepresentation.Bin)] Id: TGUID;
    [MessagePackEnumRepresentation(
       TMessagePackEnumRepresentation.Ordinal)] Status: TStatus;
    [MessagePackSerializer(TMyMoneySerializer)] Odd: TMoney;
  end;
```

| Attribute | Choices |
| --- | --- |
| `MessagePackName` | the map key to use |
| `MessagePackIgnore` | never written, never read |
| `MessagePackDateTimeRepresentation` | `Timestamp`, `StringIso8601`, `UnixSeconds`, `UnixMilliseconds`, `CustomString`. `UnixSeconds` writes the second an instant falls in, rounded toward the past; the timestamp's nanoseconds are never negative. A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write (`ESerializationUnsupported`) in every representation |
| `MessagePackGuidRepresentation` | `LowercaseString`, `Bin` |
| `MessagePackCurrencyRepresentation` | `ScaledInt64`, `Float64`, `DecimalString` |
| `MessagePackEnumRepresentation` | `Name`, `Ordinal` |
| `MessagePackSerializer` | a `TCustomMessagePackValueSerializer<T>` descendant |

`Currency` defaults to `ScaledInt64` because that is exactly what Delphi
stores and it is exact in both directions. `Float64` is offered for consumers
that expect a number and is lossy past fifteen significant digits.

## Structural conversion

MessagePack declares all four capabilities with nothing supplied. It is
self-describing.

```pascal
Payload := TSerialization.Convert(Source, TSerializationFormat.Json,
             TSerializationFormat.MessagePack);
```

* nil, booleans, ints, uints, floats, str, bin, arrays and maps map onto the
  dynamic kinds directly;
* a `uint 64` above `High(Int64)` becomes `TDynamicKind.UInt`;
* a timestamp becomes `TDynamicKind.DateTime`;
* any **other** extension becomes `TDynamicTag.MsgPackExtension`, an object of
  `type` (Int) and `data` (Bytes), so a destination that cannot express it
  refuses by name rather than dropping it;
* a map with non-str keys: under the `Encode` name policy (`Natural`,
  `Lossless`) an int, uint, bool or nil key becomes its text, and under
  `Strict` it is refused; a float, bin, array or map key is always refused,
  by the MessagePack side, with the member path.

## What is proven, and how

`tests/MessagePackNative` runs **197 checks**.

The independent reference is the specification's format table, and the ledger
the test prints walks it first byte by first byte — every family above,
including the `0xc1` that must never appear, all five ext widths, all three
timestamp encodings, and the boundaries where one integer width gives way to
the next.

Byte sequences that can be computed by hand from the table are written out in
hex in the test and compared literally.

## Not implemented, and why

* **The pre-2013 raw family**, in which str and bin were one type. This
  library writes and reads the current specification only. A document from
  the old one has its `0xd9`–`0xdb` bytes read as str, which is what they now
  mean — and a document that used them for binary data will fail UTF-8
  validation rather than produce mojibake.
