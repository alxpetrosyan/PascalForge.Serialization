# Protobuf behaviour

How the protobuf engine maps Delphi values to and from Protocol Buffers.
This document covers **protobuf only** — JSON, XML and BSON have their own
rules and their own attributes.

*Which* protobuf — the wire-format ledger, the security audit, and the
evidence against the specification's published byte vectors — is in
[`protobuf-compatibility.md`](protobuf-compatibility.md).

The OTHER schema — protoc's own `FileDescriptorSet`, which makes structural
conversion, cross-format conversion and DataSet projection possible with no
Delphi type at all — is in
[`protobuf-descriptors.md`](protobuf-descriptors.md).

Ownership is defined once, for every format, in
[`deserialization-ownership.md`](deserialization-ownership.md).

---

## The one thing that is different

**Protobuf has no names on the wire.** A message is a sequence of (field
number, wire type, payload), and nothing in the bytes says whether a
length-delimited field is a string, a byte array, a nested message or a
packed repeated field.

So every member that is to be serialized needs a number, and a member
without one is simply not serialized — there is no name to fall back on:

```pascal
type
  TShipment = class
  public
    [ProtoField(1)] Id: Int64;
    [ProtoField(2)] Reference: string;
    [ProtoField(3)] Amount: Currency;
    [ProtoField(4)] Lines: TObjectList<TLine>;

    [ProtoIgnore]   Cached: string;   // explicit
    Scratch: string;                  // no number, so the same thing
  end;
```

Two members claiming one number is an error when the plan is built, not a
silent overwrite at run time. So is a number outside 1..536870911, and so is
one in the 19000..19999 range the specification reserves for itself.

**And so is a class that has members and numbers none of them.** Leaving a
member out is how a caller keeps it off the wire; leaving *every* member out
produces a message of zero bytes, which reads back as a default-constructed
object. The round trip loses the entire document and reports success — the
worst failure a serializer has, because it is silent and total. So it is
refused where the mistake was made, at the type:

```text
TCreate has members but not one of them carries [ProtoField], so a Protobuf
message built from it would be empty and the round trip would lose
everything. Number the members that belong on the wire, or mark them
[ProtoIgnore] to say the emptiness is intended.
```

A class with no members at all, and a class whose members are all
`[ProtoIgnore]`, still write an empty message — both of those are a decision
rather than an omission.

**The root must be a message.** Protobuf has no top-level scalar and no
top-level array, so `Serialize<Integer>` and `Serialize<TArray<T>>` raise
rather than inventing a wrapper.

---

## Scalars

`Auto` — the default — picks the obvious `.proto` type:

| Delphi | .proto | wire type |
| --- | --- | --- |
| `Boolean`, `ByteBool`, … | `bool` | varint |
| `ShortInt`…`Integer` | `int32` | varint |
| `Byte`, `Word`, `Cardinal`, and an unsigned subrange above `High(Integer)` (`3000000000..4000000000`) | `uint32` | varint |
| `Int64` | `int64` | varint |
| `UInt64` | `uint64` | varint |
| `Single` | `float` | fixed32 |
| `Double`, `Extended` | `double` | fixed64 |
| `Currency` | `sint64`, **scaled** | varint |
| `string` | `string`, UTF-8 | length-delimited |
| `TBytes` | `bytes` | length-delimited |
| `TGUID` | `bytes`, 16 of them | length-delimited |
| enumeration | the enum's number | varint |
| `TDateTime` | `google.protobuf.Timestamp` | length-delimited |
| `TDate`, `TTime` | `string`, ISO 8601 | length-delimited |
| set | packed repeated enum | length-delimited |
| class, record | a nested message | length-delimited |
| `TList<T>` and descendants, `TArray<T>` | repeated | — |
| `TDictionary<K,V>` and descendants | `map<K,V>` | — |

`[ProtoType]` overrides the scalar, and there are two reasons to:

```pascal
[ProtoField(3), ProtoType(TProtoScalar.SInt64)] Delta: Int64;
[ProtoField(4), ProtoType(TProtoScalar.Fixed64)] Hash: UInt64;
```

**Zig-zag** (`sint32`, `sint64`) for a field that is often negative. An
`int64` of −1 costs **ten bytes**, because a negative varint is
sign-extended to 64 bits first; the same value as `sint64` costs **one**.
`tests\ProtobufNative` asserts both lengths, because the difference is easy
to lose and expensive to lose.

**Fixed width** (`fixed32`, `fixed64`, `sfixed32`, `sfixed64`) for a value
that is usually large. Four or eight bytes always — cheaper than a varint
above about 2^28, dearer below it.

**A wider number into a narrower field.** A varint does not say which scalar
wrote it, so the reader decides by the field's declared scalar, as the
protobuf specification says: an `int32` or `uint32` field keeps the low 32
bits of a wider varint, the way a C++ cast does, and an `int64` field reads a
`uint64` above `High(Int64)` as negative. Every conforming implementation
reads those bytes the same way. After that cast the value is range-checked
into the member - 300 into a `Byte` is refused. On write, a value its
declared scalar cannot hold is refused. To read a wider value, declare the
wider scalar.

### Currency

A `Currency` is written as the **scaled `Int64` Delphi actually stores**,
zig-zagged, so it is exact to four decimal places with no floating point
anywhere near it. `[ProtoType(TProtoScalar.Double)]` says otherwise, and is
what a `.proto` declaring `double` needs.

### TDateTime

`google.protobuf.Timestamp` — a nested message of `seconds` (field 1) and
`nanos` (field 2) — which is the well-known type for an instant and what any
other implementation will expect. An instant before 1899-12-30 is written as
the `Timestamp` protoc writes for it (1800-01-01T12:00 is `seconds`
-5364619200), and read as the instant it states. A `TDateTime` or `TDate`
outside the years 1 to 9999 is refused on write (`ESerializationUnsupported`),
and a `Timestamp` outside them on read (`EProtobufInputError`, naming the
field) - which is also the range the well-known type defines. `TDate` and
`TTime` are **not** instants, so they travel as ISO 8601 text, parsed by
position rather than by the machine's locale.

---

## Presence

This is where proto3 is subtle, and the mapping follows it exactly.

**Implicit presence** — a plain scalar. A value equal to its type's default
is **not written at all**, and a reader that does not find the field uses
the default. An all-default message is zero bytes, which
`IMPLICIT_PRESENCE_OMITS_DEFAULTS` asserts.

**Explicit presence** — a `TNullable<T>`, or a class reference. Written
whenever it has a value, default or not; absent when it does not. This is
proto3's `optional`, and it is the only way to tell "zero" from "not set".

```pascal
[ProtoField(1)] Count: Integer;              // 0 is not written
[ProtoField(2)] Limit: TNullable<Integer>;   // 0 IS written, if set
```

---

## Repeated fields

A `TList<T>`, a descendant of one, or a `TArray<T>`. Numeric elements are
written **packed** — one length-delimited run — which is proto3's default
and much smaller; `[ProtoPacked(False)]` writes them one tag at a time.

A reader accepts **both** spellings whatever the schema says, because the
specification requires it. An empty repeated field is not written.

> A `TArray<T>` member that arrives unpacked is rebuilt once per element,
> which is quadratic in the element count — a Delphi dynamic array inside a
> `TValue` cannot grow in place. A `TList<T>` member has no such cost and is
> the better choice for a large repeated field.

## Maps

A `TDictionary<K,V>` is `map<K,V>`, which on the wire is exactly a repeated
message with the key in field 1 and the value in field 2 — the `map` keyword
is sugar over that and nothing more. A map entry missing either half uses
that type's default, as the specification says.

## oneof

Members sharing a `[ProtoOneOf]` name are mutually exclusive:

```pascal
[ProtoField(2), ProtoOneOf('body')] AsText: TNullable<string>;
[ProtoField(3), ProtoOneOf('body')] AsNumber: TNullable<Int64>;
[ProtoField(4), ProtoOneOf('body')] AsMessage: TDetail;
```

Reading one **clears the others**, so a document that sets two — which is
legal on the wire — leaves the last one set, which is what the specification
says. Give them explicit presence, so that "which one is set" has an answer.

## Enumerations

A protobuf enum is a **number**, and the numbers a `.proto` assigns need not
be 0, 1, 2 in order:

```pascal
TProtobufSerializer.RegisterEnumNumbers<TPriority>([0, 5, 10]);
```

Without a registration the ordinal is the number, which is right whenever
the `.proto` was written to match. With one, a number the type does not
declare raises rather than landing on whichever ordinal it happens to hit.

## Unknown fields

proto3 requires a conforming implementation to **preserve** fields it does
not understand across a round trip, and a Delphi DTO has nowhere to put them
unless it says so:

```pascal
type
  TNarrow = class
  public
    [ProtoField(1)] Known: Integer;
    [ProtoUnknown]  Unknown: TBytes;
  end;
```

With that member they survive, exactly as they arrived, written back at the
end of the message. **Without it they are dropped** — which is stated here
rather than left to be discovered, and is asserted by
`NO_STORE_UNKNOWN_FIELDS_ARE_DROPPED` so that this paragraph stays true.

## Groups

proto2's groups — wire types 3 and 4 — are **read**. A group the schema does
not know is skipped as a unit, nesting included, and a group with no end tag
or a mismatched one is an error. They are not written: nothing generates
them any more, and the specification deprecated them.

---

## Conversion

Protobuf takes part in **contract-aware** conversion with every other
format, in both directions:

```pascal
Proto := TProtobufSerializer.From<TShipment>(Json, TSerializationFormat.Json);
Json  := TJsonSerializer.From<TShipment>(Proto, TSerializationFormat.Protobuf);
```

It does **not** take part in structural conversion, and it says so:

```text
ESerializationFormatCapability:
  Structural parsing is not available for serialization format PROTOBUF.
  The format IS registered - its handler simply cannot parse its own payload
  into the dynamic structural tree.
```

That is a different exception from `ESerializationFormatNotRegistered`,
because the fix is different: use the contract-aware path, or use a
self-describing format. The same applies to building a DataSet: with a
contract it works, without one it raises.

```pascal
DS := TDataSetSerializer.CreateFDMemTable<TShipment>(Proto,
        TSerializationFormat.Protobuf);   // works
DS := TDataSetSerializer.CreateFDMemTable(Proto,
        TSerializationFormat.Protobuf);   // raises, and says why
```

---

## Custom serializers

Typed, like every other format's:

```pascal
type
  TCoordinateProto = class(TCustomProtoValueSerializer<TCoordinate>)
  public
    function SerializeValue(const AValue: TCoordinate;
      out AWireType: TProtoWireType): TBytes; override;
    function DeserializeValue(const AData: TBytes; AWireType: TProtoWireType;
      const AExisting: TCoordinate): TCoordinate; override;
  end;

TProtobufSerializer.RegisterTypeSerializer<TCoordinate>(TCoordinateProto);
```

The serializer chooses its own wire type, which is what lets a value object
be one length-delimited blob rather than a nested message with field numbers
of its own.

## Errors

`EProtobufError` and its two descendants: `EProtobufInputError` for bytes at
fault — a truncated varint, a length that overruns, a wire type that does
not exist, a string that is not UTF-8 — and `EProtobufInternalError` for a
model or configuration at fault — a duplicate field number, a reserved one,
a type protobuf cannot carry, a non-message root.

Every read is bounds-checked against the enclosing message as well as the
buffer, so a truncated or lying document fails with a message naming the
byte offset rather than reading past its end.
