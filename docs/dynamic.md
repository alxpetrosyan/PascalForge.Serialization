# Dynamic values

`PascalForge.Dynamic` is the library's structural model: a document as values,
with no Delphi type behind it. Every format reads into it and writes from it,
so a value built once can be written as JSON, BSON, CBOR, YAML or any other
format here, and a document read in one format can be changed and written in
another.

```pascal
uses
  PascalForge.Dynamic, PascalForge.Json, PascalForge.Bson;

var
  Obj: TDynamicObject;
begin
  Obj := TDynamicObject.Create;
  try
    Obj
      .Append('name', 'Erin')
      .Append('age', 35)
      .Append('active', True);
    Obj.InsertAt(1, 'country', 'Utopia');
    Obj.AddObject('address')
      .Append('city', 'Uptown')
      .Append('country', 'Ireland');

    Json := TJsonSerializer.FromDynamic(Obj);
    Bson := TBsonSerializer.FromDynamic(Obj);
  finally
    Obj.Free;
  end;
end;
```

**Dynamic is not a `TSerializationFormat`.** It produces no bytes and has no
registration. It is the value between a format's reader and a format's
writer, given to the caller to inspect, build or change.

**The builder philosophy.** Build a logical value once, with Dynamic, then
encode it with whichever format the destination wants. There is no
`TBsonDocument` or `TCborMap` builder family to learn per format. The
format-specific value types that remain (`TBsonValue`, `TCborValue`,
`TAsn1Value` and the rest) are for genuinely native operations: an exact
encoding, a format feature Dynamic carries only as an Extended value.

`demo\Dynamic\01-DynamicDocuments` runs every example on this page.

## The kinds

| Kind | Holds | Read with |
| --- | --- | --- |
| `Null` | nothing | `IsNull` |
| `Bool` | a Boolean | `AsBool` |
| `Int` | any Int64 | `AsInt` |
| `UInt` | a UInt64 **above** `High(Int64)` - anything smaller is `Int` | `AsUInt` |
| `Float` | a Double | `AsFloat` |
| `Decimal` | exact decimal text, at any precision | `AsDecimal` |
| `Str` | Unicode text | `AsStr` |
| `Bytes` | binary | `AsBytes` |
| `Date`, `Time`, `DateTime` | a calendar day, a time of day, an instant | `AsDateTime` |
| `Arr` | ordered items - a `TDynamicArray` | `AsArray`, `Items` |
| `Obj` | named members - a `TDynamicObject` | `AsObject`, `Find`, `Get` |
| `Extended` | a value a source format has that none of the above names | `ExtendedTag`, `ExtendedValue` |

It is deliberately not a JSON value model. A UInt64 past Int64, an exact
decimal, binary and the three temporal kinds are their own kinds because a
format that carries them natively must not lose them in the middle of a
conversion. A kind is **never inferred from text**: `"2026-09-22"` read from
JSON is `Str`, and stays `Str`.

**Extended values** carry what a source format has natively and the other
kinds do not name: a BSON ObjectId or decimal128, a CBOR semantic tag this
library does not interpret, a CBOR bignum, a MessagePack extension, a YAML
alias or tag. The tag is from `TDynamicTag` - the source format's own name
for the type - and the payload carries its parts, documented per tag. They
are kept exactly, never flattened to text; each destination writes them its
own way or refuses them (see [`conversion.md`](conversion.md)).

Scalars are made with the `TDynamicValue.New*` functions and never change.

**Each accessor reads its own kind.** `AsBool`, `AsInt`, `AsUInt`,
`AsFloat`, `AsDecimal`, `AsStr`, `AsBytes`, `AsDateTime`, `AsObject` and
`AsArray` raise `EDynamicError`, naming the kind, when asked of a value of
another kind - never a zero, an empty string or another kind's storage. The
only cross-kind readings are exact ones: `AsUInt` reads a non-negative `Int`,
`AsDecimal` reads an `Int` or `UInt` as its digits, and `AsDateTime` reads
all three temporal kinds. An `Int` is never read as a `UInt`'s bits, a `UInt`
never as an `Int`, a `Float` never as a decimal. Ask `Kind` first when the
kind is not known.

**Binary values are copied both ways**: `NewBytes` keeps its own copy of the
array, and `AsBytes` returns a copy, so neither the caller's array before nor
the returned array after can change the value.

## Objects

Members keep **insertion order** and **exact names**: `name`, `Name` and
`NAME` are three different members. A name is there at most once.

| Call | Does |
| --- | --- |
| `Append(Name, Value)` | adds a member at the end; returns the object |
| `InsertAt(Index, Name, Value)` | adds at `Index`, 0 to `Count`; `InsertAt(Count, ...)` is `Append`; returns the object |
| `AddObject(Name)`, `AddArray(Name)` | adds an empty child and returns **the child** |
| `AppendNull(Name)` | adds a null |
| `Adopt(Name, Value)` | adds, owning `Value` whatever happens (see Ownership) |
| `AppendOrReplace(Name, Value)` | **explicit** replacement: replaces the member in its position, or appends |
| `Find(Name)`, `Get(Name)` | the member, or `nil`; `Get` raises when there is none |
| `Contains`, `IndexOf`, `Names[I]`, `Items[I]`, `Count` | reading |
| `Extract(Name)`, `ExtractAt(I)` | takes a member out; the caller owns it |
| `Delete(Name)`, `Delete(I)`, `Clear` | takes members out and frees them; `EDynamicError` when there is no such member or index |
| `Remove(Name)` | the same by name, returning `False` instead of raising when there is none |
| `Import(Source, Collision)` | copies another object's members in |
| `MoveFrom(Source, Collision)` | **moves** them in, leaving `Source` empty |

`Append` takes a string, an `Int64`, a Boolean, a `TDynamicValue`, or **any
Delphi value** (next section). Appending a name that is already there raises
`EDynamicError` and leaves the object unchanged - nothing is silently
replaced.

## Arrays

| Call | Does |
| --- | --- |
| `Append(Value)` | adds an item; returns the array |
| `InsertAt(Index, Value)` | adds at `Index`; returns the array |
| `AddObject`, `AddArray` | adds an empty child and returns it |
| `AppendRange(Other)` | appends **copies of Other's items** - the explicit flatten |
| `ReplaceAt`, `ExtractAt`, `Delete(I)`, `Clear` | editing; an index out of range raises `EDynamicError` |

**Appending an array adds it as one nested item.** `Arr.Append(Other)` makes
a two-level array; flattening is only ever the explicit `AppendRange`.

## Delphi values

A class, a record, a list, a dictionary or a scalar becomes a dynamic value
through the same RTTI surface every serializer uses (see
[`attributes.md`](attributes.md)):

```pascal
Obj.Append('person', Person);    // the projection, as one member
Obj.Append(Person);              // the projection's members, imported
Arr.Append(Person);              // the projection, as one item

Value  := TDynamicSerializer.Serialize<TPerson>(Person);
Person := TDynamicSerializer.Deserialize<TPerson>(Value);
TDynamicSerializer.Populate(ExistingPerson, Value);
```

| Delphi | Dynamic |
| --- | --- |
| integer types, `Comp` | `Int` (`UInt` for a UInt64 past Int64) |
| `Double`, `Single`, `Extended` | `Float` |
| `Currency` | `Decimal`, exact |
| `TDate`, `TTime`, `TDateTime` | `Date`, `Time`, `DateTime` |
| `Boolean` | `Bool` |
| enumeration | `Str` - the name, or `[SerializationEnum]` text |
| set | `Arr` of element names |
| string, `Char` | `Str` |
| `TBytes` | `Bytes` |
| `TGUID` | `Str`, the canonical 36 characters without braces |
| `TNullable<T>` | the value, or null; an **empty** nullable member is left out |
| `Variant` | its value; an Unassigned member is left out |
| array, `TList<T>`, `TObjectList<T>`, `TStrings`, ... | `Arr` |
| `TDictionary<K, V>` with string, integer or enumeration keys | `Obj`, keyed by the key's text |
| class, record | `Obj` of its members |
| `TDynamicValue` | itself (see Ownership) |

Members are the public fields and readable properties, named by
`[SerializationName]` or by the **exact Delphi identifier** - Dynamic applies
no naming convention. Reading back, a member is found by its exact name and,
failing that, by the one member whose name matches ignoring case, because
Delphi identifiers are case-insensitive. Two or more members that match only
ignoring case - `name` and `NAME`, with no `Name` - are refused with
`EDynamicError` naming the path and the candidates, rather than one being
picked or the member left unset. A value of the wrong kind, a number
out of the member's range, an enumeration text the type does not have: each
raises `EDynamicError`, never a wrapped or default value. A read that fails
frees what it built and nothing else.

A read descends no deeper than every writer does: each object and array it
enters is one level of the library's 64-level limit
(`SERIALIZATION_MAX_GRAPH_DEPTH`), so a hand-built tree nested deeper raises
`ESerializationLimitExceeded`, naming where, instead of exhausting the
stack. The same holds for a `Variant` member read from nested arrays.

An enumeration's text is `[SerializationEnum]`'s wherever the enumeration
appears - a member, a nullable, a set's elements, an array's or list's
items, a dictionary's keys and values, a nested record - and a mapped
enumeration reads its mapped text only.

Text where the contract says date, time, `TBytes` or `TGUID` is decoded -
ISO 8601, base64, the GUID spelling - because a JSON document carries those
as strings. That is the contract speaking, not a guess: a `Str` read into a
string member stays a string.

`Obj.Append(Person)` with no name needs the projection to be an object; a
scalar raises. A `TDynamicObject` passed there is imported as copies of its
members, and the caller keeps it.

## Ownership

A value belongs to **at most one container**, which frees it.

- `Append`, `InsertAt` and `AppendOrReplace` take ownership **only when they
  succeed**. On a refusal - a duplicate name, an index out of range - the
  caller still owns the value.
- `Adopt` always takes ownership: on a refusal the value is freed. It is the
  form for a value built inline, `Obj.Adopt('x', BuildIt)`, which would
  otherwise leak.
- A value that already has a `Parent` is refused by every container: take it
  out with `Extract`, or add a `Clone`.
- A container cannot hold itself or one of its ancestors, so a tree never
  has a cycle.
- `Extract` and `ExtractAt` hand a member back as a root the caller owns.
- An Extended value owns its payload.

The tree returned by `Serialize`, `ToDynamic`, `Clone` and every format's
`ToDynamic` is the caller's. A value passed to `FromDynamic` stays the
caller's.

**Threading.** A dynamic value is an ordinary object: one thread changes it
at a time. Several threads may read a tree nobody is changing.

## Clone and equality

`Clone` is a deep copy, a new root. `Equals` is deep equality: same kind and
same value all the way down. **Arrays compare in order; objects compare
member by member by exact name, whatever order the members were added in.**
`Int 1` and `Float 1.0` are different values. Floats compare by value, so
`0.0` equals `-0.0` and NaN equals NaN; decimals compare as their text.
`GetHashCode` agrees with `Equals`.

## Import and merge

`Import` copies another object's members in - the source is not changed -
and `MoveFrom` moves them, leaving the source empty. `TDynamicCollision`
says what happens when a name is already taken:

| Collision | When the name is taken |
| --- | --- |
| `Error` (default) | `EDynamicError`, decided **before** anything changes |
| `KeepExisting` | the member already there stays |
| `Overwrite` | the incoming member replaces it, in its position |
| `DeepMerge` | two objects merge member by member, all the way down; **any other pair - two arrays included - is an Overwrite** |

Arrays are never concatenated or merged index by index. A caller that wants
that has `AppendRange`.

## Formats

Every format's facade reads and writes a dynamic value directly, with no
registration:

```pascal
Value := TJsonSerializer.ToDynamic(Json);          Json := TJsonSerializer.FromDynamic(Value);
Value := TXmlSerializer.ToDynamic(Xml);            Xml  := TXmlSerializer.FromDynamic(Value, 'Root');
Value := TBsonSerializer.ToDynamic(Bytes);         Bytes := TBsonSerializer.FromDynamic(Value);
Value := TCborSerializer.ToDynamic(Bytes);         Bytes := TCborSerializer.FromDynamic(Value);
Value := TMessagePackSerializer.ToDynamic(Bytes);  Bytes := TMessagePackSerializer.FromDynamic(Value);
Value := TYamlSerializer.ToDynamic(Yaml);          Yaml := TYamlSerializer.FromDynamic(Value);
Value := TCsvSerializer.ToDynamic(Csv);            Csv  := TCsvSerializer.FromDynamic(Value);
```

The schema-driven formats need their schema, and refuse rather than guess
without it:

```pascal
Value := TAvroSerializer.ToDynamic(Bytes, WriterSchema {, ReaderSchema});
Bytes := TAvroSerializer.FromDynamic(Value, Schema);
Value := TAsn1Serializer.ToDynamic(Bytes, Module, 'TypeName', TAsn1EncodingRule.Der);
Bytes := TAsn1Serializer.FromDynamic(Value, Module, 'TypeName', TAsn1EncodingRule.Der);
Value := Descriptors.ToDynamic(Bytes, 'package.Message');      // TProtobufSchema
Bytes := Descriptors.FromDynamic(Value, 'package.Message');
```

With the format chosen at run time, through the registry - the format must
be registered explicitly, as for any run-time choice:

```pascal
Value   := TSerialization.ToDynamic(Payload, TSerializationFormat.Bson);
Payload := TSerialization.FromDynamic(Value, TSerializationFormat.Xml);
// a schema-driven format takes its context
Value   := TSerialization.ToDynamic(Payload, TSerializationFormat.Avro, AvroContext);
```

What each format keeps and what it adapts is the structural conversion's
behaviour, described per format in `docs/formats/` and, with the three
profiles, in [`conversion.md`](conversion.md). In brief: JSON, BSON, CBOR,
MessagePack and YAML round-trip the common kinds; XML and CSV carry text and
a fixed shape (CSV is an array of flat objects); BSON and CBOR keep their
native values as Extended values.

## DataSets

```pascal
Value := TDataSetSerializer.ToDynamic(DataSet, TDataSetSerializationPolicy.StructureAndRows);
TDataSetSerializer.FromDynamic(Value, DataSet, TDataSetSourceMode.Auto);
TDataSetSerializer.FromDynamic(Value, DataSet, TDataSetSerializationPolicy.RowsOnly);
TDataSetSerializer.FromDynamic<TOrder>(Value, DataSet);
```

The same packet and projection the format paths use, with the encoded
document left out. **How a value is read into a DataSet is always the
caller's explicit choice** - a source mode or a policy - so an arbitrary
value is never treated as a DataSet packet because it happens to have
members called `fields` and `rows`. `FromDynamic<T>` is the contract-aware
form: `T`'s members, with their DataSet and general attributes, decide the
columns, and an array becomes one row per item. See
[`dataset-formats.md`](dataset-formats.md).

## Errors

`EDynamicError` is the model's own: a duplicate name, a value that already
has an owner, a cycle, an index out of range, a missing member, a
wrong-kind accessor, an ambiguous member name, a value of the wrong kind on
the way into a Delphi type. A tree nested past the depth limit raises the
library's `ESerializationLimitExceeded`. Each format's reader and writer
raise their own errors, as on every other path.
