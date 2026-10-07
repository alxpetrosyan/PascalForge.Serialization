# BSON behaviour

How the BSON engine maps Delphi values to and from BSON. This document covers
**BSON only** — JSON and XML have their own rules and their own attributes;
see [`serializer-behavior.md`](serializer-behavior.md) and
[`xml-behavior.md`](xml-behavior.md).

*Which* BSON — the element-type ledger, the security audit, and the evidence
against the specification's own byte vectors — is in
[`bson-compatibility.md`](bson-compatibility.md).

Ownership is defined once, for every format, in
[`deserialization-ownership.md`](deserialization-ownership.md).

BSON is a real engine. Bytes are written and read directly; nothing routes
through JSON text, through XML, or through the dynamic tree. That matters more
here than anywhere else: routing through a text format would destroy every
distinction BSON exists to keep.

## The bytes

```pascal
Data    := TBsonSerializer.Serialize<TShipment>(Shipment);   // TBytes
Shipment := TBsonSerializer.Deserialize<TShipment>(Data);
TBsonSerializer.Populate<TShipment>(Existing, Data);
```

BSON is binary, so its natural Delphi type is `TBytes` and that is what the
API returns. There is no base64 API pretending otherwise: a caller who wants
base64 can encode the bytes, and a caller who does not should never have to
pay for it.

## What is implemented

| BSON element | Delphi |
| --- | --- |
| `0x01` double | `Single`, `Double`, `Extended` |
| `0x02` string | `string`, enumerations, sets |
| `0x03` document | a class, a record, a dictionary |
| `0x04` array | a list, a dynamic array |
| `0x05` binary | `TBytes` (subtype 0), `TGUID` (subtype 4) |
| `0x08` boolean | `Boolean` and friends |
| `0x09` datetime | `TDateTime` |
| `0x0A` null | an explicit null on read |
| `0x10` int32 | every integer width up to 32 bits |
| `0x12` int64 | `Int64`, and `Currency` by default |
| `0x07` ObjectId | **`TBsonObjectId`** |

**Every element type the specification defines is read and written.** The
table above is the ones with a natural Delphi counterpart; the remaining
eleven — timestamp, decimal128, regular expression, JavaScript, JavaScript
with scope, symbol, undefined, DBPointer, min key, max key, and binary with
an unusual subtype — have none, so they are carried exactly and reached
through `TBsonValue`, directly or through a typed custom serializer. The full
ledger is in [`bson-compatibility.md`](bson-compatibility.md).

A type byte the specification does **not** define is refused by name rather
than skipped:

```
The BSON element "x" has type byte 0x63, which the BSON specification does
not define. ... It is reported rather than skipped: a value that arrives as
the wrong type is worse than one that does not arrive.
```

Two of the eleven are worth knowing about before you meet them.

**A BSON timestamp is not a datetime.** It is a MongoDB-internal value —
seconds in the high 32 bits, a per-second increment in the low 32 — and it is
carried as the raw `UInt64`. Turning one into a `TDateTime` would produce a
plausible date that means something else.

**A decimal128 is carried, not interpreted.** Delphi has no 128-bit decimal,
so the sixteen bytes round trip exactly and no arithmetic is offered.

## Numbers

Numeric fidelity is the reason to choose BSON, so nothing goes through
`Double` on the way:

- an integer member up to 32 bits wide → **int32**;
- an `Int64` member → **int64**, even when its current value would fit in 32
  bits. The *contract* is 64-bit, and narrowing on the strength of one small
  value would make the wire type depend on the data;
- a float member → **double**.

On read, a double is accepted where an integer is expected only when it is
exactly integral; otherwise it raises rather than rounding silently.

### Currency

BSON has no fixed-point type, so this is a decision rather than a translation.
Three representations, selectable per member with
`[BsonCurrencyRepresentation(...)]`:

| representation | wire | exact? |
| --- | --- | --- |
| `ScaledInt64` *(default)* | int64 | **yes** |
| `Double` | double | no, beyond 15 significant digits |
| `DecimalString` | string | yes |

`Currency` **is** a scaled `Int64` in Delphi — the value times 10 000 — so
writing that integer is exact in both directions and costs nothing. A double
would have lost precision on large values; Decimal128 is out of scope for this
version, and `ScaledInt64` is the safe alternative rather than a silent
downgrade.

## GUID

Binary, subtype 4 — the standard UUID subtype, which is what a BSON consumer
expects — in RFC 4122 byte order, the order the text reads:
`{73FFD264-44B3-4C69-90E8-E7D1DFC035D4}` is `73 FF D2 64 44 B3 4C 69 …`, as
the bson-corpus `subtype 0x04 UUID` vector, mongosh and the drivers have it.
Sixteen bytes under the legacy subtype 3 are read in `TGUID`'s memory layout.
Before 0.9.0 a `TGUID` was written in its memory layout under subtype 4, so
such a document now reads back as a different GUID - D1, D2 and D3
byte-swapped. JSON's lowercase-string rule is **not** inherited.
`[BsonGuidRepresentation(TBsonGuidRepresentation.LowercaseString)]` selects
the 36-character string for a consumer that insists on one. JSON's, XML's and
BSON's GUID policies are independent.

## Date and time

| Delphi | BSON, by default |
| --- | --- |
| `TDateTime` | **native BSON datetime** — milliseconds since the Unix epoch |
| `TDate` | ISO 8601 string — `2026-03-14` |
| `TTime` | ISO 8601 string — `17:30:00` |

`TDate` and `TTime` are **not instants**. A date has no time of day and a time
has no day, so writing either as a BSON datetime would claim a point in time
neither of them has. They get strings instead, and the choice is documented
rather than silently made.

A `TDateTime` is taken as the instant it states; nothing is shifted, because a
`TDateTime` carries no zone and inventing one would make the value depend on
where the process runs. That includes an instant before 1899-12-30 with a
time of day, which Delphi encodes as a negative day and a positive time.
`UnixSeconds` writes the second an instant falls in, rounded toward the past.
A `TDateTime` or `TDate` outside the years 1 to 9999 is refused on write with
`ESerializationUnsupported`, in every representation: no reader here reads
one back.

Representation is configurable per member, per field, per type and globally —
`Native`, `StringIso8601`, `UnixSeconds`, `UnixMilliseconds`, `CustomString` —
independently of JSON's and XML's. See
[`datetime-policies.md`](datetime-policies.md).

## Naming, presence and absence

- Member name: the Delphi member name, or `[BsonName('_id')]`.
- `[BsonIgnore]` removes the member from both directions.
- A nullable with no value is **omitted**, not written as BSON null.
- A `nil` object, list or dictionary is **omitted**.
- An absent element leaves the member as it was, so a document from a newer
  or older producer still deserializes.
- An explicit BSON null **detaches** an object member without freeing it.

## The root

A BSON document is the only thing that can be a root — the format has no
top-level array or scalar. A root that is not a document therefore travels
under the name `value`, and reading applies the same rule, so it round-trips:

```pascal
Data := TBsonSerializer.Serialize<Integer>(42);   // { "value": 42 }
```

A class, a record and a dictionary are documents already and are written as
themselves.

## Enumerations, sets and collections

- Enumeration: the RTTI name, or `TBsonSerializer.RegisterEnumMapping<T>`'s
  value. BSON's mapping table is its own.
- Set: a comma-separated string.
- List and dynamic array: a BSON array. Recognition is by RTL class ancestry.
- Dictionary: a BSON document, so the key must have a text form — a string, an
  integer, an enumeration or a GUID. Anything else is refused when the plan is
  built.
- A container that already exists is **reused**: cleared, then refilled.

## Custom serializers

```pascal
TTypeSerializer = class(TCustomBsonValueSerializer<TCoordinate>)
  function SerializeValue(const AValue: TCoordinate): TBsonValue; override;
  function DeserializeValue(AValue: TBsonValue; const AExisting: TCoordinate): TCoordinate; override;
end;
```

A custom BSON serializer returns a `TBsonValue`, so it can use any element
type the format has. `[BsonSerializer(TSomething)]` names one for a single
member; `RegisterTypeSerializer<T>` covers every value of a type. A BSON
serializer is BSON's and does not become a JSON or XML one.

## Structural conversion

BSON states its types, so the dynamic tree keeps them: an int32 stays an
integer, a BSON datetime stays a `DateTime`, binary stays `Bytes`. Converting
BSON to JSON structurally therefore preserves numbers as numbers — unlike
converting XML, whose element text carries no type at all. See
[`conversion.md`](conversion.md).

**BSON is the destination that never needs a policy.** Its own types cover
every dynamic kind and a BSON member name is an arbitrary string, so there is
no name to encode and no value to adapt: `$type` arrives in BSON as `$type`,
and `Natural`, `Lossless` and `Strict` produce identical bytes. Name
adaptation belongs to the destination that cannot spell the name, and this
one can.

Going the other way, BSON's binary and datetime are exactly what JSON and XML
lack, so BSON documents are the fixtures that exercise the value policy:
`Natural` writes base64 and ISO-8601 text, `Lossless` writes MongoDB
Extended JSON - a published standard rather than a convention of this
library's - and `Strict` refuses with the member path. The three dedicated
APIs are `ToJson`, `ToJsonWithSchema` and `ToExtendedJson`; see
[`bson-compatibility.md`](bson-compatibility.md).

**BSON does not accept a text source.** Handing it a string raises rather than
encoding the string to UTF-8 and parsing it — those bytes are not a document,
and treating them as one reads the first four characters as a length. Pass
`TBytes`, or `TSerializationPayload.FromBytes`.

## Errors

`EBsonError` and its descendants: `EBsonInputError` for bytes at fault,
`EBsonInternalError` for a model or configuration at fault, and
`EBsonUnsupportedType` for a valid BSON element this version does not
implement. Every read is bounds-checked against both the length the document
declares and the buffer it is in, so a truncated or lying document fails with
a message naming the byte offset rather than reading past its end - a
declared length near `High(Integer)` included. A container that refuses an
element the document holds - a sorted `TStringList` with `dupError` - is an
`EBsonInputError` naming the container class.

On write: `WriteDocument` raises `EBsonInternalError` for a nil tree, a nil
element, or nesting past 512; an unpaired UTF-16 surrogate in any text and a
date outside the years 1 to 9999 raise `ESerializationUnsupported`; a value
nested past 64 levels raises `ESerializationLimitExceeded`.
